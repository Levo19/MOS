// 656 · CATÁLOGO VIRTUAL PÚBLICO — RPC mos.catalogo_virtual()
//   La vitrina pública (mosgo.vercel.app/catalogo.html) lee ESTO y nada más.
//   Misma fuente que mos.ruta_boot (familias = producto base + presentaciones con 🚚),
//   pero DESNUDA de todo lo interno:
//     · SÍ viaja: nombre del líder, marca, concepto (subcategoría IA), unidad, foto,
//       escalera {label, precio, factor} y `disponible` (booleano, stock>0).
//     · NO viaja: precio_costo, margen_pct, precio_tope, stock NUMÉRICO, sku interno,
//       clientes, ni una sola columna de otro esquema que no sea el stock booleanizado.
//   El id es un hash corto del sku (ancla estable para el front) — no revela el SKU.
//   SECURITY DEFINER + search_path='' + statement_timeout 15s + GRANT a anon/authenticated.
//   Parche/creación con def VIVA verificada; tests dentro de begin/rollback antes de aplicar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const T = []; const chk = (n, cond, x) => { T.push([cond ? '✅' : '❌', n, x === undefined ? '' : String(x)]); return cond; };

// ── DDL ────────────────────────────────────────────────────────────────────────
// Espeja el armado de familias de mos.ruta_boot (fam_keys → basep → escalones):
// si mañana un producto entra a canal_mayoreo, aparece solo en la vitrina.
const DDL = `
create or replace function mos.catalogo_virtual()
returns jsonb
language sql
stable
security definer
set search_path to ''
set statement_timeout to '15s'
as $fn$
  with fam_keys as (
    select distinct coalesce(nullif(btrim(p.sku_base),''), p.id_producto) as fsku
      from mos.productos p
     where p.canal_mayoreo = true and p.tipo_producto::text <> 'PRESENTACION'
    union
    select distinct nullif(btrim(p.sku_base),'')
      from mos.productos p
     where p.canal_mayoreo = true and p.tipo_producto::text = 'PRESENTACION'
       and nullif(btrim(p.sku_base),'') is not null
  ),
  basep as (
    select k.fsku,
           pr.descripcion,
           coalesce(nullif(btrim(pr.categoria_ia->>'subcategoria'),''),
                    nullif(btrim(pr.categoria_ia->>'categoria'),''), 'OTROS') as concepto,
           coalesce(nullif(btrim(pr.marca),''), '') as marca,
           upper(coalesce(nullif(btrim(pr.unidad_medida),''), pr.unidad, 'NIU')) as um,
           coalesce(pr.canal_mayoreo, false) as base_mosgo,
           coalesce(pr.precio_venta, 0) as precio,
           coalesce(nullif(btrim(pr.foto_url),''), '') as foto,
           (coalesce(s.cantidad_disponible, 0) > 0) as disponible
      from fam_keys k
      join lateral (
        select * from mos.productos p
         where coalesce(nullif(btrim(p.sku_base),''), p.id_producto) = k.fsku
           and p.tipo_producto::text <> 'PRESENTACION'
           and coalesce(nullif(p.factor_conversion,0),1) = 1
         order by (upper(coalesce(nullif(btrim(p.unidad_medida),''), p.unidad,'')) = 'KGM') desc, p.id_producto
         limit 1) pr on true
      left join wh.stock s on upper(btrim(s.cod_producto)) = upper(btrim(pr.codigo_barra))
  )
  select jsonb_build_object(
    'ok', true,
    'generado', to_char(now() at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'total', (select count(*) from basep),
    'familias', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',         substr(md5(b.fsku), 1, 10),
               'nombre',     b.descripcion,
               'marca',      b.marca,
               'concepto',   b.concepto,
               'unidad',     case when b.um = 'KGM' then 'KGM' else 'NIU' end,
               'foto',       b.foto,
               'disponible', b.disponible,
               'escalones',  coalesce((
                  select jsonb_agg(x.j order by x.factor)
                    from (
                      -- escalón suelto: la unidad base, cuando MosGo la vende
                      select 1::numeric as factor,
                             jsonb_build_object(
                               'label',  case when b.um = 'KGM' then '1 kg' else '1 un' end,
                               'precio', round(b.precio, 2),
                               'factor', 1) as j
                       where b.base_mosgo and b.precio > 0
                      union all
                      -- presentaciones (packs) con precio propio
                      select lf.fac,
                             jsonb_build_object(
                               'label',  lb.txt,
                               'precio', round(coalesce(e.precio_venta,0), 2),
                               'factor', lf.fac) as j
                        from mos.productos e
                        cross join lateral (select coalesce(nullif(e.factor_conversion,0),1) as fac) lf
                        cross join lateral (select case when lf.fac = round(lf.fac)
                                                        then round(lf.fac)::bigint::text
                                                        else btrim(to_char(lf.fac,'FM999999990.999')) end as ft) lt
                        cross join lateral (select coalesce(nullif(
                                 case when position('·' in coalesce(e.descripcion,'')) > 0
                                      then btrim(split_part(e.descripcion, '·', 2))
                                      else btrim(replace(coalesce(e.descripcion,''), b.descripcion, '')) end, ''),
                                 coalesce(e.descripcion,'')) as s0) l0
                        cross join lateral (select case when b.um = 'KGM'
                                 then regexp_replace(l0.s0, '[(]([0-9.,]+)[[:space:]]*un[[:space:]]*[)]', '(\\1 kg)', 'gi')
                                 else l0.s0 end as s1) l1
                        cross join lateral (select replace(lt.ft, '.', '[.]') as fre) l2
                        cross join lateral (select case
                                 when lf.fac <= 1 then l1.s1
                                 when l1.s1 ~* ('[x×][[:space:]]*' || l2.fre || '([^0-9]|$)') then l1.s1
                                 when l1.s1 ~* ('(^|[^0-9])' || l2.fre || '[[:space:]]*(un|kg)([^a-z]|$)') then l1.s1
                                 else l1.s1 || ' ×' || lt.ft end as txt) lb
                       where e.canal_mayoreo = true
                         and e.tipo_producto::text = 'PRESENTACION'
                         and nullif(btrim(e.sku_base),'') = b.fsku
                         and coalesce(e.precio_venta,0) > 0
                         -- guarda KGM: un pack sin precio de etiqueta se cobra por kg en ME,
                         -- su precio nominal mentiría en la vitrina.
                         and (b.um <> 'KGM' or coalesce(e.precio_fijo,false))
                    ) x), '[]'::jsonb)
             ) order by b.concepto, upper(b.marca), b.descripcion)
        from basep b), '[]'::jsonb)
  )
$fn$;

revoke all on function mos.catalogo_virtual() from public;
grant execute on function mos.catalogo_virtual() to anon, authenticated;
`;

await c.query('begin');
await c.query(DDL);

// ── verificación de la def VIVA (lo que quedó, no lo que creí escribir) ────────
{
  const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'mos' and p.proname = 'catalogo_virtual'`)).rows[0];
  chk('def viva existe', !!d && !!d.d);
  chk('SECURITY DEFINER', /SECURITY DEFINER/.test(d.d));
  chk("search_path=''", /SET search_path TO ''/.test(d.d));
  chk('statement_timeout 15s', /SET statement_timeout TO '15s'/.test(d.d));
  const acl = (await c.query(`select coalesce(array_to_string(p.proacl,','),'') a from pg_proc p
     join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='catalogo_virtual'`)).rows[0].a;
  chk('GRANT a anon', /anon=X/.test(acl), acl);
  chk('GRANT a authenticated', /authenticated=X/.test(acl));
  chk('sin GRANT a PUBLIC', !/(^|,)=X/.test(acl));
}

// ── test funcional COMO anon (así la llamará PostgREST) ───────────────────────
let R = null;
{
  await c.query('savepoint sp_anon');
  await c.query('set local role anon');
  try {
    R = (await c.query(`select mos.catalogo_virtual() r`)).rows[0].r;
    chk('anon puede ejecutar', true);
  } catch (e) { chk('anon puede ejecutar', false, e.message); }
  await c.query('rollback to savepoint sp_anon');   // vuelve a rol admin
}

if (R) {
  const F = R.familias || [];
  chk('trae familias (>0)', F.length > 0, `familias=${F.length}`);
  chk('ok:true + total coherente', R.ok === true && +R.total === F.length, `total=${R.total}`);

  // ── FUGAS: ni la palabra costo/margen/stock/sku, ni un stock numérico ───────
  const raw = JSON.stringify(R);
  const claves = new Set();
  (function walk(o) {
    if (Array.isArray(o)) return o.forEach(walk);
    if (o && typeof o === 'object') for (const k of Object.keys(o)) { claves.add(k); walk(o[k]); }
  })(R);
  const PROHIBIDAS = ['costo', 'precio_costo', 'margen', 'margen_pct', 'precio_tope', 'stock',
    'stockBase', 'cantidad_disponible', 'sku', 'sku_base', 'fsku', 'id_producto', 'codigo_barra',
    'cliente', 'clientes', 'documento', 'telefono', 'telefono_wsp', 'sustitutos'];
  const fugadas = PROHIBIDAS.filter(k => [...claves].some(c2 => c2.toLowerCase() === k.toLowerCase()));
  chk('sin claves prohibidas', fugadas.length === 0, fugadas.join(',') || 'ninguna');
  chk("string 'costo' ausente del JSON", !/costo/i.test(raw));
  chk("string 'margen' ausente", !/margen/i.test(raw));
  chk('sin stock numérico (solo booleano)', !/"stock[^"]*"[[:space:]]*:/i.test(raw) && !claves.has('stock'),
    'claves=' + [...claves].sort().join('|'));
  chk('disponible es booleano en todas', F.every(f => typeof f.disponible === 'boolean'));

  // ── forma de los datos ──────────────────────────────────────────────────────
  const claveOk = F.every(f => ['id', 'nombre', 'marca', 'concepto', 'unidad', 'foto', 'disponible', 'escalones']
    .every(k => k in f) && Object.keys(f).length === 8);
  chk('cada familia = exactamente 8 claves públicas', claveOk, Object.keys(F[0] || {}).join(','));
  chk('escalones {label,precio,factor}', F.every(f => (f.escalones || []).every(e =>
    typeof e.label === 'string' && typeof e.factor !== 'undefined' && +e.precio > 0
    && Object.keys(e).length === 3)));
  chk('unidad ∈ {KGM,NIU}', F.every(f => f.unidad === 'KGM' || f.unidad === 'NIU'));
  chk('todas con concepto', F.every(f => (f.concepto || '').length > 0));

  // orden (concepto, marca, nombre)
  const key = f => [f.concepto, (f.marca || '').toUpperCase(), f.nombre].join('\u0000');
  chk('ordenado por (concepto, marca, nombre)',
    F.every((f, i) => i === 0 || key(F[i - 1]) <= key(f)));

  // paridad con ruta_boot (misma fuente ⇒ mismo universo de familias)
  const rb = (await c.query(`select mos.ruta_boot('{}'::jsonb) r`)).rows[0].r;
  chk('paridad de familias con ruta_boot', (rb.familias || []).length === F.length,
    `boot=${(rb.familias || []).length} vitrina=${F.length}`);

  // ── retrato de lo que verá la web ───────────────────────────────────────────
  const porC = {};
  for (const f of F) (porC[f.concepto] = porC[f.concepto] || []).push(f);
  console.log('\n📖 CAPÍTULOS que generará la vitrina:');
  for (const [k, v] of Object.entries(porC)) {
    const marcas = [...new Set(v.map(x => (x.marca || '').toUpperCase() || '—'))];
    console.log(`   · ${k} — ${v.length} productos · marcas: ${marcas.join(', ')}`);
  }
  const conFoto = F.filter(f => f.foto).length;
  const agot = F.filter(f => !f.disponible).length;
  console.log(`   fotos: ${conFoto}/${F.length} · agotados: ${agot} · escalones totales: ${F.reduce((a, f) => a + (f.escalones || []).length, 0)}`);
  console.log('   ejemplo:', JSON.stringify(F.find(f => (f.escalones || []).length > 1) || F[0]));
}

const ok = T.every(t => t[0] === '✅');
console.log('\n' + T.map(t => `${t[0]} ${t[1]}${t[2] ? '  → ' + t[2] : ''}`).join('\n'));
if (ok && process.argv.includes('--apply')) { await c.query('commit'); console.log('\n🟢 656 APLICADO'); }
else { await c.query('rollback'); console.log(ok ? '\n🟡 tests OK — corre con --apply para aplicar' : '\n🔴 ROLLBACK: hay tests en rojo'); }
await c.end();
