import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
for (const f of ['productos_proveedor_stock','productos_proveedor_stock_v2']) {
  const r = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='mos' and p.proname=$1 and p.prokind='f' limit 1`,[f])).rows[0];
  if (!r) { console.log(f+': NO EXISTE'); continue; }
  console.log('\n=== mos.'+f, '('+r.d.split('\n').length+' líneas)');
  console.log('   aplica factor_conversion?', /factor_conversion/i.test(r.d) ? 'SÍ' : '❌ NO');
  console.log('   excluye anuladas?        ', /ANULAD/i.test(r.d) ? 'SÍ' : '❌ NO');
  r.d.split('\n').forEach((l,i)=>{ if(/ventas_by_sku|sum\(vd\.cantidad\)|factor/i.test(l)) console.log('   L'+(i+1)+': '+l.trim().slice(0,120)); });
}
await c.end();
