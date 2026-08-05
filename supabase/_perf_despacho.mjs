import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
try {
  console.log('── tiempos reales de las RPC del despacho (pg_stat_statements)');
  console.table((await c.query(`
    select left(regexp_replace(query,'\s+',' ','g'),58) q, calls,
           round(mean_exec_time)::int ms_prom, round(max_exec_time)::int ms_max,
           round(total_exec_time/1000)::int seg_total
      from pg_stat_statements
     where query ~* 'crear_despacho_rapido|cerrar_lista_sombra|crear_pickup|consolidar_pickups'
     order by max_exec_time desc limit 10`)).rows);
} catch(e) { console.log('  (pg_stat_statements no disponible:', e.message.slice(0,70)+')'); }
console.log('\n── ¿hay statement_timeout configurado?');
console.table((await c.query(`select name, setting from pg_settings where name in ('statement_timeout','idle_in_transaction_session_timeout','lock_timeout')`)).rows);
console.log('\n── ¿hay locks trabados AHORA?');
console.table((await c.query(`select count(*) bloqueados from pg_locks where not granted`)).rows);
await c.end();
