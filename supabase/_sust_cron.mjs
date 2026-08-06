// crons de sustitutos: Edge cada 10 min (nuevos/stale) + validador SQL cada 30 min
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const secret = fs.readFileSync('../.cron_secret_descia', 'utf8').trim();
await c.query(`select cron.unschedule(jobid) from cron.job where jobname in ('sustitutos-ia-auto','sust-validar')`);
await c.query(`select cron.schedule('sustitutos-ia-auto', '*/10 * * * *', $cmd$
  select net.http_post(
    url := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/sustitutos-ia',
    headers := '{"Content-Type":"application/json","x-cron-secret":"${'${secret}'}"}'::jsonb,
    body := '{"max":2}'::jsonb);
$cmd$)`.replace('${secret}', secret));
await c.query(`select cron.schedule('sust-validar', '7,37 * * * *', 'select mos.sust_validar(''{}''::jsonb)')`);
const jobs = (await c.query(`select jobname, schedule from cron.job where jobname in ('sustitutos-ia-auto','sust-validar')`)).rows;
console.log('crons:', JSON.stringify(jobs));
await c.end();
