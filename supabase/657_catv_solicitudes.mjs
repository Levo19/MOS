// 657 · CIERRE DE PEDIDO DEL CATÁLOGO VIRTUAL — mos.catv_solicitudes + 3 RPC
//   FASE 2 de la vitrina pública. La web arma un carrito y lo "cierra"; acá vive
//   todo lo que NO puede vivir en el navegador.
//
//   ── LEY DEL DINERO ────────────────────────────────────────────────────────────
//   El navegador manda SOLO {id, escalon_idx, cantidad}. Ni un precio, ni un
//   subtotal, ni un total. El servidor:
//     1. llama a mos.catalogo_virtual() — la MISMA función que leyó el browser, así
//        el índice del escalón y su precio son por construcción los que se vieron;
//     2. re-lee el precio REAL de ese escalón y recalcula subtotal y total;
//     3. mapea el id-hash (substr(md5(fsku),1,10)) al producto interno y guarda la
//        línea DESNORMALIZADA con cod_barras/sku — datos internos que jamás viajan
//        de vuelta al público (la tabla no es legible por anon ni authenticated).
//   Si el payload trae precios, se IGNORAN. Test 'anti-manipulación' lo demuestra.
//
//   ── TABLA ─────────────────────────────────────────────────────────────────────
//   mos.catv_solicitudes: RLS ON con 0 policies + REVOKE a anon/authenticated ⇒
//   NADIE la lee por PostgREST. La única puerta son las RPC SECURITY DEFINER.
//
//   ── QUIÉN PUEDE LEER LAS SOLICITUDES ──────────────────────────────────────────
//   catv_pendientes / catv_atender llevan datos de contacto de clientes reales
//   (nombre + teléfono + qué compran). No pueden ser abiertas como el resto de
//   ruta_* (que hoy están concedidas a anon SIN puerta alguna).
//   Puerta doble, cualquiera de las dos abre:
//     · rol authenticated / service_role / postgres  → pasa (lo pedido en el brief);
//     · rol anon + p.device = dispositivo mosGo ACTIVO en mos.dispositivos → pasa.
//   MosGo NO tiene sesión Supabase: llama a sus RPC con la anon key + PIN propio
//   (ver mos.ruta_login_pin). Sin la segunda puerta la pestaña Pedidos no podría
//   cargar nada. Con ella, estas dos RPC quedan ESTRICTAMENTE más cerradas que
//   cualquier otra ruta_* del POS.
//
//   Parche con def VIVA verificada; tests dentro de begin/rollback ANTES de aplicar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const T = []; const chk = (n, cond, x) => { T.push([cond ? '✅' : '❌', n, x === undefined ? '' : String(x)]); return cond; };

// ── DDL ────────────────────────────────────────────────────────────────────────
const DDL_TABLA = `
create table if not exists mos.catv_solicitudes (
  id            bigserial primary key,
  codigo        text generated always as ('SOL-' || id) stored,
  lineas        jsonb       not null default '[]'::jsonb,
  total         numeric(12,2) not null default 0,
  nombre        text,
  telefono      text,
  user_agent    text,
  created_at    timestamptz not null default now(),
  estado        text        not null default 'PENDIENTE',
  atendido_por  text
);

create unique index if not exists catv_solicitudes_codigo_uk on mos.catv_solicitudes (codigo);
create index if not exists catv_solicitudes_pend_ix on mos.catv_solicitudes (estado, created_at desc);
create index if not exists catv_solicitudes_tel_ix  on mos.catv_solicitudes (telefono, created_at desc);
create index if not exists catv_solicitudes_ua_ix   on mos.catv_solicitudes (user_agent, created_at desc);

alter table mos.catv_solicitudes enable row level security;
alter table mos.catv_solicitudes force row level security;

revoke all on table    mos.catv_solicitudes           from public, anon, authenticated;
revoke all on sequence mos.catv_solicitudes_id_seq    from public, anon, authenticated;
`;

// ── RPC 1 · catv_solicitar (PÚBLICA · anon) ────────────────────────────────────
const DDL_SOLICITAR = `
create or replace function mos.catv_solicitar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
set statement_timeout to '20s'
as $fn$
declare
  v_in     jsonb   := coalesce(p->'lineas', '[]'::jsonb);
  v_nombre text    := left(btrim(coalesce(p->>'nombre', '')), 80);
  v_tel    text    := left(regexp_replace(coalesce(p->>'telefono', ''), '[^0-9]', '', 'g'), 20);
  v_ua     text    := left(btrim(coalesce(p->>'ua', '')), 400);
  v_n      int;
  v_hits   int;
  v_cat    jsonb;
  v_map    jsonb;
  v_lin    jsonb   := '[]'::jsonb;
  v_tot    numeric := 0;
  v_fam    jsonb;
  v_esc    jsonb;
  v_fsku   text;
  v_cod    text;
  v_sku    text;
  v_fac    numeric;
  v_pre    numeric;
  v_sub    numeric;
  v_codigo text;
  r        record;
begin
  -- ── forma del payload ───────────────────────────────────────────────────────
  if jsonb_typeof(v_in) <> 'array' then
    return jsonb_build_object('ok', false, 'razon', 'payload');
  end if;
  v_n := jsonb_array_length(v_in);
  if v_n = 0  then return jsonb_build_object('ok', false, 'razon', 'vacio');      end if;
  if v_n > 60 then return jsonb_build_object('ok', false, 'razon', 'max_lineas'); end if;

  -- cada línea: id = 10 hex, escalon_idx = entero, cantidad = entero.
  -- Cualquier otra cosa (precio incluido) se descarta sin mirarla.
  if exists (
    select 1 from jsonb_array_elements(v_in) x
     where coalesce(x.value->>'id', '')          !~ '^[0-9a-f]{10}$'
        or coalesce(x.value->>'escalon_idx', '') !~ '^[0-9]{1,3}$'
        or coalesce(x.value->>'cantidad', '')    !~ '^[0-9]{1,4}$'
  ) then
    return jsonb_build_object('ok', false, 'razon', 'payload');
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_in) x
     where (x.value->>'cantidad')::int < 1 or (x.value->>'cantidad')::int > 999
  ) then
    return jsonb_build_object('ok', false, 'razon', 'cantidad');
  end if;

  -- ── anti-abuso: 5 por hora por teléfono O por user_agent ────────────────────
  select count(*) into v_hits
    from mos.catv_solicitudes s
   where s.created_at > now() - interval '1 hour'
     and ( (v_tel <> '' and s.telefono   = v_tel)
        or (v_ua  <> '' and s.user_agent = v_ua) );
  if v_hits >= 5 then
    return jsonb_build_object('ok', false, 'razon', 'limite');
  end if;

  -- ── la vitrina, tal cual la leyó el navegador ───────────────────────────────
  v_cat := mos.catalogo_virtual();

  -- id-hash → sku de familia (mismo md5 corto que publica catalogo_virtual)
  select coalesce(jsonb_object_agg(substr(md5(k.fsku), 1, 10), k.fsku), '{}'::jsonb)
    into v_map
    from (
      select distinct coalesce(nullif(btrim(pp.sku_base), ''), pp.id_producto) as fsku
        from mos.productos pp
       where pp.canal_mayoreo = true and pp.tipo_producto::text <> 'PRESENTACION'
      union
      select distinct nullif(btrim(pp.sku_base), '')
        from mos.productos pp
       where pp.canal_mayoreo = true and pp.tipo_producto::text = 'PRESENTACION'
         and nullif(btrim(pp.sku_base), '') is not null
    ) k;

  for r in
    select x.value->>'id'                as hid,
           (x.value->>'escalon_idx')::int as eidx,
           (x.value->>'cantidad')::int    as cant,
           x.ordinality::int              as nro
      from jsonb_array_elements(v_in) with ordinality x(value, ordinality)
  loop
    select y.value into v_fam
      from jsonb_array_elements(v_cat->'familias') y
     where y.value->>'id' = r.hid
     limit 1;
    if v_fam is null then
      return jsonb_build_object('ok', false, 'razon', 'linea_invalida', 'linea', r.nro);
    end if;

    v_esc := v_fam->'escalones'->r.eidx;
    if v_esc is null then
      return jsonb_build_object('ok', false, 'razon', 'linea_invalida', 'linea', r.nro);
    end if;

    -- PRECIO REAL: sale de la vitrina del servidor, nunca del navegador
    v_fac := coalesce((v_esc->>'factor')::numeric, 1);
    v_pre := round(coalesce((v_esc->>'precio')::numeric, 0), 2);
    if not (v_pre > 0) then
      return jsonb_build_object('ok', false, 'razon', 'linea_invalida', 'linea', r.nro);
    end if;
    v_sub := round(v_pre * r.cant, 2);

    -- ── producto interno (cod_barras / sku) ───────────────────────────────────
    v_fsku := v_map->>r.hid;
    v_cod := null; v_sku := null;
    if v_fsku is not null then
      if v_fac = 1 then
        select pr.codigo_barra, pr.id_producto into v_cod, v_sku
          from mos.productos pr
         where coalesce(nullif(btrim(pr.sku_base), ''), pr.id_producto) = v_fsku
           and pr.tipo_producto::text <> 'PRESENTACION'
           and coalesce(nullif(pr.factor_conversion, 0), 1) = 1
           and pr.canal_mayoreo = true
           and round(coalesce(pr.precio_venta, 0), 2) = v_pre
         order by (upper(coalesce(nullif(btrim(pr.unidad_medida), ''), pr.unidad, '')) = 'KGM') desc,
                  pr.id_producto
         limit 1;
      end if;
      if v_cod is null then
        select e.codigo_barra, e.id_producto into v_cod, v_sku
          from mos.productos e
         where nullif(btrim(e.sku_base), '') = v_fsku
           and e.tipo_producto::text = 'PRESENTACION'
           and e.canal_mayoreo = true
           and coalesce(nullif(e.factor_conversion, 0), 1) = v_fac
           and round(coalesce(e.precio_venta, 0), 2) = v_pre
         order by e.id_producto
         limit 1;
      end if;
    end if;
    if v_cod is null then
      -- sin producto interno la línea no es convertible en pedido: se rechaza
      -- entera antes que guardar una solicitud que MosGo no podrá atender.
      return jsonb_build_object('ok', false, 'razon', 'linea_invalida', 'linea', r.nro);
    end if;

    v_lin := v_lin || jsonb_build_object(
      'n',           r.nro,
      'id',          r.hid,
      'cod_barras',  v_cod,
      'sku',         v_sku,
      'producto',    v_fam->>'nombre',
      'marca',       v_fam->>'marca',
      'concepto',    v_fam->>'concepto',
      'unidad',      v_fam->>'unidad',
      'escalon',     v_esc->>'label',
      'factor',      v_fac,
      'cantidad',    r.cant,
      'precio_unit', v_pre,
      'subtotal',    v_sub);
    v_tot := v_tot + v_sub;
  end loop;

  insert into mos.catv_solicitudes (lineas, total, nombre, telefono, user_agent)
  values (v_lin, round(v_tot, 2), nullif(v_nombre, ''), nullif(v_tel, ''), nullif(v_ua, ''))
  returning codigo into v_codigo;

  return jsonb_build_object('ok', true, 'codigo', v_codigo,
                            'total', round(v_tot, 2), 'lineas', jsonb_array_length(v_lin));
end;
$fn$;

revoke all on function mos.catv_solicitar(jsonb) from public;
grant execute on function mos.catv_solicitar(jsonb) to anon, authenticated;
`;

// ── RPC 2 · catv_pendientes (MosGo) ────────────────────────────────────────────
const DDL_PENDIENTES = `
create or replace function mos.catv_pendientes(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
set statement_timeout to '15s'
as $fn$
declare
  v_rol text := lower(coalesce(nullif(current_setting('role', true), 'none'), session_user::text, ''));
  v_dev text := nullif(btrim(coalesce(p->>'device', '')), '');
begin
  if v_rol not in ('authenticated', 'service_role', 'postgres')
     and not exists (select 1 from mos.dispositivos d
                      where d.id_dispositivo = v_dev
                        and upper(coalesce(d.estado, '')) = 'ACTIVO'
                        and lower(coalesce(d.app, '')) = 'mosgo')
  then
    return jsonb_build_object('ok', false, 'error', 'NO_AUTORIZADO');
  end if;

  return jsonb_build_object('ok', true, 'solicitudes', coalesce((
    select jsonb_agg(jsonb_build_object(
             'codigo',     s.codigo,
             'nombre',     s.nombre,
             'telefono',   s.telefono,
             'total',      s.total,
             'lineas',     s.lineas,
             'created_at', to_char(s.created_at at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI:SS'),
             'hace_min',   floor(extract(epoch from (now() - s.created_at)) / 60)::int
           ) order by s.created_at desc)
      from (select * from mos.catv_solicitudes
             where estado = 'PENDIENTE' order by created_at desc limit 100) s
  ), '[]'::jsonb));
end;
$fn$;

revoke all on function mos.catv_pendientes(jsonb) from public;
grant execute on function mos.catv_pendientes(jsonb) to anon, authenticated;
`;

// ── RPC 3 · catv_atender (MosGo) ───────────────────────────────────────────────
const DDL_ATENDER = `
create or replace function mos.catv_atender(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
set statement_timeout to '15s'
as $fn$
declare
  v_rol text := lower(coalesce(nullif(current_setting('role', true), 'none'), session_user::text, ''));
  v_dev text := nullif(btrim(coalesce(p->>'device', '')), '');
  v_cod text := btrim(coalesce(p->>'codigo', ''));
  v_ven text := left(btrim(coalesce(p->>'vendedor', '')), 60);
  v_out text;
begin
  if v_rol not in ('authenticated', 'service_role', 'postgres')
     and not exists (select 1 from mos.dispositivos d
                      where d.id_dispositivo = v_dev
                        and upper(coalesce(d.estado, '')) = 'ACTIVO'
                        and lower(coalesce(d.app, '')) = 'mosgo')
  then
    return jsonb_build_object('ok', false, 'error', 'NO_AUTORIZADO');
  end if;
  if v_cod !~ '^SOL-[0-9]{1,18}$' then
    return jsonb_build_object('ok', false, 'error', 'CODIGO_INVALIDO');
  end if;

  update mos.catv_solicitudes
     set estado = 'ATENDIDA', atendido_por = nullif(v_ven, '')
   where codigo = v_cod and estado = 'PENDIENTE'
  returning codigo into v_out;

  if v_out is null then
    return jsonb_build_object('ok', false, 'error', 'NO_PENDIENTE');
  end if;
  return jsonb_build_object('ok', true, 'codigo', v_out, 'estado', 'ATENDIDA',
                            'atendido_por', nullif(v_ven, ''));
end;
$fn$;

revoke all on function mos.catv_atender(jsonb) from public;
grant execute on function mos.catv_atender(jsonb) to anon, authenticated;
`;

await c.query('begin');
await c.query(DDL_TABLA);
await c.query(DDL_SOLICITAR);
await c.query(DDL_PENDIENTES);
await c.query(DDL_ATENDER);

// ═══ VERIFICACIÓN DE LA DEF VIVA (lo que quedó, no lo que creí escribir) ═══════
{
  for (const fn of ['catv_solicitar', 'catv_pendientes', 'catv_atender']) {
    const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'mos' and p.proname = $1`, [fn])).rows[0];
    chk(`${fn} · def viva`, !!d && !!d.d);
    chk(`${fn} · SECURITY DEFINER`, /SECURITY DEFINER/.test(d.d));
    chk(`${fn} · search_path=''`, /SET search_path TO ''/.test(d.d));
    const acl = (await c.query(`select coalesce(array_to_string(p.proacl, ','), '') a from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'mos' and p.proname = $1`, [fn])).rows[0].a;
    chk(`${fn} · GRANT anon+authenticated`, /anon=X/.test(acl) && /authenticated=X/.test(acl), acl);
    chk(`${fn} · sin GRANT a PUBLIC`, !/(^|,)=X/.test(acl));
  }
}

// ── tabla: RLS on, 0 policies, cero permisos para el público ──────────────────
{
  const t = (await c.query(`select relrowsecurity rls, relforcerowsecurity frls
     from pg_class cl join pg_namespace n on n.oid = cl.relnamespace
    where n.nspname = 'mos' and cl.relname = 'catv_solicitudes'`)).rows[0];
  chk('tabla · RLS ON', t && t.rls === true);
  chk('tabla · FORCE RLS', t && t.frls === true);
  const pol = (await c.query(`select count(*)::int n from pg_policies where schemaname = 'mos' and tablename = 'catv_solicitudes'`)).rows[0].n;
  chk('tabla · 0 policies', pol === 0, 'policies=' + pol);
  const g = (await c.query(`select coalesce(string_agg(grantee || ':' || privilege_type, ','), '') g
     from information_schema.role_table_grants
    where table_schema = 'mos' and table_name = 'catv_solicitudes' and grantee in ('anon','authenticated','PUBLIC')`)).rows[0].g;
  chk('tabla · sin grants a anon/authenticated/PUBLIC', g === '', g || 'ninguno');
  const cols = (await c.query(`select column_name, is_generated, generation_expression
     from information_schema.columns where table_schema = 'mos' and table_name = 'catv_solicitudes' order by ordinal_position`)).rows;
  chk('tabla · 10 columnas', cols.length === 10, cols.map(x => x.column_name).join(','));
  const cg = cols.find(x => x.column_name === 'codigo');
  chk("tabla · codigo generada 'SOL-'||id", cg && cg.is_generated === 'ALWAYS' && /SOL-/.test(cg.generation_expression || ''),
    cg && cg.generation_expression);
}

// ═══ TESTS FUNCIONALES COMO anon (así llega por PostgREST) ════════════════════
const DEV_OK = '7e57c1a0-de00-4c1a-9de0-7e57c1a0de00';   // TEST-CLAUDE (QA MosGo), ACTIVO
// TODO user_agent del harness empieza por 'harness-657' → (a) es único por corrida, así el
// anti-abuso de una corrida no contamina la siguiente; (b) la limpieza final lo reconoce.
const UA_T = 'harness-657-' + Date.now();
const BASE = (await c.query(`select count(*)::int n from mos.catv_solicitudes`)).rows[0].n;

// catálogo real para armar payloads verdaderos
const CAT = (await c.query(`select mos.catalogo_virtual() r`)).rows[0].r;
const conEsc = (CAT.familias || []).filter(f => (f.escalones || []).length > 0);
const F1 = conEsc[0], F2 = conEsc.find(f => f !== F1 && (f.escalones || []).length > 1) || conEsc[1];
chk('hay familias con escalones para probar', !!F1 && !!F2, `f1=${F1 && F1.id} f2=${F2 && F2.id}`);

const anon = async (sql, params) => {
  await c.query('savepoint sp');
  await c.query('set local role anon');
  let out, err = null;
  try { out = (await c.query(sql, params)).rows; }
  catch (e) { err = e.message; }
  // ROLLBACK TO SAVEPOINT deshace también el SET LOCAL ROLE — y es lo ÚNICO que se
  // puede hacer con la transacción abortada; el reset explícito solo va en el camino feliz.
  if (err) { await c.query('rollback to savepoint sp'); return { err }; }
  await c.query('reset role');
  await c.query('release savepoint sp');
  return { rows: out };
};
const solicitar = async p => {
  const r = await anon(`select mos.catv_solicitar($1::jsonb) r`, [JSON.stringify(p)]);
  return r.err ? { err: r.err } : r.rows[0].r;
};

// ── 1 · anon NO puede tocar la tabla ──────────────────────────────────────────
{
  const r = await anon(`select count(*) from mos.catv_solicitudes`);
  chk('anon NO puede leer la tabla', !!r.err, (r.err || 'LEYÓ — FUGA').slice(0, 70));
  const w = await anon(`insert into mos.catv_solicitudes (lineas) values ('[]'::jsonb)`);
  chk('anon NO puede insertar en la tabla', !!w.err, (w.err || 'INSERTÓ — FUGA').slice(0, 70));
}

// ── 2 · camino feliz ──────────────────────────────────────────────────────────
let SOL1 = null, ESPERADO = 0;
{
  const e1 = F1.escalones[0], e2 = F2.escalones[F2.escalones.length - 1];
  ESPERADO = Math.round((+e1.precio * 3 + +e2.precio * 2) * 100) / 100;
  const r = await solicitar({
    lineas: [{ id: F1.id, escalon_idx: 0, cantidad: 3 },
             { id: F2.id, escalon_idx: F2.escalones.length - 1, cantidad: 2 }],
    nombre: 'Bodega La Prueba', telefono: '987 654 321', ua: UA_T
  });
  chk('anon puede ejecutar catv_solicitar', !r.err, r.err);
  chk('camino feliz · ok:true', r && r.ok === true, JSON.stringify(r));
  chk('camino feliz · codigo SOL-n', /^SOL-[0-9]+$/.test((r || {}).codigo || ''), r && r.codigo);
  chk('camino feliz · total = servidor', +(r || {}).total === ESPERADO, `rpc=${r && r.total} esperado=${ESPERADO}`);
  SOL1 = r && r.codigo;

  const g = (await c.query(`select lineas, total, nombre, telefono, user_agent, estado, atendido_por
     from mos.catv_solicitudes where codigo = $1`, [SOL1])).rows[0];
  chk('guardado · estado PENDIENTE', g && g.estado === 'PENDIENTE');
  chk('guardado · total en tabla', g && +g.total === ESPERADO, g && g.total);
  chk('guardado · teléfono normalizado a dígitos', g && g.telefono === '987654321', g && g.telefono);
  chk('guardado · 2 líneas', g && g.lineas.length === 2);
  chk('guardado · líneas con cod_barras interno', g && g.lineas.every(l => !!l.cod_barras && !!l.sku),
    g && JSON.stringify(g.lineas[0]));
  chk('guardado · subtotal = precio_unit × cantidad', g && g.lineas.every(l =>
    Math.abs(+l.subtotal - Math.round(+l.precio_unit * +l.cantidad * 100) / 100) < 0.005));
  chk('guardado · total = Σ subtotales', g &&
    Math.abs(+g.total - g.lineas.reduce((a, l) => a + (+l.subtotal), 0)) < 0.005);
}

// ── 3 · ANTI-MANIPULACIÓN: precios inventados en el payload NO mueven el total ──
{
  const e1 = F1.escalones[0], e2 = F2.escalones[F2.escalones.length - 1];
  const r = await solicitar({
    lineas: [
      { id: F1.id, escalon_idx: 0, cantidad: 3, precio: 0.01, precio_unit: 0.01, subtotal: 0.03, label: 'GRATIS' },
      { id: F2.id, escalon_idx: F2.escalones.length - 1, cantidad: 2, precio: 0.01, subtotal: 0.02 }
    ],
    total: 0.05, nombre: 'Ladrón de precios', telefono: '900 000 001', ua: UA_T + '-hack'
  });
  chk('anti-manipulación · acepta el pedido', r && r.ok === true, JSON.stringify(r));
  chk('anti-manipulación · total REAL, no el enviado', +(r || {}).total === ESPERADO,
    `enviado=0.05 · devuelto=${r && r.total} · real=${ESPERADO}`);
  const g = (await c.query(`select total, lineas from mos.catv_solicitudes where codigo = $1`, [r.codigo])).rows[0];
  chk('anti-manipulación · nada de 0.01 quedó en la tabla',
    +g.total === ESPERADO && g.lineas.every(l => +l.precio_unit > 0.01),
    `total=${g.total} precios=${g.lineas.map(l => l.precio_unit).join('/')}`);
  chk('anti-manipulación · el label sale del servidor, no del payload',
    g.lineas.every(l => l.escalon !== 'GRATIS'), g.lineas.map(l => l.escalon).join(' | '));
  chk('anti-manipulación · precio_unit = precio real del escalón',
    +g.lineas[0].precio_unit === Math.round(+e1.precio * 100) / 100 &&
    +g.lineas[1].precio_unit === Math.round(+e2.precio * 100) / 100,
    `${g.lineas[0].precio_unit}/${g.lineas[1].precio_unit} vs ${e1.precio}/${e2.precio}`);
}

// ── 4 · validaciones ──────────────────────────────────────────────────────────
{
  const L = n => Array.from({ length: n }, () => ({ id: F1.id, escalon_idx: 0, cantidad: 1 }));
  const casos = [
    ['vacío',              { lineas: [] },                                                              'vacio'],
    ['61 líneas',          { lineas: L(61) },                                                           'max_lineas'],
    ['cantidad 0',         { lineas: [{ id: F1.id, escalon_idx: 0, cantidad: 0 }] },                    'cantidad'],
    ['cantidad 1000',      { lineas: [{ id: F1.id, escalon_idx: 0, cantidad: 1000 }] },                 'cantidad'],
    ['cantidad negativa',  { lineas: [{ id: F1.id, escalon_idx: 0, cantidad: -5 }] },                   'payload'],
    ['cantidad decimal',   { lineas: [{ id: F1.id, escalon_idx: 0, cantidad: 1.5 }] },                  'payload'],
    ['cantidad texto',     { lineas: [{ id: F1.id, escalon_idx: 0, cantidad: 'DROP' }] },               'payload'],
    ['id inventado',       { lineas: [{ id: 'deadbeef00', escalon_idx: 0, cantidad: 1 }] },             'linea_invalida'],
    ['id con forma mala',  { lineas: [{ id: '../../etc', escalon_idx: 0, cantidad: 1 }] },              'payload'],
    ['escalón fuera',      { lineas: [{ id: F1.id, escalon_idx: 99, cantidad: 1 }] },                   'linea_invalida'],
    ['lineas no-array',    { lineas: { id: F1.id } },                                                   'payload']
  ];
  for (const [n, p, esp] of casos) {
    const r = await solicitar({ ...p, ua: UA_T + '-val-' + n });
    chk('rechaza ' + n, r && r.ok === false && r.razon === esp, JSON.stringify(r));
  }
  const antes = (await c.query(`select count(*)::int n from mos.catv_solicitudes`)).rows[0].n;
  chk('los rechazos NO dejaron filas', antes - BASE === 2, `nuevas=${antes - BASE} (base=${BASE})`);
}

// ── 5 · límite de 5/hora ──────────────────────────────────────────────────────
{
  const UA_L = 'harness-657-limite-' + Date.now();
  const uno = () => solicitar({ lineas: [{ id: F1.id, escalon_idx: 0, cantidad: 1 }], ua: UA_L });
  const res = [];
  for (let i = 0; i < 7; i++) res.push(await uno());
  chk('límite · las 5 primeras pasan', res.slice(0, 5).every(r => r && r.ok === true),
    res.slice(0, 5).map(r => r && (r.ok ? 'ok' : r.razon)).join(','));
  chk('límite · la 6ª cae con razon=limite', res[5] && res[5].ok === false && res[5].razon === 'limite', JSON.stringify(res[5]));
  chk('límite · la 7ª también', res[6] && res[6].ok === false && res[6].razon === 'limite');

  // por teléfono, aunque cambie el user_agent
  const TEL = '955' + String(Date.now()).slice(-6);
  const dos = ua => solicitar({ lineas: [{ id: F1.id, escalon_idx: 0, cantidad: 1 }], telefono: TEL, ua });
  const r2 = [];
  for (let i = 0; i < 6; i++) r2.push(await dos(UA_T + '-tel-' + TEL + '-' + i));
  chk('límite · por TELÉFONO aunque cambie el navegador',
    r2.slice(0, 5).every(r => r.ok === true) && r2[5].ok === false && r2[5].razon === 'limite',
    r2.map(r => r.ok ? 'ok' : r.razon).join(','));
}

// ── 6 · catv_pendientes: puerta ───────────────────────────────────────────────
{
  const sinDev = await anon(`select mos.catv_pendientes('{}'::jsonb) r`);
  chk('pendientes · anon SIN device → NO_AUTORIZADO',
    !sinDev.err && sinDev.rows[0].r.ok === false && sinDev.rows[0].r.error === 'NO_AUTORIZADO',
    JSON.stringify(sinDev.err || sinDev.rows[0].r));

  const malDev = await anon(`select mos.catv_pendientes($1::jsonb) r`, [JSON.stringify({ device: 'inventado-123' })]);
  chk('pendientes · device desconocido → NO_AUTORIZADO', malDev.rows[0].r.error === 'NO_AUTORIZADO');

  // un dispositivo real pero de OTRA app / no ACTIVO tampoco entra
  const otra = (await c.query(`select id_dispositivo from mos.dispositivos
      where lower(coalesce(app,'')) <> 'mosgo' and upper(coalesce(estado,'')) = 'ACTIVO' limit 1`)).rows[0];
  if (otra) {
    const r = await anon(`select mos.catv_pendientes($1::jsonb) r`, [JSON.stringify({ device: otra.id_dispositivo })]);
    chk('pendientes · dispositivo de otra app → NO_AUTORIZADO', r.rows[0].r.error === 'NO_AUTORIZADO', otra.id_dispositivo);
  }

  const ok = await anon(`select mos.catv_pendientes($1::jsonb) r`, [JSON.stringify({ device: DEV_OK })]);
  const P = ok.rows[0].r;
  chk('pendientes · device mosGo ACTIVO → ok', P && P.ok === true, JSON.stringify(ok.err || '').slice(0, 90));
  chk('pendientes · aparece la solicitud de prueba',
    (P.solicitudes || []).some(s => s.codigo === SOL1), (P.solicitudes || []).map(s => s.codigo).join(','));
  const s1 = (P.solicitudes || []).find(s => s.codigo === SOL1);
  chk('pendientes · trae nombre/teléfono/total/hace_min/lineas',
    s1 && s1.nombre === 'Bodega La Prueba' && s1.telefono === '987654321'
       && +s1.total === ESPERADO && typeof s1.hace_min === 'number' && Array.isArray(s1.lineas),
    JSON.stringify(s1 && { n: s1.nombre, t: s1.telefono, to: s1.total, h: s1.hace_min }));
  chk('pendientes · las líneas llevan cod_barras (MosGo mapea con eso)',
    s1 && s1.lineas.every(l => !!l.cod_barras));

  // authenticated pasa sin device
  await c.query('savepoint spa'); await c.query('set local role authenticated');
  const au = (await c.query(`select mos.catv_pendientes('{}'::jsonb) r`)).rows[0].r;
  await c.query('reset role'); await c.query('release savepoint spa');
  chk('pendientes · authenticated pasa SIN device', au && au.ok === true, JSON.stringify(au).slice(0, 80));
}

// ── 7 · catv_atender ──────────────────────────────────────────────────────────
{
  const sinDev = await anon(`select mos.catv_atender($1::jsonb) r`, [JSON.stringify({ codigo: SOL1, vendedor: 'X' })]);
  chk('atender · sin device → NO_AUTORIZADO', sinDev.rows[0].r.error === 'NO_AUTORIZADO');

  const malCod = await anon(`select mos.catv_atender($1::jsonb) r`,
    [JSON.stringify({ device: DEV_OK, codigo: "SOL-1'; drop table x--", vendedor: 'X' })]);
  chk('atender · código con forma mala → CODIGO_INVALIDO', malCod.rows[0].r.error === 'CODIGO_INVALIDO');

  const r = await anon(`select mos.catv_atender($1::jsonb) r`,
    [JSON.stringify({ device: DEV_OK, codigo: SOL1, vendedor: 'LUIS (QA 657)' })]);
  const A = r.rows[0].r;
  chk('atender · ok', A && A.ok === true && A.estado === 'ATENDIDA', JSON.stringify(A));

  const g = (await c.query(`select estado, atendido_por from mos.catv_solicitudes where codigo = $1`, [SOL1])).rows[0];
  chk('atender · tabla en ATENDIDA con vendedor', g.estado === 'ATENDIDA' && g.atendido_por === 'LUIS (QA 657)',
    JSON.stringify(g));

  const rep = await anon(`select mos.catv_atender($1::jsonb) r`,
    [JSON.stringify({ device: DEV_OK, codigo: SOL1, vendedor: 'OTRO' })]);
  chk('atender · repetir → NO_PENDIENTE (nadie la roba dos veces)', rep.rows[0].r.error === 'NO_PENDIENTE');

  const P = (await anon(`select mos.catv_pendientes($1::jsonb) r`, [JSON.stringify({ device: DEV_OK })])).rows[0].r;
  chk('atender · ya no aparece en pendientes', !(P.solicitudes || []).some(s => s.codigo === SOL1));
}

// ── retrato ───────────────────────────────────────────────────────────────────
{
  const f = (await c.query(`select codigo, total, nombre, telefono, estado, atendido_por,
      jsonb_array_length(lineas) nl from mos.catv_solicitudes order by id`)).rows;
  console.log('\n📥 SOLICITUDES creadas por el harness (todo esto se revierte):');
  for (const x of f) console.log(`   · ${x.codigo}  S/ ${x.total}  ${x.nl} líneas  ${x.estado}` +
    `${x.atendido_por ? ' por ' + x.atendido_por : ''}  ${x.nombre || '(sin nombre)'} ${x.telefono || ''}`);
  const l = (await c.query(`select lineas from mos.catv_solicitudes order by id limit 1`)).rows[0].lineas;
  console.log('   línea canónica ejemplo:', JSON.stringify(l[0]));
}

// ── LIMPIEZA: los tests INSERTAN de verdad. En --apply el commit se llevaría las
//    filas del harness a producción — se borran acá y la secuencia vuelve a 1, así
//    la primera solicitud real del catálogo es SOL-1.
{
  const del = (await c.query(`delete from mos.catv_solicitudes
     where coalesce(user_agent, '') like 'harness-657%'
        or coalesce(user_agent, '') like 'ua-distinto-%'`)).rowCount;
  const quedan = (await c.query(`select count(*)::int n from mos.catv_solicitudes`)).rows[0].n;
  chk('limpieza · el harness no deja basura en PROD', quedan === 0, `borradas=${del} quedan=${quedan}`);
  if (quedan === 0) await c.query(`alter sequence mos.catv_solicitudes_id_seq restart with 1`);
}

const ok = T.every(t => t[0] === '✅');
console.log('\n' + T.map(t => `${t[0]} ${t[1]}${t[2] ? '  → ' + t[2] : ''}`).join('\n'));
if (ok && process.argv.includes('--apply')) { await c.query('commit'); console.log('\n🟢 657 APLICADO'); }
else { await c.query('rollback'); console.log(ok ? '\n🟡 tests OK — corre con --apply para aplicar' : '\n🔴 ROLLBACK: hay tests en rojo'); }
await c.end();
