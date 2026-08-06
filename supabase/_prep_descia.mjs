import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
await c.query(`alter table mos.productos add column if not exists descripcion_ia text`);
const n = (await c.query(`select count(*) total,
  count(*) filter (where descripcion_ia is not null) hechos
  from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true)=true`)).rows[0];
console.log('canónicos activos:', n.total, '· ya con descripcion_ia:', n.hechos);
const m = (await c.query(`select p.codigo_barra, p.descripcion,
    coalesce(string_agg(e.codigo_barra, ', '), '') equivalentes
  from mos.productos p left join mos.equivalencias e on e.sku_base = p.sku_base and e.activo
  where p.tipo_producto::text='CANONICO' and coalesce(p.estado,true)=true
  group by 1,2 order by p.descripcion limit 5`)).rows;
console.table(m);
await c.end();
