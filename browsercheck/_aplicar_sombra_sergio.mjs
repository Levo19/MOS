import pg from 'pg'; import fs from 'fs';
const c=new pg.Client({connectionString:fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim()});
await c.connect();
const LS='LS1786476692501', ACU='PCK-ACU-ZONA-01-2026-08-09';
const SKUS=['LEV1306','LEV1180','LEV107'];
const foto=async()=>{
  const r=await c.query(`select jsonb_array_length(items) n,
    (select round(sum(greatest(0,(e->>'solicitado')::numeric - coalesce((e->>'despachado')::numeric,0))),2)
       from jsonb_array_elements(items) e) deuda,
    (select count(*) from jsonb_array_elements(items) e where coalesce(e->>'sinSku','false')='true') constancias,
    (select jsonb_object_agg(e->>'skuBase', e->>'solicitado') from jsonb_array_elements(items) e
      where e->>'skuBase' = any($2)) los3
    from wh.pickups where id_pickup=$1`,[ACU,SKUS]);
  return r.rows[0];
};
const antes=await foto();
console.log('ANTES  :', JSON.stringify(antes));
await c.query(`update wh.listas_sombra set fecha_creacion = now() - interval '25 hours' where id_lista=$1`,[LS]);
const r=await c.query(`select wh.vencer_listas_sombra() j`);
console.log('volcado:', JSON.stringify(r.rows[0].j));
const desp=await foto();
console.log('DESPUÉS:', JSON.stringify(desp));
const est=await c.query(`select estado, nota from wh.listas_sombra where id_lista=$1`,[LS]);
console.log('sombra :', est.rows[0].estado, '·', (est.rows[0].nota||'').slice(-60));
console.log('\nΔ productos:', desp.n - antes.n, '· Δ deuda:', (Number(desp.deuda)-Number(antes.deuda)).toFixed(2), 'uds · constancias:', antes.constancias, '→', desp.constancias);
await c.end();
