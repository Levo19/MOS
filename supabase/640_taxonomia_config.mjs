// 640 · TAXONOMÍA EN CONFIG + adiós al margen por categoría (decisión dueño):
//   · mos.taxonomia_catalogo: catálogo VIVO de subcategorías con descripción ("Incluye: …",
//     derivada de las reglas reales) y ejemplos (productos reales). Se AUTO-alimenta:
//     si la IA clasifica un producto en una categoría/subcategoría nueva (p.ej. HERRAMIENTAS),
//     aparece sola en config (mos._tax_registrar).
//   · mos.taxonomia_config: RPC para el panel Config→Categorías (categorías + subcategorías
//     + conteos + descripciones + ejemplos). El margen/modo por categoría MUERE en la UI;
//     el margen es por PRODUCTO (los campos por producto ya existen y se conservan).
//   · id_categoria pasa a ser ESPEJO de categoria_ia->>'categoria' (ya es seguro: ningún
//     motor de precios lee mos.categorias — verificado en toda la BD). Así filtros y
//     reportes existentes muestran la taxonomía IA sin tocar nada más.
//   · ia_guardar_descripcion acepta la propuesta 🗂 de la Edge (categoría/subcategoría
//     nuevas cuando el clasificador local no calza) y la registra.
import fs from 'fs';
import pkg from 'pg';
import { REGLAS } from './_tax_flat.mjs';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

// ── seed del catálogo: descripción = keywords legibles de las reglas · ejemplos = productos reales ──
const arbol = JSON.parse(fs.readFileSync('_tax_arbol.json', 'utf8'));
const kw = new Map();   // 'CAT│sub' → Set(keywords)
const limpiar = (pat) => pat.split('|').map(t => t
  .replace(/\\[bdy]|[\^\$\(\)\[\]\?\*\+\.]|\{\d.*?\}/g, ' ')
  .replace(/\s+/g, ' ').trim().toLowerCase())
  .filter(t => t && t.length >= 3 && !/[\\{}]/.test(t));
for (const [pat, cat, subs] of REGLAS) {
  for (const [sp, sub] of subs) {
    const k = cat + '│' + sub;
    if (!kw.has(k)) kw.set(k, new Set());
    limpiar(sp || pat).forEach(t => { if (kw.get(k).size < 10) kw.get(k).add(t); });
  }
}
const filas = [];
for (const [cat, subsObj] of Object.entries(arbol)) {
  for (const [sub, v] of Object.entries(subsObj)) {
    const kws = [...(kw.get(cat + '│' + sub) || [])].slice(0, 8);
    const desc = sub === 'Por revisar (nombre insuficiente)'
      ? 'Productos cuyo nombre no alcanza para clasificarlos — conviene renombrarlos.'
      : (kws.length ? 'Incluye: ' + kws.join(', ') + '.' : 'Subcategoría de ' + cat.replace(/_/g, ' ') + '.');
    filas.push([cat, sub, desc, (v.ej || []).slice(0, 3).join(' · ')]);
  }
}

const DDL = String.raw`
create table if not exists mos.taxonomia_catalogo (
  categoria    text not null,
  subcategoria text not null,
  descripcion  text not null default '',
  ejemplos     text not null default '',
  auto         boolean not null default false,   -- true = la detectó la IA sola
  creado       timestamptz not null default now(),
  primary key (categoria, subcategoria)
);

-- registro automático: categoría/subcategoría nueva → aparece sola en config
create or replace function mos._tax_registrar(p_cat text, p_sub text)
returns void language plpgsql security definer set search_path to '' as $fn$
begin
  if coalesce(btrim(p_cat),'') = '' or coalesce(btrim(p_sub),'') = '' then return; end if;
  insert into mos.categorias (id_categoria, nombre, descripcion, estado, fecha_creacion)
  values (upper(btrim(p_cat)), initcap(replace(btrim(p_cat), '_', ' ')),
          '🤖 Categoría nueva detectada por la IA — descripción pendiente', true, now())
  on conflict (id_categoria) do nothing;
  insert into mos.taxonomia_catalogo (categoria, subcategoria, descripcion, ejemplos, auto)
  values (upper(btrim(p_cat)), btrim(p_sub), '🤖 Subcategoría nueva detectada por la IA', '', true)
  on conflict (categoria, subcategoria) do nothing;
end $fn$;

-- panel Config→Categorías: categorías + subcategorías + conteos + descripciones + ejemplos
create or replace function mos.taxonomia_config(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  with cnt as (
    select categoria_ia->>'categoria' cat, categoria_ia->>'subcategoria' sub,
           count(*) n, count(*) filter (where tipo_producto::text='CANONICO') nc
      from mos.productos
     where coalesce(estado,true) and categoria_ia is not null
     group by 1, 2
  ),
  subs as (
    select t.categoria, t.subcategoria, t.descripcion, t.ejemplos, t.auto,
           coalesce(c1.n, 0) n
      from mos.taxonomia_catalogo t
      left join cnt c1 on c1.cat = t.categoria and c1.sub = t.subcategoria
  )
  select coalesce(jsonb_agg(x order by x->>'categoria'), '[]'::jsonb) from (
    select jsonb_build_object(
      'categoria',  s.categoria,
      'nombre',     coalesce(mc.nombre, initcap(replace(s.categoria,'_',' '))),
      'descripcion', coalesce(mc.descripcion, ''),
      'productos',  (select coalesce(sum(n),0) from subs z where z.categoria = s.categoria),
      'subcategorias', (select jsonb_agg(jsonb_build_object(
          'subcategoria', z.subcategoria, 'descripcion', z.descripcion,
          'ejemplos', z.ejemplos, 'auto', z.auto, 'productos', z.n) order by z.n desc, z.subcategoria)
        from subs z where z.categoria = s.categoria)
    ) x
    from (select distinct categoria from subs) s
    left join mos.categorias mc on mc.id_categoria = s.categoria
  ) t(x);
$fn$;
revoke all on function mos.taxonomia_config(jsonb) from public, anon;
grant execute on function mos.taxonomia_config(jsonb) to authenticated, service_role;`;

// ── trigger de herencia: + espejo id_categoria + registro en catálogo ──
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
      select marca, descripcion_ia, categoria_ia into v_l from mos.productos
       where sku_base = new.sku_base and tipo_producto::text in ('CANONICO','DERIVADO')
         and codigo_barra is distinct from new.codigo_barra
       order by (descripcion_ia is not null) desc, (codigo_barra !~* '^PRE[0-9]') desc, length(descripcion) desc
       limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
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
  elsif tg_op = 'UPDATE' and new.tipo_producto::text = 'CANONICO'
        and (new.descripcion is distinct from old.descripcion
          or new.codigo_barra is distinct from old.codigo_barra) then
    new.categoria_ia := coalesce(mos.clasificar_producto(new.descripcion, new.descripcion_ia), new.categoria_ia);
    new.ia_refresh := true;
  end if;
  -- [640] id_categoria = ESPEJO de la taxonomía IA + registro en el catálogo vivo
  if new.categoria_ia is not null then
    new.id_categoria := coalesce(new.categoria_ia->>'categoria', new.id_categoria);
    perform mos._tax_registrar(new.categoria_ia->>'categoria', new.categoria_ia->>'subcategoria');
  end if;
  return new;
end $fn$;`;

const CASCADA = String.raw`
create or replace function mos._tg_herencia_cascada() returns trigger
language plpgsql security definer set search_path to '' as $fn$
begin
  if pg_trigger_depth() > 4 then return null; end if;
  if new.tipo_producto::text = 'CANONICO' then
    update mos.productos d
       set descripcion_ia = coalesce(new.descripcion_ia, d.descripcion_ia),
           categoria_ia   = coalesce(new.categoria_ia,   d.categoria_ia),
           id_categoria   = coalesce(new.categoria_ia->>'categoria', d.id_categoria),
           marca = 'TONYS'
     where d.tipo_producto::text = 'DERIVADO' and d.codigo_producto_base = new.sku_base
       and (coalesce(new.descripcion_ia, d.descripcion_ia) is distinct from d.descripcion_ia
         or coalesce(new.categoria_ia, d.categoria_ia) is distinct from d.categoria_ia
         or coalesce(new.categoria_ia->>'categoria', d.id_categoria) is distinct from d.id_categoria
         or coalesce(d.marca,'') <> 'TONYS');
    update mos.productos pr
       set descripcion_ia = coalesce(new.descripcion_ia, pr.descripcion_ia),
           categoria_ia   = coalesce(new.categoria_ia,   pr.categoria_ia),
           id_categoria   = coalesce(new.categoria_ia->>'categoria', pr.id_categoria),
           marca = case when nullif(btrim(coalesce(new.marca,'')),'') is not null then new.marca else pr.marca end
     where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = new.sku_base
       and (coalesce(new.descripcion_ia, pr.descripcion_ia) is distinct from pr.descripcion_ia
         or coalesce(new.categoria_ia, pr.categoria_ia) is distinct from pr.categoria_ia
         or coalesce(new.categoria_ia->>'categoria', pr.id_categoria) is distinct from pr.id_categoria
         or (nullif(btrim(coalesce(new.marca,'')),'') is not null and pr.marca is distinct from new.marca));
  elsif new.tipo_producto::text = 'DERIVADO' then
    update mos.productos pr
       set descripcion_ia = coalesce(new.descripcion_ia, pr.descripcion_ia),
           categoria_ia   = coalesce(new.categoria_ia,   pr.categoria_ia),
           id_categoria   = coalesce(new.categoria_ia->>'categoria', pr.id_categoria),
           marca = 'TONYS'
     where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = new.sku_base
       and (coalesce(new.descripcion_ia, pr.descripcion_ia) is distinct from pr.descripcion_ia
         or coalesce(new.categoria_ia, pr.categoria_ia) is distinct from pr.categoria_ia
         or coalesce(new.categoria_ia->>'categoria', pr.id_categoria) is distinct from pr.id_categoria
         or coalesce(pr.marca,'') <> 'TONYS');
  end if;
  return null;
end $fn$;`;

// ── ia_guardar: acepta propuesta 🗂 de la Edge (categoría nueva) + espejo + registro ──
const GUARDAR = String.raw`
create or replace function mos.ia_guardar_descripcion(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod text := btrim(coalesce(p->>'codigoBarra',''));
  v_txt text := coalesce(p->>'texto','');
  v_marca text := btrim(coalesce(p->>'marca',''));
  v_pcat text := upper(btrim(coalesce(p->>'categoriaProp','')));
  v_psub text := btrim(coalesce(p->>'subcategoriaProp',''));
  v_prop jsonb := case when v_pcat <> '' and v_psub <> ''
                       then jsonb_build_object('categoria', v_pcat, 'subcategoria', v_psub) end;
  v_sku text; v_refresh boolean; v_cat jsonb; v_n int;
begin
  if v_cod = '' then return jsonb_build_object('ok',false,'error','codigoBarra requerido'); end if;
  if length(v_txt) < 60 or position('🏷' in v_txt) = 0 or position('✅' in v_txt) = 0 then
    return jsonb_build_object('ok',false,'error','FORMATO: faltan las líneas 🏷…✅');
  end if;
  select sku_base, coalesce(ia_refresh,false) into v_sku, v_refresh
    from mos.productos where codigo_barra = v_cod and tipo_producto::text = 'CANONICO';
  if v_sku is null then return jsonb_build_object('ok',false,'error','canónico no existe'); end if;

  set local session_replication_role = replica;
  update mos.productos
     set descripcion_ia = v_txt,
         marca = case when v_refresh and v_marca <> '' then v_marca
                      when nullif(btrim(coalesce(marca,'')),'') is null and v_marca <> '' then v_marca
                      else marca end,
         -- orden: nombre → PROPUESTA de la Edge (dominio nuevo, p.ej. HERRAMIENTAS) → ficha
         categoria_ia = case when v_refresh or categoria_ia is null
                                  or categoria_ia->>'subcategoria' = 'Por clasificar'
                             then coalesce(mos.clasificar_producto(descripcion, null), v_prop,
                                           mos.clasificar_producto(descripcion, v_txt), categoria_ia)
                             else categoria_ia end,
         ia_refresh = false
   where codigo_barra = v_cod and tipo_producto::text = 'CANONICO';
  get diagnostics v_n = row_count;
  if v_n <> 1 then return jsonb_build_object('ok',false,'actualizados',v_n); end if;

  select categoria_ia into v_cat from mos.productos where codigo_barra = v_cod;
  if v_cat is not null then
    perform mos._tax_registrar(v_cat->>'categoria', v_cat->>'subcategoria');
    update mos.productos set id_categoria = v_cat->>'categoria'
     where codigo_barra = v_cod and id_categoria is distinct from (v_cat->>'categoria');
  end if;

  -- árbol completo (replica: sin triggers → explícito), con espejo id_categoria
  update mos.productos d
     set descripcion_ia = c.descripcion_ia, categoria_ia = c.categoria_ia,
         id_categoria = coalesce(c.categoria_ia->>'categoria', d.id_categoria), marca = 'TONYS'
    from mos.productos c
   where c.codigo_barra = v_cod and c.tipo_producto::text='CANONICO'
     and d.tipo_producto::text = 'DERIVADO' and d.codigo_producto_base = c.sku_base;
  update mos.productos pr
     set descripcion_ia = c.descripcion_ia, categoria_ia = c.categoria_ia,
         id_categoria = coalesce(c.categoria_ia->>'categoria', pr.id_categoria),
         marca = case when nullif(btrim(coalesce(c.marca,'')),'') is not null then c.marca else pr.marca end
    from mos.productos c
   where c.codigo_barra = v_cod and c.tipo_producto::text='CANONICO'
     and pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = c.sku_base;
  update mos.productos pr
     set descripcion_ia = d.descripcion_ia, categoria_ia = d.categoria_ia,
         id_categoria = coalesce(d.categoria_ia->>'categoria', pr.id_categoria), marca = 'TONYS'
    from mos.productos d
   where d.tipo_producto::text = 'DERIVADO' and d.codigo_producto_base = v_sku
     and pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = d.sku_base;

  return jsonb_build_object('ok', true, 'actualizados', 1, 'refresh', v_refresh,
    'categoria', v_cat->>'categoria', 'subcategoria', v_cat->>'subcategoria');
end; $fn$;
revoke all on function mos.ia_guardar_descripcion(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_guardar_descripcion(jsonb) to service_role;`;

async function aplicar() {
  await c.query(DDL);
  // seed idempotente: pisa descripcion/ejemplos de las 108 conocidas, respeta las auto
  for (const f of filas)
    await c.query(`insert into mos.taxonomia_catalogo (categoria, subcategoria, descripcion, ejemplos, auto)
      values ($1,$2,$3,$4,false)
      on conflict (categoria, subcategoria) do update set descripcion=excluded.descripcion, ejemplos=excluded.ejemplos, auto=false`, f);
  // re-seed de reglas (fix \bANGO\b: "mango antideslizante" ya no cae en Cocoa)
  await c.query('truncate mos.taxonomia_reglas');
  const reglasFilas = [];
  REGLAS.forEach(([pat, cat, subs], i) => subs.forEach(([sp, sub], j) =>
    reglasFilas.push([(i + 1) * 100 + j, pat.replaceAll('\\b', '\\y'), sp ? sp.replaceAll('\\b', '\\y') : null, cat, sub])));
  for (const f of reglasFilas)
    await c.query('insert into mos.taxonomia_reglas(orden,patron,patron2,categoria,subcategoria) values ($1,$2,$3,$4,$5)', f);
  await c.query(FICHA); await c.query(CASCADA); await c.query(GUARDAR);
}

const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };

// ══ FASE 1: tests (tx + ROLLBACK) ══
await c.query('begin');
await aplicar();
// 1) taxonomia_config: 23 categorías, 108 subcategorías, con conteos y ejemplos
{
  const r = (await c.query(`select mos.taxonomia_config('{}'::jsonb) r`)).rows[0].r;
  const nsubs = r.reduce((a, x) => a + (x.subcategorias || []).length, 0);
  const conEj = r.every(x => (x.subcategorias || []).some(s => s.ejemplos));
  const esp = r.find(x => x.categoria === 'ESPECIAS');
  chk('taxonomia_config: 23 cat / 108 sub con conteos', r.length === 23 && nsubs === 108 && Number(esp.productos) > 200, `cat=${r.length} sub=${nsubs} especias=${esp?.productos}`);
  chk('subcategorías traen ejemplos reales', conEj, '');
}
// 2) espejo id_categoria al insertar
await c.query(`insert into mos.productos (id_producto, sku_base, codigo_barra, descripcion, tipo_producto, estado, precio_venta, fecha_creacion)
  values ('IDT640A','LEVT640A','TEST640VIN','VINAGRE DE MANZANA TEST 500ML','CANONICO',true,8,now())`);
{
  const r = (await c.query(`select id_categoria, categoria_ia from mos.productos where codigo_barra='TEST640VIN'`)).rows[0];
  chk('canónico nuevo: id_categoria = espejo de la IA', r.id_categoria === 'VINAGRES' && r.categoria_ia?.categoria === 'VINAGRES', JSON.stringify(r));
}
// 3) categoría NUEVA propuesta por la Edge (visión HERRAMIENTAS) → auto-aparece en config
await c.query(`insert into mos.productos (id_producto, sku_base, codigo_barra, descripcion, tipo_producto, estado, precio_venta, fecha_creacion)
  values ('IDT640B','LEVT640B','TEST640HER','MARTILLO CARPINTERO STANLEY 16OZ','CANONICO',true,35,now())`);
await c.query(`set local session_replication_role = origin`);
{
  const pre = (await c.query(`select categoria_ia from mos.productos where codigo_barra='TEST640HER'`)).rows[0];
  const txt = '🏷 Marca: STANLEY\n🧪 Hecho de: acero forjado y mango de fibra\n📋 Composición: cabeza de acero, mango antideslizante\n📦 Presentación: unidad, 16 onzas\n🎨 Características: cabeza pulida, mango amarillo/negro\n✅ Usos y beneficios: clavar y extraer clavos en carpintería';
  const g = (await c.query(`select mos.ia_guardar_descripcion($1::jsonb) r`, [JSON.stringify({ codigoBarra: 'TEST640HER', texto: txt, marca: 'STANLEY', categoriaProp: 'HERRAMIENTAS', subcategoriaProp: 'Martillos' })])).rows[0].r;
  await c.query(`set local session_replication_role = origin`);
  const r = (await c.query(`select id_categoria, categoria_ia from mos.productos where codigo_barra='TEST640HER'`)).rows[0];
  const cat = (await c.query(`select count(*) n from mos.categorias where id_categoria='HERRAMIENTAS'`)).rows[0].n;
  const sub = (await c.query(`select auto from mos.taxonomia_catalogo where categoria='HERRAMIENTAS' and subcategoria='Martillos'`)).rows[0];
  chk('categoría nueva (HERRAMIENTAS) auto-registrada por la IA',
    g.ok === true && r.id_categoria === 'HERRAMIENTAS' && r.categoria_ia?.subcategoria === 'Martillos' && Number(cat) === 1 && sub?.auto === true,
    `pre=${JSON.stringify(pre.categoria_ia)} → ${JSON.stringify(r.categoria_ia)}`);
  const cfg = (await c.query(`select mos.taxonomia_config('{}'::jsonb) r`)).rows[0].r;
  chk('config la muestra al instante', cfg.some(x => x.categoria === 'HERRAMIENTAS'), 'cats=' + cfg.length);
}
// 4) espejo en cascada: si cambia la categoría del líder, los hijos espejan id_categoria
{
  const lider = (await c.query(`select p.codigo_barra, p.sku_base from mos.productos p
    where p.tipo_producto::text='CANONICO' and p.descripcion_ia is not null
      and exists (select 1 from mos.productos h where h.sku_base=p.sku_base and h.tipo_producto::text='PRESENTACION')
    limit 1`)).rows[0];
  await c.query(`update mos.productos set categoria_ia = '{"categoria":"TESTCAT640","subcategoria":"Sub test"}'::jsonb
    where codigo_barra=$1`, [lider.codigo_barra]);
  const r = (await c.query(`select count(*) filter (where h.id_categoria = 'TESTCAT640') ok_n, count(*) tot
    from mos.productos h where h.tipo_producto::text='PRESENTACION' and h.sku_base=$1`, [lider.sku_base])).rows[0];
  chk('cascada espeja id_categoria en los hijos', Number(r.ok_n) === Number(r.tot) && Number(r.tot) > 0, JSON.stringify(r));
}
t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 140) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} — NO se aplica`); await c.end(); process.exit(1); }

// ══ FASE 2: aplicar + recompute (fix ANGO) + herencia + BACKFILL espejo ══
await c.query('begin');
await aplicar();
await c.query(`set local session_replication_role = replica`);
// recompute de canónicos con el clasificador corregido (solo cambian ~5)
const { clasificar } = await import('./_tax_flat.mjs');
const canon = (await c.query(`select codigo_barra, descripcion, coalesce(descripcion_ia,'') dia, categoria_ia
  from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true) and descripcion_ia is not null`)).rows;
let recls = 0;
for (const p of canon) {
  const h = clasificar(p.descripcion, p.dia);
  const nuevo = h ? { categoria: h.cat, subcategoria: h.sub } : { categoria: 'OTROS', subcategoria: 'Por clasificar' };
  if (JSON.stringify(nuevo) !== JSON.stringify(p.categoria_ia)) {
    await c.query(`update mos.productos set categoria_ia=$2::jsonb where codigo_barra=$1`, [p.codigo_barra, JSON.stringify(nuevo)]);
    recls++;
  }
}
// re-herencia de hijos con el líder real (idéntico criterio del trigger)
await c.query(`update mos.productos d
   set descripcion_ia = coalesce(c.descripcion_ia, d.descripcion_ia),
       categoria_ia   = coalesce(c.categoria_ia,   d.categoria_ia), marca='TONYS'
  from mos.productos c
 where d.tipo_producto::text='DERIVADO' and c.tipo_producto::text='CANONICO' and c.sku_base = d.codigo_producto_base`);
await c.query(`update mos.productos pr
   set descripcion_ia = coalesce(l.descripcion_ia, pr.descripcion_ia),
       categoria_ia   = coalesce(l.categoria_ia,   pr.categoria_ia),
       marca = case when nullif(btrim(coalesce(l.marca,'')),'') is not null then l.marca else pr.marca end
  from (select distinct on (x.sku_base) x.sku_base, x.marca, x.descripcion_ia, x.categoria_ia
          from mos.productos x where x.tipo_producto::text in ('CANONICO','DERIVADO')
         order by x.sku_base, (x.descripcion_ia is not null) desc, (x.codigo_barra !~* '^PRE[0-9]') desc, length(x.descripcion) desc) l
 where pr.tipo_producto::text='PRESENTACION' and l.sku_base = pr.sku_base`);
console.log('reclasificados por fix de regla:', recls);
const bf = await c.query(`update mos.productos
  set id_categoria = categoria_ia->>'categoria'
  where categoria_ia is not null and id_categoria is distinct from (categoria_ia->>'categoria')`);
const v = (await c.query(`select
  (select count(*) from mos.productos where categoria_ia is not null and id_categoria is distinct from (categoria_ia->>'categoria')) desal,
  (select count(*) from mos.taxonomia_catalogo) subs`)).rows[0];
console.log(`\nbackfill espejo id_categoria: ${bf.rowCount} realineados · desalineados restantes: ${v.desal} · catálogo subcats: ${v.subs}`);
if (Number(v.desal) > 0) { console.log('❌ — ROLLBACK'); await c.query('rollback'); await c.end(); process.exit(1); }
await c.query('commit');
await c.query(`update mos.productos set updated_at = updated_at where codigo_barra = (select codigo_barra from mos.productos where categoria_ia is not null limit 1)`);
console.log(`✅ ${t.length}/${t.length} tests + 640 aplicado (bump único emitido)`);
await c.end();
