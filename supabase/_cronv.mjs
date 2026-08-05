import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.table((await c.query(`select jobid, schedule, active, left(command,70) cmd from cron.job where command ~* 'vencer_extensiones|suspend|dispositivo'`)).rows);
await c.end();
