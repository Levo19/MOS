import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
try {
  console.log('── crons que llaman a vencer_listas_sombra:');
  console.table((await c.query(`select jobid, schedule, active, left(command,90) command from cron.job where command ~* 'vencer_listas_sombra'`)).rows);
  console.log('── últimas corridas:');
  console.table((await c.query(`select j.jobname, r.status, r.start_time::date d, count(*) n from cron.job_run_details r
    join cron.job j on j.jobid=r.jobid where j.command ~* 'vencer_listas_sombra'
    group by 1,2,3 order by 3 desc limit 6`)).rows);
} catch(e){ console.log('  (sin acceso a cron:', e.message.slice(0,60)+')'); }
console.log('\n── las 11 sombras escaneadas: ¿en qué estado están hoy?');
console.table((await c.query(`
  select upper(coalesce(ls.estado,'?')) estado, count(*) n,
         to_char(min(ls.fecha_creacion) at time zone 'America/Lima','DD/MM') mas_vieja,
         to_char(max(ls.fecha_creacion) at time zone 'America/Lima','DD/MM') mas_nueva
    from wh.listas_sombra ls
   where coalesce(btrim(ls.zona),'')<>''
     and (select coalesce(sum(wh._num(coalesce(it->>'cantidadEscaneada','0'))),0)
            from jsonb_array_elements(coalesce(ls.items,'[]'::jsonb)) it) > 0
   group by 1 order by 2 desc`)).rows);
await c.end();
