const { readFileSync } = require('fs');
const { Client } = require('pg');
(async () => {
  const cs = readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim();
  const c = new Client({ connectionString: cs, ssl: { rejectUnauthorized: false } });
  await c.connect();
  await c.query(`select set_config('request.jwt.claims','{"app":"mosAdmin","role":"MASTER"}',true)`);
  // find candidate functions
  const q = await c.query(`
    select n.nspname||'.'||p.proname as f, pg_get_function_identity_arguments(p.oid) args
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where p.proname ~* 'desc_pendientes|sust_pendientes|cron_ocr_guias|ia_desc|sust_stale|pendientes'
    order by 1`);
  console.log('CANDIDATES:');
  q.rows.forEach(r=>console.log('  '+r.f+'('+r.args+')'));
  await c.end();
})().catch(e=>{console.error(e);process.exit(1)});
