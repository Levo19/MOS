import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── tablas de mermas/sorpresas:');
console.table((await c.query(`select table_name from information_schema.tables where table_schema='wh' and table_name ~* 'merma|sorpresa'`)).rows);
for (const t of ['mermas','sorpresas']) {
  try {
    console.log(`\n── wh.${t} · volumen 90 días`);
    console.table((await c.query(`select count(*) n, round(sum(cantidad),2) uds,
      min(fecha)::date desde, max(fecha)::date hasta from wh.${t} where fecha >= now() - interval '90 days'`)).rows);
  } catch(e){ console.log('   (', e.message.slice(0,70), ')'); }
}
console.log('\n── firma de las 4 funciones sin kardex:');
console.table((await c.query(`select n.nspname||'.'||p.proname f, pg_get_function_identity_arguments(p.oid) args,
   length(pg_get_functiondef(p.oid)) largo
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.proname in ('registrar_sorpresa','merma_alta_manual','procesar_merma','mermas_eliminar_batch')`)).rows);
await c.end();
