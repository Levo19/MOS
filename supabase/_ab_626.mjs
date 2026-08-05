import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
// proveedor con productos de verdad
const p = (await c.query(`select pp.id_proveedor, count(*) n from mos.proveedores_productos pp
  group by 1 order by 2 desc limit 3`)).rows;
console.log('proveedores con más productos:', p.map(x=>x.id_proveedor+'('+x.n+')').join(' '));
const nuevo = fs.readFileSync('626b_fix_cb_factor.sql','utf8');
const viejo = fs.readFileSync('_626_backup_previo.sql','utf8');
const corre = async (def, idp) => {
  await c.query('begin'); await c.query(def);
  const r = (await c.query(`select mos.productos_proveedor_stock($1::jsonb) r`,[JSON.stringify({idProveedor:idp})])).rows[0].r;
  await c.query('rollback');
  const arr = Array.isArray(r) ? r : (r?.data||[]);
  return arr;
};
for (const {id_proveedor:idp} of p) {
  const A = await corre(viejo, idp), B = await corre(nuevo, idp);
  console.log(`\n== proveedor ${idp}: antes ${A.length} productos · después ${B.length}`);
  if (!A.length) { console.log('   (sin productos, no compara)'); continue; }
  const key = Object.keys(A[0]).find(k=>/venta/i.test(k));
  const mapA = new Map(A.map(x=>[x.codigoBarra||x.sku||x.id, x[key]]));
  let dif=0, muestras=[];
  for (const b of B) { const k=b.codigoBarra||b.sku||b.id; const a=mapA.get(k);
    if (a!==undefined && Number(a)!==Number(b[key])) { dif++; if(muestras.length<5) muestras.push(`${b.descripcion||k}: ${a} → ${b[key]}`); } }
  console.log(`   campo de ventas: ${key} · cambiaron ${dif} de ${B.length}`);
  muestras.forEach(m=>console.log('     ', m));
}
await c.end();
