// ¿El despacho parcial de ayer (17:41) generó guía GPCK? + pendiente dentro del acumulador PARCIAL.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('— guías de salida a ZONA-02 de ayer:');
console.table((await c.query(`
  select id_guia, tipo, id_zona, estado, usuario,
         to_char(fecha at time zone 'America/Lima','MM-DD HH24:MI') hora,
         (select count(*) from wh.guia_detalle gd where gd.id_guia = g.id_guia) lineas
    from wh.guias g
   where upper(coalesce(id_zona,'')) like '%02%'
     and (fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date - 1
   order by fecha`)).rows);
console.log('— acumulador PARCIAL: cuánto queda DEBIDO adentro (sol - desp > 0):');
console.table((await c.query(`
  select count(*) items_con_deuda,
         round(sum(greatest(0, (it->>'solicitado')::numeric - coalesce((it->>'despachado')::numeric,0))), 3) unidades_debidas
    from wh.pickups p, jsonb_array_elements(p.items) it
   where p.id_pickup = 'PCK-ACU-ZONA-02-2026-07-26'
     and greatest(0, (it->>'solicitado')::numeric - coalesce((it->>'despachado')::numeric,0)) > 0`)).rows);
await c.end();
