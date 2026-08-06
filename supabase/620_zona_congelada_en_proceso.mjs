// 620 · La cuenta corriente de una zona se congela si su acumulador queda EN_PROCESO.
//
// `wh.consolidar_pickups_todas` (el que corre el cron cada hora) solo levanta acumuladores
// viejos en ('PENDIENTE','PARCIAL'). El rescate del anti-secuestro (EN_PROCESO → PENDIENTE
// tras 1h) vive DENTRO de `consolidar_pickup_zona`, que nunca llega a ejecutarse para esa
// zona → deadlock: no se libera, no pasa a REZAGADO y no re-siembra.
// Medido: PCK-ACU-ZONA-01-2026-07-26 quedó EN_PROCESO y el cron era un no-op desde el 01/08.
// 603 prometía "la lista de zona SIEMPRE visible" — con esto se cumple también tras un
// despacho interrumpido.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

console.log('── acumuladores atascados HOY:');
console.table((await c.query(`
  select id_pickup, id_zona, estado,
         to_char(ultima_actividad at time zone 'America/Lima','DD/MM HH24:MI') ult_act,
         jsonb_array_length(coalesce(items,'[]'::jsonb)) items
    from wh.pickups
   where id_pickup like 'PCK-ACU-%' and upper(coalesce(estado,'')) = 'EN_PROCESO'
   order by 2`)).rows);

const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='wh' and p.proname='consolidar_pickups_todas' and p.prokind='f'`)).rows[0].d;

if (d.includes("'PENDIENTE','PARCIAL','EN_PROCESO'")) {
  console.log('· ya incluía EN_PROCESO');
} else {
  const viejo = `in ('PENDIENTE','PARCIAL')`;
  const n = (d.match(/in \('PENDIENTE','PARCIAL'\)/g) || []).length;
  if (!n) { console.log('⚠ no ubiqué el filtro de estados; def:'); console.log(d); process.exit(1); }
  const nuevo = `in ('PENDIENTE','PARCIAL','EN_PROCESO')   -- [620] si no, la zona se congela`;
  await c.query('begin');
  try {
    await c.query(d.split(viejo).join(nuevo));
    const r = (await c.query(`select wh.consolidar_pickups_todas('{}'::jsonb) j`)).rows[0].j;
    console.log('  ensayo → zonas procesadas:', JSON.stringify(r).slice(0, 200));
  } finally { await c.query('rollback'); }
  await c.query(d.split(viejo).join(nuevo));
  console.log(`✅ wh.consolidar_pickups_todas: ${n} filtro(s) ahora incluyen EN_PROCESO`);
}

// disparar una consolidación real para descongelar ya
const r = (await c.query(`select wh.consolidar_pickups_todas('{}'::jsonb) j`)).rows[0].j;
console.log('\n── consolidación ejecutada:', JSON.stringify(r).slice(0, 300));
console.log('\n── estado tras descongelar:');
console.table((await c.query(`
  select id_zona, estado, id_pickup,
         to_char(fecha_creado at time zone 'America/Lima','DD/MM HH24:MI') creado,
         jsonb_array_length(coalesce(items,'[]'::jsonb)) items
    from wh.pickups where id_pickup like 'PCK-ACU-%'
     and fecha_creado > now() - interval '10 days' order by id_zona, fecha_creado desc`)).rows);
await c.end();
