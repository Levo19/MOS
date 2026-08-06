// TURBO temporal del backfill: cron cada 1 min {max:4} (server-side, inmune a kills locales).
// El marcado de intentos actúa como "claim": si dos corridas se solapan, la segunda toma
// los SIGUIENTES de la cola (orden por intentos asc). Restaurar con _sust_cron.mjs al acabar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const secret = fs.readFileSync('../.cron_secret_descia', 'utf8').trim();
await c.query(`select cron.unschedule(jobid) from cron.job where jobname = 'sustitutos-ia-auto'`);
await c.query(`select cron.schedule('sustitutos-ia-auto', '* * * * *', $cmd$
  select net.http_post(
    url := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/sustitutos-ia',
    headers := '{"Content-Type":"application/json","x-cron-secret":"__S__"}'::jsonb,
    body := '{"max":4}'::jsonb);
$cmd$)`.replace('__S__', secret));
const j = (await c.query(`select jobname, schedule from cron.job where jobname='sustitutos-ia-auto'`)).rows;
console.log('turbo ON:', JSON.stringify(j));
await c.end();
