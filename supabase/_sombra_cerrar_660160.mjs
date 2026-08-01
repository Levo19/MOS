// Cierre contable de LS1785522660160 (la guía física YA existe: G_L1785526158074j5utavm 31/07 14:29).
// cerrar_lista_sombra NO crea guía — solo contabiliza pedido/despachado al acumulado (fórmula 540).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const r = (await c.query(`select wh.cerrar_lista_sombra(jsonb_build_object('idLista','LS1785522660160')) r`)).rows[0].r;
console.log('cerrar_lista_sombra →', JSON.stringify(r));
await c.query(`update wh.listas_sombra
   set nota = coalesce(nota,'') || ' [cierre contable manual 2026-08-01: la guía física ya existía G_L1785526158074j5utavm 31/07 14:29 · match 37 items/473.3 uds 1:1]'
 where id_lista = 'LS1785522660160'`);
console.table((await c.query(`select id_lista, estado, right(coalesce(nota,''),80) nota from wh.listas_sombra where id_lista='LS1785522660160'`)).rows);
console.log('— pickup contable generado y acumulador de ZONA-01:');
console.table((await c.query(`
  select id_pickup, fuente, estado, jsonb_array_length(coalesce(items,'[]'::jsonb)) n_items,
         to_char(fecha_creado at time zone 'America/Lima','MM-DD HH24:MI') creado
    from wh.pickups
   where id_pickup = 'PCK-LSC-LS1785522660160'
      or (id_zona='ZONA-01' and fuente='ACUMULADO_SEMANAL'
          and right(id_pickup,10) ~ '^\\d{4}-\\d{2}-\\d{2}$'
          and to_date(right(id_pickup,10),'YYYY-MM-DD') = wh._bucket_dom((now() at time zone 'America/Lima')::date))`)).rows);
await c.end();
