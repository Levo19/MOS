import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('pg_net:', (await c.query(`select count(*) n from pg_extension where extname='pg_net'`)).rows[0].n);
console.log('crons que llaman http:', (await c.query(`select count(*) n from cron.job where command ~* 'http_post|net\.'`)).rows[0].n);
const ej = (await c.query(`select left(command,150) c from cron.job where command ~* 'http_post' limit 1`)).rows[0];
console.log('ejemplo:', ej ? ej.c : '(ninguno)');
await c.end();
