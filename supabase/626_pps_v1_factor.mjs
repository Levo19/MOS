// 626 · mos.productos_proveedor_stock (v1, fallback vivo de Proveedores):
// las ventas se sumaban SIN convertir a la unidad del canónico.
//
// `ventas_lineas.cant = d.cantidad` y luego `group by sku` (el sku_base del padre).
// Como todas las presentaciones comparten sku_base, vender 3 bolsas de 500 g de un
// producto que se compra por kilo sumaba 3, no 1.5. El número de ventas que se usa
// para sugerir la compra queda inflado tantas veces como diga el factor.
//
// La v2 y prov_stock_ubicaciones ya multiplican por el factor; esta es la que quedó
// atrás, y sigue viva porque es el fallback cuando la v2 devuelve null.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

let def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='mos' and p.proname='productos_proveedor_stock' and p.prokind='f'`)).rows[0].d;
const antes = def;
const rep = (from, to, etq) => {
  const n = def.split(from).length - 1;
  if (n !== 1) throw new Error(`[${etq}] esperaba 1, hay ${n}`);
  def = def.replace(from, to);
};

// El mapa id→sku ahora también trae el factor del producto de esa línea.
rep(`  id_to_sku as (
    select pr.id_producto as id, coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku
    from mos.productos pr
  ),`,
    `  id_to_sku as (
    select pr.id_producto as id, coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
           -- [626] factor a unidades del canónico (una bolsa de 500g de un producto
           -- que se compra por kilo vale 0.5, no 1)
           greatest(coalesce(nullif(pr.factor_conversion,0), 1), 0)::numeric as factor
    from mos.productos pr
  ),`,
    'id_to_sku');

// El mapa cb→sku idem (se resuelve por codigo_barra cuando no vino el id).
const cbIdx = def.indexOf('cb_to_sku as (');
if (cbIdx < 0) throw new Error('no encuentro cb_to_sku');
const cbBloque = def.slice(cbIdx, def.indexOf('),', cbIdx) + 2);
console.log('── cb_to_sku actual:\n' + cbBloque + '\n');

// [626] la conversión: cantidad × factor de la línea (por id, o por código de barra).
rep(`           coalesce(d.cantidad, 0) as cant`,
    `           -- [626] antes era \`coalesce(d.cantidad,0)\`: sumaba unidades de
           -- presentaciones distintas como si fueran la misma cosa.
           (coalesce(d.cantidad, 0) * coalesce(i.factor, c.factor, 1))::numeric as cant`,
    'cant');

await c.query('begin');
await c.query(def);
const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };
const nueva = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname='productos_proveedor_stock'`)).rows[0].d;
chk('la venta se convierte a unidades del canónico', /d\.cantidad, 0\) \* coalesce\(i\.factor/.test(nueva));
chk('el mapa id→sku trae el factor', /as sku,\s*\n\s*--\s*\[626\]/.test(nueva));
chk('un factor 0 o nulo no anula la venta (cae a 1)', nueva.includes('coalesce(i.factor, c.factor, 1)'));

// la función sigue respondiendo igual de forma
let r = null;
try { r = (await c.query(`select mos.productos_proveedor_stock('{}'::jsonb) r`)).rows[0].r; } catch (e) { r = { err: e.message }; }
chk('la RPC sigue corriendo sobre datos reales', r && !r.err, r?.err);

// comparación real: ¿cuánto cambia y en qué dirección?
await c.query('rollback');
const viejo = (await c.query(`
  with l as (
    select coalesce(nullif(pr.sku_base,''), pr.id_producto) sku,
           d.cantidad q, greatest(coalesce(nullif(pr.factor_conversion,0),1),0) f
      from me.ventas_detalle d
      join me.ventas v on v.id_venta = d.id_venta
      join mos.productos pr on pr.id_producto = nullif(btrim(d.sku),'')
     where v.fecha >= now() - interval '30 days'
       and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%')
  select count(distinct sku) skus,
         round(sum(q),2) suma_actual_sin_factor,
         round(sum(q*f),2) suma_correcta_con_factor,
         count(*) filter (where f <> 1) lineas_con_factor_distinto_de_1
    from l`)).rows[0];
console.log('\n── impacto real en 30 días:');
console.table([viejo]);

t.forEach(([s, n, x]) => console.log(' ', s, n, x ? '· ' + String(x).slice(0, 80) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }
await c.query(def);
console.log(`\n✅ ${t.length}/${t.length} — 626 aplicado`);
fs.writeFileSync('626_pps_v1_factor.sql', def);
fs.writeFileSync('_626_backup_previo.sql', antes);
await c.end();
