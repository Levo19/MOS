import pg from 'pg'; import fs from 'fs';
const c=new pg.Client({connectionString:fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim()});
await c.connect();
const LS='LS1786476692501', ACU='PCK-ACU-ZONA-01-2026-08-09';
const ver=async(t)=>{
  const r=await c.query(`select jsonb_array_length(items) n,
    (select count(*) from jsonb_array_elements(items) e where coalesce(e->>'sinSku','false')='true') sinsku,
    (select count(*) from jsonb_array_elements(items) e where coalesce(e->>'sinSku','false')<>'true') identificados
    from wh.pickups where id_pickup=$1`,[ACU]);
  console.log(t, JSON.stringify(r.rows[0]));
};
// Qué trae la sombra
const s=await c.query(`select
  (select count(*) from jsonb_array_elements(items) e where coalesce(btrim(e->>'skuBase'),'')<>'') identificados,
  (select count(*) from jsonb_array_elements(items) e where coalesce(btrim(e->>'skuBase'),'')='') sin_identificar,
  (select round(sum((e->>'cantidad')::numeric),2) from jsonb_array_elements(items) e where coalesce(btrim(e->>'skuBase'),'')<>'') uds_ident
  from wh.listas_sombra where id_lista=$1`,[LS]);
console.log('SOMBRA de Sergio:', JSON.stringify(s.rows[0]));
await ver('ACUMULADO antes: ');
await c.query('begin');
// Simular el cierre del día: la sombra cumple su ciclo aunque no se haya escaneado nada
await c.query(`update wh.listas_sombra set fecha_creacion = now() - interval '25 hours' where id_lista=$1`,[LS]);
const r=await c.query(`select wh.vencer_listas_sombra() j`);
console.log('vencer_listas_sombra →', JSON.stringify(r.rows[0].j));
await ver('ACUMULADO después:');
const post=await c.query(`select estado from wh.listas_sombra where id_lista=$1`,[LS]);
console.log('estado de la sombra:', post.rows[0].estado);
await c.query('rollback'); await c.end();
console.log('\nROLLBACK — nada cambió todavía');
