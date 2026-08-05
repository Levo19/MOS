import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
for (const t of ['mermas','sorpresas']) {
  console.log(`\n── columnas wh.${t}:`);
  const cols = (await c.query(`select column_name, data_type from information_schema.columns where table_schema='wh' and table_name=$1 order by ordinal_position`,[t])).rows;
  console.log('   ' + cols.map(x=>x.column_name).join(', '));
  const qty = cols.find(x=>/cant|unid|qty|peso/i.test(x.column_name))?.column_name;
  const fec = cols.find(x=>/fecha|creado|created/i.test(x.column_name))?.column_name;
  if (qty && fec) {
    console.table((await c.query(`select count(*) n, round(sum(${qty}),2) uds, min(${fec})::date desde, max(${fec})::date hasta
      from wh.${t} where ${fec} >= now() - interval '90 days'`)).rows);
  }
}
await c.end();
