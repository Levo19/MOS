import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const g = (await c.query(`select count(*) filter (where descripcion_ia is not null) hechos, count(*) total
  from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true)`)).rows[0];
console.log(`GLOBAL: ${g.hechos} de ${g.total} canónicos con descripcion_ia`);
const sinFicha = (await c.query(`select count(*) n from mos.productos
  where descripcion_ia like '%sin ficha web específica%'`)).rows[0].n;
console.log(`marcados "sin ficha web específica" (candidatos a repesca): ${sinFicha}`);
const marcas = (await c.query(`select count(*) n from mos.productos p
  where p.tipo_producto::text='CANONICO' and p.descripcion_ia is not null and nullif(btrim(p.marca),'') is not null`)).rows[0].n;
console.log(`canónicos con campo marca lleno: ${marcas}`);
// pendientes REALES dentro del universo válido de los lotes
const pend = (await c.query(String.raw`select codigo_barra, descripcion from mos.productos p
  where p.tipo_producto::text='CANONICO' and coalesce(p.estado,true) and p.descripcion_ia is null
    and coalesce(p.es_insumo,false)=false and length(btrim(p.descripcion))>=6
    and p.descripcion !~* '^[0-9 .,x*/-]+\s*(metros?|unidades?|mil(lar)?|cm|mm|gr?|kg|ml|lt|litros?)?\.?\s*$'
  order by descripcion`)).rows;
console.log(`\nREZAGADOS del universo válido: ${pend.length}`);
console.table(pend.slice(0, 15));
await c.end();
