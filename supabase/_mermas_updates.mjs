import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
for (const f of ['registrar_sorpresa','merma_alta_manual','procesar_merma','mermas_eliminar_batch']) {
  const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='wh' and p.proname=$1 limit 1`,[f])).rows[0].d;
  fs.writeFileSync('_def_'+f+'.sql', d);
  console.log(`\n===== wh.${f}`);
  const L = d.split('\n');
  L.forEach((l,i)=>{ if(/wh\.stock\b/.test(l)) {
    console.log('  L'+(i+1)+': '+l.trim().slice(0,120));
    for (let k=1;k<=4;k++) if (L[i+k] && /cantidad_disponible|where|values|returning|;/.test(L[i+k])) console.log('        '+L[i+k].trim().slice(0,115));
  }});
}
await c.end();
