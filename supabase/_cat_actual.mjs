import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── categorías existentes (mos.categorias):');
console.table((await c.query(`select * from mos.categorias order by 1 limit 25`)).rows.map(r=>Object.fromEntries(Object.entries(r).slice(0,5))));
console.log('── uso de id_categoria en canónicos:');
console.table((await c.query(`select coalesce(nullif(btrim(id_categoria),''),'(vacío)') cat, count(*) n
  from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true) group by 1 order by 2 desc limit 12`)).rows);
console.log('── ¿id_categoria afecta políticas de precio?');
console.log((await c.query(`select column_name from information_schema.columns where table_schema='mos' and table_name='categorias'`)).rows.map(x=>x.column_name).join(', '));
await c.end();
