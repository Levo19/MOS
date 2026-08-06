import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.table((await c.query(`select id_categoria, nombre, margen_pct from mos.categorias order by id_categoria`)).rows);
await c.end();
