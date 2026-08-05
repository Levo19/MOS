// 626b · CORRECCIÓN de 626: dejé una referencia a `c.factor` pero cb_to_sku no tenía
// esa columna. Se la agrego (las equivalencias comparten el código del canónico → 1).
// Y esta vez la verificación ejecuta la RPC con proveedores REALES, que es lo que
// debí hacer antes de aplicar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

let def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='mos' and p.proname='productos_proveedor_stock' and p.prokind='f'`)).rows[0].d;
const rep = (from, to, etq) => {
  const n = def.split(from).length - 1;
  if (n !== 1) throw new Error(`[${etq}] esperaba 1, hay ${n}`);
  def = def.replace(from, to);
};

rep(`    select distinct coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
           nullif(btrim(pr.codigo_barra),'') as cb
    from mos.productos pr
    where nullif(btrim(pr.codigo_barra),'') is not null
    union
    select distinct e.sku_base as sku, nullif(btrim(e.codigo_barra),'') as cb
    from mos.equivalencias e`,
    `    select distinct coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
           nullif(btrim(pr.codigo_barra),'') as cb,
           greatest(coalesce(nullif(pr.factor_conversion,0), 1), 0)::numeric as factor  -- [626b]
    from mos.productos pr
    where nullif(btrim(pr.codigo_barra),'') is not null
    union
    -- la equivalencia es el MISMO producto con otro código: factor 1 por definición
    select distinct e.sku_base as sku, nullif(btrim(e.codigo_barra),'') as cb, 1::numeric
    from mos.equivalencias e`,
    'cb_to_sku');

await c.query('begin');
await c.query(def);
const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };
chk('cb_to_sku ya expone factor', /as cb,\s*\n\s*greatest\(coalesce\(nullif\(pr\.factor_conversion/.test(def));

// LA prueba que faltó: ejecutar con proveedores reales
const provs = (await c.query(`select id_proveedor, nombre from mos.proveedores limit 5`)).rows;
let okP = 0, errP = [];
for (const p of provs) {
  try {
    await c.query(`select mos.productos_proveedor_stock($1::jsonb)`, [JSON.stringify({ idProveedor: p.id_proveedor })]);
    okP++;
  } catch (e) { errP.push(`${p.nombre}: ${e.message.slice(0, 70)}`); }
}
chk(`la RPC corre con los ${provs.length} proveedores reales`, errP.length === 0, errP.join(' | '));

// y que el resultado tenga forma usable
let muestra = null;
try {
  const r = (await c.query(`select mos.productos_proveedor_stock($1::jsonb) r`,
    [JSON.stringify({ idProveedor: provs[0]?.id_proveedor })])).rows[0].r;
  muestra = Array.isArray(r) ? r : (r?.data || r?.productos || null);
} catch (e) { errP.push(e.message); }
chk('devuelve una lista de productos', Array.isArray(muestra), muestra ? `n=${muestra.length}` : 'no es lista');

t.forEach(([s, n, x]) => console.log(' ', s, n, x ? '· ' + String(x).slice(0, 110) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
if (fallos) {
  await c.query('rollback');
  // dejar la función como estaba ANTES del 626 para no dejar producción rota
  const backup = fs.readFileSync('_626_backup_previo.sql', 'utf8');
  await c.query(backup);
  console.log(`\n❌ ${fallos} fallaron — REVERTIDO al estado previo al 626`);
  await c.end(); process.exit(1);
}
await c.query('rollback');
await c.query(def);
console.log(`\n✅ ${t.length}/${t.length} — 626b aplicado (626 completo y verificado con datos reales)`);
fs.writeFileSync('626b_fix_cb_factor.sql', def);
await c.end();
