import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };

console.log('── códigos del proveedor reparados');
console.table((await c.query(`select codigo_barra, sku_base, id_proveedor
  from mos.proveedores_productos where sku_base in ('LEV226','LEV522') order by 1`)).rows);
const cam = (await c.query(`select codigo_barra from mos.proveedores_productos where sku_base='LEV226' limit 1`)).rows[0];
t('CAMARON ya tiene el código con ceros (00247)', cam.codigo_barra === '00247', cam.codigo_barra);

const q = (await c.query(`
  select count(*) n from mos.proveedores_productos pp
    join mos.productos pr on coalesce(nullif(btrim(pr.sku_base),''),pr.id_producto)=btrim(pp.sku_base)
   where coalesce(pp.activa,true) and pr.tipo_producto::text='CANONICO'
     and btrim(pp.codigo_barra) <> btrim(pr.codigo_barra)
     and ltrim(btrim(pp.codigo_barra),'0') = ltrim(btrim(pr.codigo_barra),'0')`)).rows[0];
t('ya no quedan códigos mutilados por ceros', parseInt(q.n) === 0, q.n);

console.log('── la RPC devuelve ambos códigos');
const r = (await c.query(`select mos.prov_stock_ubicaciones('{"idProveedor":"PROV082"}'::jsonb) j`)).rows[0].j;
const prods = r.data.productos || [];
t('todos los productos traen codigoProv', prods.every(p => !!p.codigoProv), prods.length);
const camaron = prods.find(p => p.codigoBarra === '00247');
t('el CAMARON ya viene con ubicaciones (antes caía al card viejo)', !!camaron);
if (camaron) {
  console.log('     codigoBarra:', camaron.codigoBarra, '· codigoProv:', camaron.codigoProv, '· unidad:', camaron.unidad);
  t('CAMARON es KGM (granel, no unidades)', camaron.unidad === 'KGM', camaron.unidad);
  const z = camaron.ubicaciones.find(u => u.tipo === 'ZONA');
  if (z) console.log('     zona:', z.id, '· total', z.totalEq, '· falta', z.faltaEq);
}
console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
await c.end();
process.exit(fail === 0 ? 0 : 1);
