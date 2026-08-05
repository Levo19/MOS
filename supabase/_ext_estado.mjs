import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── extension_requests columnas:');
console.log((await c.query(`select column_name from information_schema.columns where table_schema='mos' and table_name='extension_requests' order by ordinal_position`)).rows.map(x=>x.column_name).join(', '));
console.log('\n── filas recientes:');
console.table((await c.query(`select estado, count(*) n, max(creado) reciente from mos.extension_requests group by 1 order by 2 desc limit 8`)).rows.map(r=>({...r, reciente: String(r.reciente).slice(0,24)})));
for (const f of ['solicitar_extension_horario','vencer_extensiones_horario']) {
  const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='mos' and p.proname=$1 limit 1`,[f])).rows[0]?.d || '(no existe)';
  fs.writeFileSync('_def_'+f+'.sql', d);
  console.log('\n== '+f+' ('+d.split('\n').length+' líneas) — claves:');
  d.split('\n').forEach(l=>{ if(/interval|insert into|on conflict|estado.*=|vencid/i.test(l)) console.log('   '+l.trim().slice(0,110)); });
}
await c.end();
