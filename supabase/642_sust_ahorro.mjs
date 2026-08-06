// 642 · AHORRO DE TOKENS en sustitutos (pedido dueño: "no gastar a lo loco, también al
// crear/editar producto"):
//   ANTES: producto nuevo/ficha editada → TODA la subcategoría stale (~30 líderes × IA
//          ≈ $0.60 por producto nuevo). A LO LOCO.
//   AHORA (reciprocidad): solo SELF se regenera. Cuando X guarda sus internos, marca
//   stale ÚNICAMENTE a los ≤3 elegidos que aún no lo referencian (si X eligió a Alacena,
//   Alacena re-evalúa y puede adoptar a X — el caso Alpaso/Alacena se cubre con ≤3
//   re-evaluaciones, no ~30). Converge: si B ya lista a X, no se re-marca (sin ping-pong).
//   + dieta de prompt: candidatos 40→25, ficha recortada, max_tokens 1000→700 (Edge).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const SQL = String.raw`
-- candidatos 40 → 25 (suficiente variedad, ~40% menos tokens de entrada)
create or replace function mos.sust_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  with lid as (
    select pr.codigo_barra, pr.descripcion, pr.marca, pr.unidad, pr.descripcion_ia,
           pr.tipo_producto::text tipo,
           pr.categoria_ia->>'categoria' catg, pr.categoria_ia->>'subcategoria' subc,
           coalesce(nullif(btrim(pr.codigo_producto_base),''), pr.sku_base) raiz
      from mos.productos pr
     where pr.tipo_producto::text in ('CANONICO','DERIVADO')
       and coalesce(pr.estado, true) and coalesce(pr.es_insumo, false) = false
       and pr.descripcion_ia is not null and pr.categoria_ia is not null
       and (pr.sust_stale or pr.sustitutos_internos is null)
     order by pr.sust_intentos asc, pr.sust_stale desc, pr.codigo_barra
     limit least(greatest(coalesce((p->>'max')::int, 2), 1), 5)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'codigo_barra', l.codigo_barra, 'descripcion', l.descripcion,
      'marca', coalesce(l.marca, ''), 'unidad', coalesce(l.unidad, ''),
      'tipo', l.tipo, 'categoria', l.catg, 'subcategoria', l.subc,
      'ficha', l.descripcion_ia, 'candidatos', cand.arr)), '[]'::jsonb)
    from lid l
    cross join lateral (
      select coalesce(jsonb_agg(x.j), '[]'::jsonb) arr from (
        select jsonb_build_object('sku', cd.sku_base, 'cod', cd.codigo_barra,
                 'nombre', cd.descripcion, 'sub', cd.categoria_ia->>'subcategoria') j
          from mos.productos cd
         where cd.tipo_producto::text in ('CANONICO','DERIVADO')
           and coalesce(cd.estado, true) and coalesce(cd.es_insumo, false) = false
           and cd.categoria_ia->>'categoria' = l.catg
           and coalesce(nullif(btrim(cd.codigo_producto_base),''), cd.sku_base) <> l.raiz
           and cd.codigo_barra <> l.codigo_barra
         order by (cd.categoria_ia->>'subcategoria' = l.subc) desc, length(cd.descripcion)
         limit 25
      ) x
    ) cand;
$fn$;

-- ficha nueva/editada → SOLO self (la reciprocidad de sust_guardar hace el resto)
create or replace function mos._ia_marcar_sust(p_cod text, p_sub text)
returns void language sql security definer set search_path to '' as $fn$
  update mos.productos set sust_stale = true where codigo_barra = p_cod;
$fn$;

-- guardar v2: + RECIPROCIDAD acotada (≤3 elegidos re-evalúan, solo si aún no referencian a X)
create or replace function mos.sust_guardar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod text := btrim(coalesce(p->>'codigoBarra',''));
  v_h record; v_raiz text;
  v_int jsonb := '[]'::jsonb; v_ext jsonb := '[]'::jsonb;
  e jsonb; t record; v_n int := 0; v_rec int := 0;
begin
  if v_cod = '' then return jsonb_build_object('ok',false,'error','codigoBarra requerido'); end if;
  select codigo_barra, sku_base, coalesce(nullif(btrim(codigo_producto_base),''), sku_base) raiz
    into v_h from mos.productos
   where codigo_barra = v_cod and tipo_producto::text in ('CANONICO','DERIVADO');
  if v_h.codigo_barra is null then return jsonb_build_object('ok',false,'error','líder no existe'); end if;
  v_raiz := v_h.raiz;

  for e in select * from jsonb_array_elements(coalesce(p->'internos','[]'::jsonb)) loop
    exit when jsonb_array_length(v_int) >= 3;
    select cd.sku_base, cd.codigo_barra, cd.descripcion, cd.categoria_ia->>'subcategoria' sub
      into t from mos.productos cd
     where cd.codigo_barra = btrim(coalesce(e->>'cod',''))
       and cd.tipo_producto::text in ('CANONICO','DERIVADO')
       and coalesce(cd.estado, true)
       and coalesce(nullif(btrim(cd.codigo_producto_base),''), cd.sku_base) <> v_raiz;
    if t.codigo_barra is not null then
      v_int := v_int || jsonb_build_object('sku', t.sku_base, 'cod', t.codigo_barra,
        'nombre', t.descripcion, 'sub', t.sub, 'motivo', left(btrim(coalesce(e->>'motivo','')), 140));
    end if;
  end loop;

  for e in select * from jsonb_array_elements(coalesce(p->'externos','[]'::jsonb)) loop
    exit when jsonb_array_length(v_ext) >= 3;
    if btrim(coalesce(e->>'nombre','')) <> '' then
      v_ext := v_ext || jsonb_build_object(
        'nombre', left(btrim(e->>'nombre'), 120), 'marca', left(btrim(coalesce(e->>'marca','')), 60),
        'presentacion', left(btrim(coalesce(e->>'presentacion','')), 90),
        'motivo', left(btrim(coalesce(e->>'motivo','')), 140));
    end if;
  end loop;

  set local session_replication_role = replica;
  update mos.productos
     set sustitutos_internos = v_int, sustitutos_externos = v_ext,
         sust_stale = false, sust_intentos = 0
   where codigo_barra = v_cod;
  update mos.productos pr
     set sustitutos_internos = v_int, sustitutos_externos = v_ext
   where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = v_h.sku_base;
  get diagnostics v_n = row_count;

  -- RECIPROCIDAD: mis elegidos me consideran de vuelta (solo si aún no me listan y ya
  -- tienen sustitutos calculados — durante el backfill los null van a pasar igual por la cola)
  update mos.productos t2
     set sust_stale = true
   where t2.codigo_barra in (select jsonb_array_elements(v_int)->>'cod')
     and t2.sustitutos_internos is not null
     and t2.sust_stale = false
     and not exists (select 1 from jsonb_array_elements(t2.sustitutos_internos) z
                      where z->>'cod' = v_cod);
  get diagnostics v_rec = row_count;

  return jsonb_build_object('ok', true, 'internos', jsonb_array_length(v_int),
    'externos', jsonb_array_length(v_ext), 'presentaciones', v_n, 'reciprocos', v_rec);
end $fn$;
revoke all on function mos.sust_guardar(jsonb) from public, anon, authenticated;
grant execute on function mos.sust_guardar(jsonb) to service_role;`;

// herencia v5: FUERA el bloque "pares de subcategoría stale" del INSERT (era el derroche)
const FICHA = String.raw`
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
      select marca, descripcion_ia, categoria_ia, sustitutos_internos, sustitutos_externos
        into v_l from mos.productos
       where sku_base = new.sku_base and tipo_producto::text in ('CANONICO','DERIVADO')
         and codigo_barra is distinct from new.codigo_barra
       order by (descripcion_ia is not null) desc, (codigo_barra !~* '^PRE[0-9]') desc, length(descripcion) desc
       limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
        new.sustitutos_internos := coalesce(v_l.sustitutos_internos, new.sustitutos_internos);
        new.sustitutos_externos := coalesce(v_l.sustitutos_externos, new.sustitutos_externos);
        if nullif(btrim(coalesce(v_l.marca,'')),'') is not null then new.marca := v_l.marca; end if;
      end if;
    elsif new.tipo_producto::text = 'DERIVADO' then
      select descripcion_ia, categoria_ia into v_l from mos.productos
       where sku_base = new.codigo_producto_base and tipo_producto::text = 'CANONICO'
       order by (descripcion_ia is not null) desc, (codigo_barra !~* '^PRE[0-9]') desc, length(descripcion) desc
       limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
      end if;
      new.marca := 'TONYS';
    end if;
    -- [642] líder nuevo: sus sustitutos nacen solos (internos null → entra a la cola);
    -- los pares YA NO se re-evalúan en masa — la reciprocidad de sust_guardar los cubre.
  elsif tg_op = 'UPDATE' and new.tipo_producto::text = 'CANONICO'
        and (new.descripcion is distinct from old.descripcion
          or new.codigo_barra is distinct from old.codigo_barra) then
    new.categoria_ia := coalesce(mos.clasificar_producto(new.descripcion, new.descripcion_ia), new.categoria_ia);
    new.ia_refresh := true;
    new.sust_stale := true;
  end if;
  if new.categoria_ia is not null then
    new.id_categoria := coalesce(new.categoria_ia->>'categoria', new.id_categoria);
    perform mos._tax_registrar(new.categoria_ia->>'categoria', new.categoria_ia->>'subcategoria');
  end if;
  return new;
end $fn$;`;

const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };
await c.query('begin');
await c.query(SQL); await c.query(FICHA);

// líder real con sustitutos ya calculados (de los 137) para probar reciprocidad
const conSust = (await c.query(`select codigo_barra, sustitutos_internos si from mos.productos
  where tipo_producto::text in ('CANONICO','DERIVADO') and sustitutos_internos is not null
    and jsonb_array_length(sustitutos_internos) > 0 limit 1`)).rows[0];
const objetivo = conSust.si[0].cod;   // este ya está en la lista de conSust

// 1) producto nuevo NO arrastra a toda la subcategoría
{
  const sub = (await c.query(`select categoria_ia->>'subcategoria' s from mos.productos where codigo_barra=$1`, [conSust.codigo_barra])).rows[0].s;
  await c.query(`update mos.productos set sust_stale=false where categoria_ia->>'subcategoria'=$1`, [sub]);
  await c.query(`insert into mos.productos (id_producto, sku_base, codigo_barra, descripcion, tipo_producto, estado, precio_venta, categoria_ia, descripcion_ia, fecha_creacion)
    values ('IDT642','LEVT642','TEST642NUEVO','PRODUCTO NUEVO 642', 'CANONICO', true, 9,
            jsonb_build_object('categoria','ESPECIAS','subcategoria',$1::text), '🏷 x ✅ y', now())`, [sub]);
  const n = (await c.query(`select count(*) n from mos.productos where sust_stale and categoria_ia->>'subcategoria'=$1 and codigo_barra<>'TEST642NUEVO'`, [sub])).rows[0].n;
  const propio = (await c.query(`select sustitutos_internos is null pend from mos.productos where codigo_barra='TEST642NUEVO'`)).rows[0].pend;
  chk('producto nuevo: 0 pares re-evaluados en masa + él mismo entra a la cola', Number(n) === 0 && propio === true, `pares_stale=${n}`);
}
// 2) reciprocidad: guardo internos de TEST642NUEVO eligiendo a "objetivo" → objetivo queda stale
{
  const g = (await c.query(`select mos.sust_guardar($1::jsonb) r`, [JSON.stringify({
    codigoBarra: 'TEST642NUEVO', internos: [{ cod: objetivo, motivo: 'r' }], externos: [] })])).rows[0].r;
  await c.query(`set local session_replication_role = origin`);
  const st = (await c.query(`select sust_stale from mos.productos where codigo_barra=$1`, [objetivo])).rows[0].sust_stale;
  chk('reciprocidad: mi elegido re-evalúa (queda stale)', g.ok === true && g.reciprocos === 1 && st === true, JSON.stringify(g));
}
// 3) sin ping-pong: si el elegido YA me lista, no se re-marca
{
  await c.query(`update mos.productos set sust_stale=false,
      sustitutos_internos = coalesce(sustitutos_internos,'[]'::jsonb) || jsonb_build_object('sku','LEVT642','cod','TEST642NUEVO','nombre','x','sub','y')
    where codigo_barra=$1`, [objetivo]);
  const g = (await c.query(`select mos.sust_guardar($1::jsonb) r`, [JSON.stringify({
    codigoBarra: 'TEST642NUEVO', internos: [{ cod: objetivo, motivo: 'r' }], externos: [] })])).rows[0].r;
  await c.query(`set local session_replication_role = origin`);
  const st = (await c.query(`select sust_stale from mos.productos where codigo_barra=$1`, [objetivo])).rows[0].sust_stale;
  chk('sin ping-pong: si ya me lista, no se re-marca', g.reciprocos === 0 && st === false, JSON.stringify(g));
}
// 4) candidatos ahora son ≤25 y siguen sin familia
{
  await c.query(`update mos.productos set sust_stale=true where codigo_barra=$1`, [conSust.codigo_barra]);
  const r = (await c.query(`select mos.sust_pendientes('{"max":5}'::jsonb) r`)).rows[0].r;
  const yo = r.find(x => x.codigo_barra === conSust.codigo_barra) || r[0];
  chk('candidatos ≤25', yo && yo.candidatos.length <= 25 && yo.candidatos.length > 0, 'cands=' + yo?.candidatos.length);
}
t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 120) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} — NO se aplica`); await c.end(); process.exit(1); }
await c.query('begin'); await c.query(SQL); await c.query(FICHA); await c.query('commit');
console.log(`\n✅ ${t.length}/${t.length} — 642 aplicado (reciprocidad + dieta de candidatos)`);
await c.end();
