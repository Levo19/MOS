import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── stock negativo HOY en almacén');
console.table((await c.query(`
  select count(*) codigos, round(sum(cantidad_disponible),2) uds_total,
         count(*) filter (where cantidad_disponible > -1) menores_a_1,
         count(*) filter (where cantidad_disponible <= -1 and cantidad_disponible > -50) entre_1_y_50,
         count(*) filter (where cantidad_disponible <= -50) graves
    from wh.stock where cantidad_disponible < 0`)).rows);
console.log('\n── los 12 peores (los que habría que contar físicamente)');
console.table((await c.query(`
  select s.cod_producto, left(coalesce(p.descripcion,'?'),42) producto,
         round(s.cantidad_disponible,3) stock
    from wh.stock s left join mos.productos p on upper(btrim(p.codigo_barra))=upper(btrim(s.cod_producto))
   where s.cantidad_disponible < 0 order by s.cantidad_disponible limit 12`)).rows);
await c.end();
