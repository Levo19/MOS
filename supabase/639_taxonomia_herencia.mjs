// 639 · TAXONOMÍA + HERENCIA de ficha (decisión dueño, aprobada 100%):
//   · mos.productos.categoria_ia jsonb {categoria, subcategoria} — la categoría de precios
//     (id_categoria → margen %) NO se toca.
//   · mos.taxonomia_reglas: las reglas del clasificador viven en la BD → productos FUTUROS
//     se clasifican solos (mos.clasificar_producto(nombre, descIA): 1º nombre, 2º ficha).
//   · Herencia AUTOMÁTICA (triggers):
//       PRESENTACIÓN (insert)  → marca + descripcion_ia + categoria_ia del líder (canónico o derivado)
//       DERIVADO     (insert)  → descripcion_ia + categoria_ia del padre canónico, marca = 'TONYS'
//       CANÓNICO     (insert)  → categoria_ia auto-clasificada
//       CANÓNICO     (update de nombre o código de barra — editar producto / PN corregir código)
//                              → re-clasifica + marca ia_refresh (el cron re-busca la ficha)
//       Cascada: cambiar ficha/marca/categoría del líder re-evalúa TODO el árbol
//                (derivados → sus presentaciones incluidas).
//   · ia_desc_pendientes ahora también devuelve los ia_refresh (re-búsqueda por edición).
//   · ia_guardar_descripcion: guarda + re-clasifica + PROPAGA el árbol (corre en replica,
//     los triggers no ven ese update — la propagación va explícita).
// Backfill: canónicos desde el clasificador aprobado, luego derivados y presentaciones.
import fs from 'fs';
import pkg from 'pg';
import { REGLAS, clasificar } from './_tax_flat.mjs';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

// ── reglas aplanadas para la BD (JS \b → POSIX \y; sin lookaheads, ya eliminados) ──
const filas = [];
REGLAS.forEach(([pat, cat, subs], i) => {
  subs.forEach(([sp, sub], j) => {
    filas.push([(i + 1) * 100 + j, pat.replaceAll('\\b', '\\y'), sp ? sp.replaceAll('\\b', '\\y') : null, cat, sub]);
  });
});

const DDL = String.raw`
alter table mos.productos add column if not exists categoria_ia jsonb;
alter table mos.productos add column if not exists ia_refresh boolean not null default false;

create table if not exists mos.taxonomia_reglas (
  orden int primary key,
  patron text not null,          -- regex POSIX (~*) sobre el texto
  patron2 text,                  -- sub-condición; null = default de la regla
  categoria text not null,
  subcategoria text not null
);

create or replace function mos.clasificar_producto(p_nombre text, p_dia text default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_txt text; v_cat text; v_sub text;
begin
  for v_txt in
    select x from (values
      (1, coalesce(p_nombre,'')),
      (2, (select string_agg(l, ' ') from unnest(string_to_array(coalesce(p_dia,''), E'\n')) l
            where l ~ '^(🧪|📋|✅)'))
    ) t(o, x) where coalesce(x,'') <> '' order by t.o
  loop
    select r.categoria, r.subcategoria into v_cat, v_sub
      from mos.taxonomia_reglas r
     where v_txt ~* r.patron and (r.patron2 is null or v_txt ~* r.patron2)
     order by r.orden limit 1;
    if v_cat is not null then
      return jsonb_build_object('categoria', v_cat, 'subcategoria', v_sub);
    end if;
  end loop;
  return null;
end $fn$;

-- herencia al NACER + re-evaluación al EDITAR nombre/código (editar producto, PN corregir código)
create or replace function mos._tg_herencia_ficha() returns trigger
language plpgsql security definer set search_path to '' as $fn$
declare v_l record;
begin
  if tg_op = 'INSERT' then
    if new.tipo_producto::text = 'CANONICO' then
      if new.categoria_ia is null then
        new.categoria_ia := coalesce(
          mos.clasificar_producto(new.descripcion, new.descripcion_ia),
          case when nullif(btrim(coalesce(new.id_categoria,'')),'') is not null
               then jsonb_build_object('categoria', new.id_categoria, 'subcategoria', 'Por clasificar') end);
      end if;
    elsif new.tipo_producto::text = 'PRESENTACION' then
      select marca, descripcion_ia, categoria_ia into v_l from mos.productos
       where sku_base = new.sku_base and tipo_producto::text in ('CANONICO','DERIVADO')
         and codigo_barra is distinct from new.codigo_barra
       limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
        if nullif(btrim(coalesce(v_l.marca,'')),'') is not null then new.marca := v_l.marca; end if;
      end if;
    elsif new.tipo_producto::text = 'DERIVADO' then
      select descripcion_ia, categoria_ia into v_l from mos.productos
       where sku_base = new.codigo_producto_base and tipo_producto::text = 'CANONICO' limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
      end if;
      new.marca := 'TONYS';   -- envasado en almacén: marca de la casa, siempre
    end if;
  elsif tg_op = 'UPDATE' and new.tipo_producto::text = 'CANONICO'
        and (new.descripcion is distinct from old.descripcion
          or new.codigo_barra is distinct from old.codigo_barra) then
    -- identidad cambió → re-clasificar YA (por nombre) y pedir re-búsqueda de ficha al cron
    new.categoria_ia := coalesce(mos.clasificar_producto(new.descripcion, new.descripcion_ia), new.categoria_ia);
    new.ia_refresh := true;
  end if;
  return new;
end $fn$;
drop trigger if exists tg_herencia_ficha on mos.productos;
create trigger tg_herencia_ficha before insert or update of descripcion, codigo_barra
  on mos.productos for each row execute function mos._tg_herencia_ficha();

-- cascada: si cambia la ficha/marca/categoría de un líder, TODO su árbol se re-evalúa
create or replace function mos._tg_herencia_cascada() returns trigger
language plpgsql security definer set search_path to '' as $fn$
begin
  if pg_trigger_depth() > 4 then return null; end if;
  if new.tipo_producto::text = 'CANONICO' then
    update mos.productos d
       set descripcion_ia = new.descripcion_ia, categoria_ia = new.categoria_ia, marca = 'TONYS'
     where d.tipo_producto::text = 'DERIVADO' and d.codigo_producto_base = new.sku_base
       and (d.descripcion_ia is distinct from new.descripcion_ia
         or d.categoria_ia is distinct from new.categoria_ia
         or coalesce(d.marca,'') <> 'TONYS');
    update mos.productos pr
       set descripcion_ia = new.descripcion_ia, categoria_ia = new.categoria_ia,
           marca = case when nullif(btrim(coalesce(new.marca,'')),'') is not null then new.marca else pr.marca end
     where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = new.sku_base
       and (pr.descripcion_ia is distinct from new.descripcion_ia
         or pr.categoria_ia is distinct from new.categoria_ia
         or (nullif(btrim(coalesce(new.marca,'')),'') is not null and pr.marca is distinct from new.marca));
  elsif new.tipo_producto::text = 'DERIVADO' then
    update mos.productos pr
       set descripcion_ia = new.descripcion_ia, categoria_ia = new.categoria_ia, marca = 'TONYS'
     where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = new.sku_base
       and (pr.descripcion_ia is distinct from new.descripcion_ia
         or pr.categoria_ia is distinct from new.categoria_ia
         or coalesce(pr.marca,'') <> 'TONYS');
  end if;
  return null;
end $fn$;
drop trigger if exists tg_herencia_cascada on mos.productos;
create trigger tg_herencia_cascada after update of marca, descripcion_ia, categoria_ia
  on mos.productos for each row
  when (old.marca is distinct from new.marca
     or old.descripcion_ia is distinct from new.descripcion_ia
     or old.categoria_ia is distinct from new.categoria_ia)
  execute function mos._tg_herencia_cascada();`;

const PEND = String.raw`
create or replace function mos.ia_desc_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object(
             'codigo_barra', pr.codigo_barra,
             'descripcion',  pr.descripcion,
             'marca_actual', coalesce(nullif(btrim(pr.marca),''),''),
             'equivalentes', coalesce((select string_agg(e.codigo_barra, ', ')
                                         from mos.equivalencias e
                                        where e.sku_base = pr.sku_base and e.activo), '')
           ) as x
      from mos.productos pr
     where pr.tipo_producto::text = 'CANONICO'
       and coalesce(pr.estado, true) = true
       and coalesce(pr.es_insumo, false) = false
       and length(btrim(pr.descripcion)) >= 6
       and pr.descripcion !~* '^[0-9 .,x*/-]+\s*(metros?|unidades?|mil(lar)?|cm|mm|gr?|kg|ml|lt|litros?)?\.?\s*$'
       and ( pr.ia_refresh = true            -- editaron nombre/código (o PN corrigió código): re-búsqueda
          or (pr.descripcion_ia is null      -- nuevo sin ficha (el backlog histórico ya está comido)
              and coalesce(pr.fecha_creacion, pr.created_at) > now() - interval '7 days') )
     order by pr.ia_refresh desc, coalesce(pr.fecha_creacion, pr.created_at) desc
     limit least(greatest(coalesce((p->>'max')::int, 2), 1), 5)
  ) t;
$fn$;
revoke all on function mos.ia_desc_pendientes(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_desc_pendientes(jsonb) to service_role;`;

const GUARDAR = String.raw`
create or replace function mos.ia_guardar_descripcion(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod text := btrim(coalesce(p->>'codigoBarra',''));
  v_txt text := coalesce(p->>'texto','');
  v_marca text := btrim(coalesce(p->>'marca',''));
  v_sku text; v_refresh boolean; v_n int;
begin
  if v_cod = '' then return jsonb_build_object('ok',false,'error','codigoBarra requerido'); end if;
  if length(v_txt) < 60 or position('🏷' in v_txt) = 0 or position('✅' in v_txt) = 0 then
    return jsonb_build_object('ok',false,'error','FORMATO: faltan las líneas 🏷…✅');
  end if;
  select sku_base, coalesce(ia_refresh,false) into v_sku, v_refresh
    from mos.productos where codigo_barra = v_cod and tipo_producto::text = 'CANONICO';
  if v_sku is null then return jsonb_build_object('ok',false,'error','canónico no existe'); end if;

  -- sin bump de catálogo (replica ⇒ tampoco corren los triggers: la propagación va explícita)
  set local session_replication_role = replica;
  update mos.productos
     set descripcion_ia = v_txt,
         marca = case when v_refresh and v_marca <> '' then v_marca      -- re-búsqueda: la ficha nueva manda
                      when nullif(btrim(coalesce(marca,'')),'') is null and v_marca <> '' then v_marca
                      else marca end,
         categoria_ia = case when v_refresh or categoria_ia is null
                                  or categoria_ia->>'subcategoria' = 'Por clasificar'
                             then coalesce(mos.clasificar_producto(descripcion, v_txt), categoria_ia)
                             else categoria_ia end,
         ia_refresh = false
   where codigo_barra = v_cod and tipo_producto::text = 'CANONICO';
  get diagnostics v_n = row_count;
  if v_n <> 1 then return jsonb_build_object('ok',false,'actualizados',v_n); end if;

  -- ÁRBOL COMPLETO: derivados TONYS → presentaciones del canónico → presentaciones de los derivados
  update mos.productos d
     set descripcion_ia = c.descripcion_ia, categoria_ia = c.categoria_ia, marca = 'TONYS'
    from mos.productos c
   where c.codigo_barra = v_cod and c.tipo_producto::text='CANONICO'
     and d.tipo_producto::text = 'DERIVADO' and d.codigo_producto_base = c.sku_base;
  update mos.productos pr
     set descripcion_ia = c.descripcion_ia, categoria_ia = c.categoria_ia,
         marca = case when nullif(btrim(coalesce(c.marca,'')),'') is not null then c.marca else pr.marca end
    from mos.productos c
   where c.codigo_barra = v_cod and c.tipo_producto::text='CANONICO'
     and pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = c.sku_base;
  update mos.productos pr
     set descripcion_ia = d.descripcion_ia, categoria_ia = d.categoria_ia, marca = 'TONYS'
    from mos.productos d
   where d.tipo_producto::text = 'DERIVADO' and d.codigo_producto_base = v_sku
     and pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = d.sku_base;

  return jsonb_build_object('ok', true, 'actualizados', 1, 'refresh', v_refresh);
end; $fn$;
revoke all on function mos.ia_guardar_descripcion(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_guardar_descripcion(jsonb) to service_role;`;

async function aplicarDDL() {
  await c.query(DDL);
  await c.query('truncate mos.taxonomia_reglas');
  for (const f of filas)
    await c.query('insert into mos.taxonomia_reglas(orden,patron,patron2,categoria,subcategoria) values ($1,$2,$3,$4,$5)', f);
  await c.query(PEND); await c.query(GUARDAR);
}

const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };

// ══ FASE 1: tests en transacción (ROLLBACK) ══
await c.query('begin');
await aplicarDDL();

// 1) el clasificador SQL debe COINCIDIR con el JS aprobado en los 1557
{
  const rows = (await c.query(`select codigo_barra, descripcion, coalesce(descripcion_ia,'') dia,
      mos.clasificar_producto(descripcion, descripcion_ia) r
    from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true) and descripcion_ia is not null`)).rows;
  let dif = 0, sin = 0; const ejemplos = [];
  for (const p of rows) {
    const js = clasificar(p.descripcion, p.dia);
    const sq = p.r;
    if (!sq) { sin++; ejemplos.push('SIN: ' + p.descripcion); continue; }
    if (!js || js.cat !== sq.categoria || js.sub !== sq.subcategoria) {
      dif++; if (ejemplos.length < 8) ejemplos.push(`${p.descripcion}: JS ${js?.cat}/${js?.sub} ≠ SQL ${sq.categoria}/${sq.subcategoria}`);
    }
  }
  chk('clasificador SQL == JS en 1557 canónicos', dif === 0 && sin === 0, `dif=${dif} sin=${sin} ${ejemplos.join(' | ')}`.slice(0, 200));
}

// producto real de apoyo: un canónico con ficha y marca
const lider = (await c.query(`select codigo_barra, sku_base, descripcion, marca, descripcion_ia, categoria_ia
  from mos.productos where tipo_producto::text='CANONICO' and descripcion_ia is not null
    and nullif(btrim(coalesce(marca,'')),'') is not null and coalesce(estado,true) limit 1`)).rows[0];

// 2) INSERT canónico → categoria_ia automática
await c.query(`insert into mos.productos (id_producto, sku_base, codigo_barra, descripcion, tipo_producto, estado, precio_venta, fecha_creacion)
  values ('IDTEST639C','LEVT639C','TEST639CANON','GALLETA SODA TEST FAMILIAR 6PACK','CANONICO',true,10,now())`);
{
  const r = (await c.query(`select categoria_ia from mos.productos where codigo_barra='TEST639CANON'`)).rows[0].categoria_ia;
  chk('canónico nuevo se auto-clasifica', r && r.categoria === 'GALLETAS_SNACKS' && r.subcategoria === 'Galletas saladas', JSON.stringify(r));
}
// 3) INSERT presentación bajo líder real → hereda los 3 campos
await c.query(`insert into mos.productos (id_producto, sku_base, codigo_barra, descripcion, tipo_producto, estado, precio_venta, factor_conversion, fecha_creacion)
  values ('IDTEST639P', $1, 'TEST639PRES', 'PRES TEST · 3 un', 'PRESENTACION', true, 30, 3, now())`, [lider.sku_base]);
{
  const r = (await c.query(`select marca, descripcion_ia, categoria_ia from mos.productos where codigo_barra='TEST639PRES'`)).rows[0];
  chk('presentación hereda marca+ficha+categoría del líder',
    r.marca === lider.marca && r.descripcion_ia === lider.descripcion_ia && JSON.stringify(r.categoria_ia) === JSON.stringify(lider.categoria_ia),
    `marca=${r.marca}`);
}
// 4) INSERT derivado → TONYS + ficha del padre
await c.query(`insert into mos.productos (id_producto, sku_base, codigo_barra, descripcion, tipo_producto, estado, precio_venta, codigo_producto_base, factor_conversion_base, fecha_creacion)
  values ('IDTEST639D', 'LEVT639D', 'TEST639DERIV', 'DERIV TEST 1KG', 'DERIVADO', true, 12, $1, 1, now())`, [lider.sku_base]);
{
  const r = (await c.query(`select marca, descripcion_ia, categoria_ia from mos.productos where codigo_barra='TEST639DERIV'`)).rows[0];
  chk('derivado hereda ficha del padre y marca=TONYS',
    r.marca === 'TONYS' && r.descripcion_ia === lider.descripcion_ia && JSON.stringify(r.categoria_ia) === JSON.stringify(lider.categoria_ia), `marca=${r.marca}`);
}
// 5) presentación DEL DERIVADO → hereda del derivado (TONYS en cascada al nacer)
await c.query(`insert into mos.productos (id_producto, sku_base, codigo_barra, descripcion, tipo_producto, estado, precio_venta, factor_conversion, fecha_creacion)
  values ('IDTEST639PD', 'LEVT639D', 'TEST639PRESD', 'PRES DERIV TEST · 3 un', 'PRESENTACION', true, 33, 3, now())`);
{
  const r = (await c.query(`select marca, descripcion_ia from mos.productos where codigo_barra='TEST639PRESD'`)).rows[0];
  chk('presentación de derivado nace TONYS con ficha', r.marca === 'TONYS' && r.descripcion_ia === lider.descripcion_ia, `marca=${r.marca}`);
}
// 6) EDITAR nombre del canónico test → re-clasifica + ia_refresh + cascada al árbol
await c.query(`update mos.productos set descripcion='VINAGRE DE MANZANA TEST 500ML' where codigo_barra='TEST639CANON'`);
{
  const r = (await c.query(`select categoria_ia, ia_refresh from mos.productos where codigo_barra='TEST639CANON'`)).rows[0];
  chk('editar nombre re-clasifica y marca ia_refresh',
    r.categoria_ia?.categoria === 'VINAGRES' && r.categoria_ia?.subcategoria === 'Vinagre de manzana' && r.ia_refresh === true,
    JSON.stringify(r.categoria_ia));
}
// 7) cambiar ficha del líder real → árbol completo (derivado test + sus presentaciones) re-evaluado
await c.query(`update mos.productos set descripcion_ia = descripcion_ia || E'\nEDIT639' where codigo_barra=$1`, [lider.codigo_barra]);
{
  const r = (await c.query(`select
      (select descripcion_ia from mos.productos where codigo_barra='TEST639DERIV') d,
      (select descripcion_ia from mos.productos where codigo_barra='TEST639PRES') p,
      (select descripcion_ia from mos.productos where codigo_barra='TEST639PRESD') pd`)).rows[0];
  const okc = [r.d, r.p, r.pd].every(x => (x || '').endsWith('EDIT639'));
  chk('cascada líder→derivado→presentaciones (árbol completo)', okc, okc ? '3/3 propagados' : 'FALTÓ propagar');
}
// 8) PN corregir código (update codigo_barra) → ia_refresh
await c.query(`update mos.productos set ia_refresh=false where codigo_barra='TEST639CANON'`);
await c.query(`update mos.productos set codigo_barra='TEST639CANON2' where codigo_barra='TEST639CANON'`);
{
  const r = (await c.query(`select ia_refresh from mos.productos where codigo_barra='TEST639CANON2'`)).rows[0];
  chk('corregir código de barras marca ia_refresh (re-búsqueda IA)', r.ia_refresh === true, '');
}
// 9) ia_desc_pendientes devuelve el refresh
{
  const r = (await c.query(`select mos.ia_desc_pendientes('{"max":5}'::jsonb) r`)).rows[0].r;
  chk('pendientes incluye el ia_refresh', Array.isArray(r) && r.some(x => x.codigo_barra === 'TEST639CANON2'), 'n=' + r.length);
}
// 10) ia_guardar_descripcion: guarda + re-clasifica + limpia flag + propaga árbol
{
  const txt = '🏷 Marca: TESTMARCA639\n🧪 Hecho de: vinagre de manzana fermentado\n📋 Composición: ácido acético de manzana\n📦 Presentación: botella 500 ml\n🎨 Características: líquido ámbar translúcido\n✅ Usos y beneficios: aderezos y conservas';
  const g = (await c.query(`select mos.ia_guardar_descripcion($1::jsonb) r`, [JSON.stringify({ codigoBarra: 'TEST639CANON2', texto: txt, marca: 'TESTMARCA639' })])).rows[0].r;
  const r = (await c.query(`select marca, ia_refresh, categoria_ia from mos.productos where codigo_barra='TEST639CANON2'`)).rows[0];
  chk('ia_guardar en refresh: marca nueva + flag limpio + re-clasifica',
    g.ok === true && r.marca === 'TESTMARCA639' && r.ia_refresh === false && r.categoria_ia?.categoria === 'VINAGRES', JSON.stringify(g));
}
// 11) crear_producto (RPC real de +producto/+presentación/+derivado) pasa por la herencia
{
  // el set local replica del test 10 vive hasta el fin de ESTA tx (en prod cada RPC es su tx) → reset
  await c.query(`set local session_replication_role = origin`);
  // _claim_ok acepta claim vacío (sesión directa) o app='MOS'
  const rp = (await c.query(`select mos.crear_producto($1::jsonb) r`, [JSON.stringify({
    descripcion: 'PRES RPC TEST · 2 un', precioVenta: 20, skuBase: lider.sku_base, factorConversion: 2, codigoBarra: 'TEST639RPC', usuario: 'TEST-CLAUDE',
  })])).rows[0].r;
  if (rp.ok) {
    const r = (await c.query(`select marca, descripcion_ia is not null con_ficha, tipo_producto::text tp from mos.productos where codigo_barra='TEST639RPC'`)).rows[0];
    chk('crear_producto (RPC real) → presentación hereda', r.tp === 'PRESENTACION' && r.marca === lider.marca && r.con_ficha === true, JSON.stringify(r));
  } else {
    chk('crear_producto (RPC real) → presentación hereda', false, 'RPC bloqueó: ' + JSON.stringify(rp));
  }
}
t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 160) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} tests fallaron — NO se aplica nada`); await c.end(); process.exit(1); }

// ══ FASE 2: aplicar de verdad + BACKFILL ══
await c.query('begin');
await aplicarDDL();
// backfill en replica: sin triggers (la herencia va explícita aquí) y sin 2,000 bumps de catálogo
await c.query(`set local session_replication_role = replica`);

// canónicos: asignación del clasificador aprobado (JS, con ficha como 2ª pasada)
const canon = (await c.query(`select codigo_barra, descripcion, coalesce(descripcion_ia,'') dia
  from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true) and descripcion_ia is not null`)).rows;
const vals = [];
for (const p of canon) {
  const h = clasificar(p.descripcion, p.dia);
  if (h) vals.push([p.codigo_barra, JSON.stringify({ categoria: h.cat, subcategoria: h.sub })]);
}
await c.query(`create temp table _asig (codigo text primary key, cat jsonb) on commit drop`);
for (let i = 0; i < vals.length; i += 200) {
  const lote = vals.slice(i, i + 200);
  const ph = lote.map((_, j) => `($${j * 2 + 1}, $${j * 2 + 2}::jsonb)`).join(',');
  await c.query(`insert into _asig values ${ph}`, lote.flat());
}
const r1 = await c.query(`update mos.productos p set categoria_ia = a.cat
  from _asig a where p.codigo_barra = a.codigo and p.tipo_producto::text='CANONICO'`);
// derivados: ficha+categoría del padre canónico, marca TONYS (todos)
const r2 = await c.query(`update mos.productos d
   set descripcion_ia = coalesce(c.descripcion_ia, d.descripcion_ia),
       categoria_ia   = coalesce(c.categoria_ia,   d.categoria_ia),
       marca = 'TONYS'
  from mos.productos c
 where d.tipo_producto::text='DERIVADO' and c.tipo_producto::text='CANONICO'
   and c.sku_base = d.codigo_producto_base`);
const r2b = await c.query(`update mos.productos set marca='TONYS'
 where tipo_producto::text='DERIVADO' and coalesce(marca,'') <> 'TONYS'`);
// presentaciones: del líder (canónico o derivado, ya actualizados arriba)
const r3 = await c.query(`update mos.productos pr
   set descripcion_ia = coalesce(l.descripcion_ia, pr.descripcion_ia),
       categoria_ia   = coalesce(l.categoria_ia,   pr.categoria_ia),
       marca = case when nullif(btrim(coalesce(l.marca,'')),'') is not null then l.marca else pr.marca end
  from mos.productos l
 where pr.tipo_producto::text='PRESENTACION'
   and l.sku_base = pr.sku_base and l.tipo_producto::text in ('CANONICO','DERIVADO')`);

// verificación dura antes de commitear
const v = (await c.query(`select
  (select count(*) from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true) and categoria_ia is not null) canon_cat,
  (select count(*) from mos.productos where tipo_producto::text='DERIVADO' and coalesce(estado,true) and marca='TONYS') deriv_tonys,
  (select count(*) from mos.productos where tipo_producto::text='DERIVADO' and coalesce(estado,true)) deriv_tot,
  (select count(*) from mos.productos where tipo_producto::text='PRESENTACION' and coalesce(estado,true) and categoria_ia is not null) pres_cat,
  (select count(*) from mos.productos where tipo_producto::text='PRESENTACION' and coalesce(estado,true)) pres_tot`)).rows[0];
console.log(`\nbackfill: canónicos ${r1.rowCount} · derivados ${r2.rowCount}+${r2b.rowCount} · presentaciones ${r3.rowCount}`);
console.log(`verifica: canon con categoría=${v.canon_cat} · derivados TONYS=${v.deriv_tonys}/${v.deriv_tot} · presentaciones con categoría=${v.pres_cat}/${v.pres_tot}`);
if (Number(v.canon_cat) < 1557 || v.deriv_tonys !== v.deriv_tot) {
  console.log('❌ verificación falló — ROLLBACK'); await c.query('rollback'); await c.end(); process.exit(1);
}
await c.query('commit');
// un solo bump de catálogo para que las apps re-descarguen marca/categoría (fuera de replica)
await c.query(`update mos.productos set updated_at = updated_at where codigo_barra = $1`, [canon[0].codigo_barra]);
console.log(`\n✅ ${t.length}/${t.length} tests + backfill aplicado (bump de catálogo único emitido)`);
await c.end();
