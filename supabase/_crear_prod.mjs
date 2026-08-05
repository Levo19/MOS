import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
for (const f of ['crear_producto','actualizar_producto']) {
  const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='mos' and p.proname=$1 limit 1`,[f])).rows[0].d;
  fs.writeFileSync('_def_'+f+'.sql', d);
  console.log('== '+f+' ('+d.split('\n').length+' líneas)');
  d.split('\n').forEach((l,i)=>{ if(/insert into mos\.productos|es_insumo|envase_sku/i.test(l)) console.log('  L'+(i+1)+':', l.trim().slice(0,120)); });
}
await c.end();
