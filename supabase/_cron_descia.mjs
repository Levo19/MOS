import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const secret = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/.cron_secret_descia','utf8').trim();
await c.query(`select cron.unschedule('descripcion-ia-auto') where exists (select 1 from cron.job where jobname='descripcion-ia-auto')`).catch(()=>{});
try { await c.query(`select cron.unschedule('descripcion-ia-auto')`); } catch(_){}
await c.query(`select cron.schedule('descripcion-ia-auto', '*/10 * * * *', $cron$
  select net.http_post(
    url := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/descripcion-ia',
    headers := '{"Content-Type":"application/json","x-cron-secret":"${secret}"}'::jsonb,
    body := '{"max":2}'::jsonb);
$cron$)`);
console.table((await c.query(`select jobname, schedule, active from cron.job where jobname='descripcion-ia-auto'`)).rows);
await c.end();
