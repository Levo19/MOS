// 652 · TTL de solicitudes de acceso (pedido dueño 2026-08-07):
//   PENDIENTE_APROBACION que NUNCA inició sesión y lleva >72h pendiente → CANCELADO_AUTO
//   (reversible: al reconectar reabre a PENDIENTE, mecánica SQL 100). El cron de 7 días
//   existente no cubría pendientes. + one-time: cancelar las 22 solicitudes basura actuales
//   (headless de pruebas + rezagadas de julio; todas con ultima_sesion NUNCA).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const def = async fn => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname=$1`, [fn])).rows[0].d;

let d = await def('cron_dispositivos_inactivos');
if (d.includes('[652]')) { console.log('652 ya aplicado'); await c.end(); process.exit(0); }
const ancla = `return jsonb_build_object('ok', true, 'suspendidos'`;
if (!d.includes(ancla)) throw new Error('ancla return no encontrada');
if (d.indexOf(ancla) !== d.lastIndexOf(ancla)) throw new Error('ancla dup');
d = d.replace(ancla,
`-- [652] TTL solicitudes: pendientes que NUNCA iniciaron sesión y llevan >72h → CANCELADO_AUTO
  -- (reversible al reconectar, SQL 100). El dueño no debe acumular solicitudes fantasma.
  update mos.dispositivos set
      estado = 'CANCELADO_AUTO',
      cancelado_auto_ts = now()
  where estado = 'PENDIENTE_APROBACION'
    and ultima_sesion is null
    and coalesce(pendiente_desde, ultima_conexion) < now() - interval '72 hours';
  ` + ancla);

// test en tx: aplicar def + simular
await c.query('begin');
await c.query(d);
const { rows: [{ n: antes }] } = await c.query(`select count(*)::int n from mos.dispositivos where estado='PENDIENTE_APROBACION'`);
await c.query(`select mos.cron_dispositivos_inactivos()`);
const { rows: [{ n: despues }] } = await c.query(`select count(*)::int n from mos.dispositivos where estado='PENDIENTE_APROBACION'`);
const { rows: [{ n: joven }] } = await c.query(`select count(*)::int n from mos.dispositivos where estado='PENDIENTE_APROBACION' and pendiente_desde > now() - interval '72 hours'`);
console.log(`test tx: pendientes ${antes} → ${despues} tras cron (quedan jóvenes <72h: ${joven}; el cron NO debe tocar jóvenes)`);
if (despues !== joven) throw new Error('el cron tocó pendientes jóvenes o dejó viejos');
await c.query('rollback');

// aplicar de verdad
await c.query(d);
// one-time: TODAS las solicitudes sin sesión jamás (incluye las de hoy de Playwright)
const r = await c.query(`update mos.dispositivos set estado='CANCELADO_AUTO', cancelado_auto_ts=now() where estado='PENDIENTE_APROBACION' and ultima_sesion is null`);
const { rows: [{ n: fin }] } = await c.query(`select count(*)::int n from mos.dispositivos where estado='PENDIENTE_APROBACION'`);
console.log(`✅ 652 aplicado · one-time canceladas: ${r.rowCount} · pendientes restantes: ${fin}`);
await c.end();
