import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const r = (await c.query(`select descripcion, marca, descripcion_ia from mos.productos where codigo_barra='N-G7SKF36'`)).rows[0];
console.log('PRODUCTO:', r.descripcion, '· marca:', r.marca || '(vacía)');
console.log('─'.repeat(60));
console.log(r.descripcion_ia);
await c.end();
