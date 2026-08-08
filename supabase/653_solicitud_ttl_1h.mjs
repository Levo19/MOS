// 653 · Regla del dueño: una solicitud vive 1 HORA. Si nadie la aprobó, se esconde (ruido)
//   y el equipo debe volver a solicitar (reabrir la app → registrar refresca pendiente_desde).
//   a) listar_dispositivos (fuente única de burbuja+modal): excluye pendientes >1h.
//   b) cron [652]: 72h → 1h (limpieza a CANCELADO_AUTO, reversible SQL 100).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const def = async fn => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname=$1`, [fn])).rows[0].d;

// a) listar
let dl = await def('listar_dispositivos');
if (!dl.includes('[653]')) {
  const a = `where (v_app is null or d.app = v_app)`;
  if (dl.indexOf(a) < 0 || dl.indexOf(a) !== dl.lastIndexOf(a)) throw new Error('ancla listar');
  dl = dl.replace(a, a + `
      -- [653] solicitud vence a 1h: pendiente vieja = ruido, se esconde (el cron la cancela; reabrir app re-solicita)
      and not (d.estado = 'PENDIENTE_APROBACION' and coalesce(d.pendiente_desde, d.ultima_conexion) < now() - interval '1 hour')`);
} else console.log('listar ya tenía 653');

// b) cron 72h → 1h
let dc = await def('cron_dispositivos_inactivos');
if (!/interval '72 hours'/.test(dc)) { if (!/\[653\]|interval '1 hour'[\s\S]*PENDIENTE_APROBACION|PENDIENTE_APROBACION[\s\S]*interval '1 hour'/.test(dc)) throw new Error('cron sin 652 ni 653'); console.log('cron ya en 1h'); }
else dc = dc.replace(`interval '72 hours'`, `interval '1 hour'`);

// test en tx
await c.query('begin');
await c.query(dl); await c.query(dc);
// sembrar 2 pendientes de prueba: viejo (2h) y joven (5min)
await c.query(`insert into mos.dispositivos (id_dispositivo, app, estado, ultima_conexion, pendiente_desde)
  values ('test-653-viejo','MOS','PENDIENTE_APROBACION', now(), now() - interval '2 hours'),
         ('test-653-joven','MOS','PENDIENTE_APROBACION', now(), now() - interval '5 minutes')`);
const { rows: [{ r }] } = await c.query(`select mos.listar_dispositivos('{}'::jsonb) r`).catch(async e => {
  return { rows: [{ r: (await c.query(`select mos.listar_dispositivos() r`)).rows[0].r }] };
});
const arr = Array.isArray(r) ? r : (r.data || []);
const ids = JSON.stringify(arr).includes('test-653-viejo') ? 'VIEJO VISIBLE ❌' : (JSON.stringify(arr).includes('test-653-joven') ? 'ok: joven visible, viejo oculto ✅' : 'ninguno visible ⚠');
console.log('test listar:', ids);
await c.query(`select mos.cron_dispositivos_inactivos()`);
const { rows: est } = await c.query(`select id_dispositivo, estado from mos.dispositivos where id_dispositivo like 'test-653-%'`);
est.forEach(x => console.log('  tras cron:', x.id_dispositivo, '→', x.estado));
const okCron = est.find(x=>x.id_dispositivo==='test-653-viejo').estado==='CANCELADO_AUTO' && est.find(x=>x.id_dispositivo==='test-653-joven').estado==='PENDIENTE_APROBACION';
console.log('test cron 1h:', okCron ? '✅' : '❌');
await c.query('rollback');
if (!ids.includes('✅') || !okCron) { console.log('NO se aplica'); process.exit(1); }
await c.query(dl); await c.query(dc);
console.log('✅ 653 aplicado: solicitudes viven 1 hora (ocultas al leer + canceladas por cron)');
await c.end();
