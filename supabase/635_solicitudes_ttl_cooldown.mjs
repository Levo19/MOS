// 635 · SOLICITUDES DE PERMISO (decisiones del dueño, 2026-08-05):
//  1. Cooldown de REENVÍO = 5 min (antes 60 s) en solicitar_acceso_dispositivo.
//     El reenvío ya "pisaba" (misma fila, pendiente_desde nuevo) — se conserva.
//  2. solicitar_extension_horario: <5 min → cooldown con segundos restantes;
//     ≥5 min → la nueva PISA a la anterior (la vieja pasa a REEMPLAZADA). Antes la
//     vieja se quedaba y la nueva se ignoraba (yaExistia) → el admin veía data rancia.
//  3. TTL 1 HORA: vencer_extensiones_horario pasa de 2 h → 1 h (cron cada hora ya corre).
//  4. listar_dispositivos expone Pendiente_Desde (para que la UI venza solicitudes a 1 h
//     y muestre "hace X min").
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const rep = (s, from, to, etq) => {
  const n = s.split(from).length - 1;
  if (n !== 1) throw new Error(`[${etq}] esperaba 1, hay ${n}`);
  return s.replace(from, to);
};
const traer = async (fn) => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname=$1 and p.prokind='f' limit 1`, [fn])).rows[0].d;

// 1) cooldown 5 min del acceso de dispositivo
let sad = await traer('solicitar_acceso_dispositivo');
sad = rep(sad,
  `  -- cooldown 60s: si ya hay una solicitud reciente, NO re-enviar (anti-spam)
  if found and upper(coalesce(d.estado,''))='PENDIENTE_APROBACION' and d.pendiente_desde is not null then
    v_age := extract(epoch from (now() - d.pendiente_desde));
    if v_age < 60 then
      return jsonb_build_object('ok', true, 'estado', 'PENDIENTE_APROBACION', 'autorizado', false,
        'cooldown', true, 'retry_seg', greatest(1, ceil(60 - v_age))::int);
    end if;
  end if;`,
  `  -- [635] cooldown 5 MIN (decisión dueño: nada de bombardeo). El reenvío tras el
  -- cooldown PISA la solicitud anterior (misma fila, pendiente_desde nuevo).
  if found and upper(coalesce(d.estado,''))='PENDIENTE_APROBACION' and d.pendiente_desde is not null then
    v_age := extract(epoch from (now() - d.pendiente_desde));
    if v_age < 300 then
      return jsonb_build_object('ok', true, 'estado', 'PENDIENTE_APROBACION', 'autorizado', false,
        'cooldown', true, 'retry_seg', greatest(1, ceil(300 - v_age))::int);
    end if;
  end if;`,
  'sad-cooldown');

// 2) extensión de horario: cooldown + pisa
let seh = await traer('solicitar_extension_horario');
seh = rep(seh,
  `  -- Dedup: si ya hay una solicitud PENDIENTE de esta persona (o de este UUID), no duplicar.
  if exists (select 1 from mos.seguridad_alertas
             where tipo='EXTENSION_HORARIO_PENDIENTE' and upper(coalesce(estado,''))='PENDIENTE'
               and (id_personal = v_id or (v_dev is not null and id_dispositivo = v_dev))) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('yaExistia',true));
  end if;`,
  `  -- [635] Anti-bombardeo con reemplazo (decisión dueño):
  --   · < 5 min de la anterior PENDIENTE → cooldown (segundos restantes al cliente)
  --   · ≥ 5 min → la nueva PISA a la anterior (REEMPLAZADA) — el admin ve solo la fresca
  declare v_prev record; v_age2 numeric;
  begin
    select id_alerta, fecha into v_prev from mos.seguridad_alertas
     where tipo='EXTENSION_HORARIO_PENDIENTE' and upper(coalesce(estado,''))='PENDIENTE'
       and (id_personal = v_id or (v_dev is not null and id_dispositivo = v_dev))
     order by fecha desc limit 1;
    if v_prev.id_alerta is not null then
      v_age2 := extract(epoch from (now() - v_prev.fecha));
      if v_age2 < 300 then
        return jsonb_build_object('ok',true,'data',jsonb_build_object('yaExistia',true,
          'cooldown',true,'retrySeg', greatest(1, ceil(300 - v_age2))::int));
      end if;
      update mos.seguridad_alertas set estado='REEMPLAZADA' where id_alerta = v_prev.id_alerta;
    end if;
  end;`,
  'seh-pisa');

// 3) TTL 1h
let veh = await traer('vencer_extensiones_horario');
veh = rep(veh,
  `and fecha < now() - interval '2 hours';`,
  `and fecha < now() - interval '1 hour';   -- [635] TTL 1 HORA (decisión dueño)`,
  'ttl-1h');

// 4) Pendiente_Desde en el listado
let ld = await traer('listar_dispositivos');
ld = rep(ld,
  `'Suspendido_Desde',`,
  `'Pendiente_Desde', case when d.pendiente_desde is null then '' else to_char(d.pendiente_desde at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
      'Suspendido_Desde',`,
  'ld-pendiente');

await c.query('begin');
await c.query(sad); await c.query(seh); await c.query(veh); await c.query(ld);
const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };

// dispositivo: cooldown 5 min
const uuid = '00000000-1111-2222-3333-444455556635';
const r1 = (await c.query(`select mos.solicitar_acceso_dispositivo($1::jsonb) r`, [JSON.stringify({ id_dispositivo: uuid, app: 'mosExpress' })])).rows[0].r;
const r2 = (await c.query(`select mos.solicitar_acceso_dispositivo($1::jsonb) r`, [JSON.stringify({ id_dispositivo: uuid, app: 'mosExpress' })])).rows[0].r;
chk('dispositivo: 1ª solicitud entra', r1.estado === 'PENDIENTE_APROBACION' && r1.enviado === true, JSON.stringify(r1));
chk('dispositivo: reintento inmediato → cooldown ~5 min', r2.cooldown === true && r2.retry_seg > 290, JSON.stringify(r2));
// tras 5 min (simulado) → pisa: pendiente_desde se renueva
await c.query(`update mos.dispositivos set pendiente_desde = now() - interval '6 minutes' where id_dispositivo=$1`, [uuid]);
const r3 = (await c.query(`select mos.solicitar_acceso_dispositivo($1::jsonb) r`, [JSON.stringify({ id_dispositivo: uuid, app: 'mosExpress' })])).rows[0].r;
const pd = (await c.query(`select extract(epoch from (now()-pendiente_desde)) s from mos.dispositivos where id_dispositivo=$1`, [uuid])).rows[0].s;
chk('dispositivo: tras 5 min el reenvío PISA (pendiente_desde fresco)', r3.enviado === true && Number(pd) < 5, `edad=${Math.round(pd)}s`);

// horario: cooldown + pisa
const rh1 = (await c.query(`select mos.solicitar_extension_horario($1::jsonb) r`, [JSON.stringify({ deviceId: uuid, app: 'mosExpress', motivo: 'prueba 1' })])).rows[0].r;
const rh2 = (await c.query(`select mos.solicitar_extension_horario($1::jsonb) r`, [JSON.stringify({ deviceId: uuid, app: 'mosExpress', motivo: 'prueba 2' })])).rows[0].r;
chk('horario: 1ª solicitud crea alerta', rh1.ok === true && rh1.data?.pendiente === true, JSON.stringify(rh1).slice(0, 90));
chk('horario: reintento inmediato → cooldown con segundos', rh2.data?.cooldown === true && rh2.data?.retrySeg > 290, JSON.stringify(rh2.data));
await c.query(`update mos.seguridad_alertas set fecha = now() - interval '6 minutes'
  where tipo='EXTENSION_HORARIO_PENDIENTE' and estado='PENDIENTE' and id_dispositivo=$1`, [uuid]);
const rh3 = (await c.query(`select mos.solicitar_extension_horario($1::jsonb) r`, [JSON.stringify({ deviceId: uuid, app: 'mosExpress', motivo: 'prueba 3' })])).rows[0].r;
const alertas = (await c.query(`select estado, count(*) n from mos.seguridad_alertas
  where tipo='EXTENSION_HORARIO_PENDIENTE' and id_dispositivo=$1 group by 1`, [uuid])).rows;
chk('horario: tras 5 min la nueva PISA (vieja REEMPLAZADA, 1 sola PENDIENTE)',
  rh3.data?.pendiente === true && alertas.some(a => a.estado === 'REEMPLAZADA' && a.n === '1')
  && alertas.some(a => a.estado === 'PENDIENTE' && a.n === '1'), JSON.stringify(alertas));

// TTL 1h
await c.query(`update mos.seguridad_alertas set fecha = now() - interval '65 minutes'
  where tipo='EXTENSION_HORARIO_PENDIENTE' and estado='PENDIENTE' and id_dispositivo=$1`, [uuid]);
await c.query(`select mos.vencer_extensiones_horario()`);
const venc = (await c.query(`select count(*) filter (where estado='PENDIENTE') pend,
  count(*) filter (where estado='VENCIDA') venc from mos.seguridad_alertas
  where tipo='EXTENSION_HORARIO_PENDIENTE' and id_dispositivo=$1`, [uuid])).rows[0];
chk('TTL: a la hora la solicitud VENCE sola (cero PENDIENTES)', venc?.pend === '0' && venc?.venc === '1', JSON.stringify(venc));

// listado con Pendiente_Desde
const lista = (await c.query(`select mos.listar_dispositivos('{}'::jsonb) r`)).rows[0].r;
const fila = (lista.data || lista || []).find?.(x => x.ID_Dispositivo === uuid) ||
  (Array.isArray(lista.data) ? lista.data.find(x => x.ID_Dispositivo === uuid) : null);
chk('listar_dispositivos ya expone Pendiente_Desde', !!fila && typeof fila.Pendiente_Desde === 'string' && fila.Pendiente_Desde.length > 0,
  JSON.stringify({ pd: fila?.Pendiente_Desde }));

t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 110) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }
await c.query(sad); await c.query(seh); await c.query(veh); await c.query(ld);
console.log(`\n✅ ${t.length}/${t.length} — 635 aplicado`);
fs.writeFileSync('635_solicitudes_ttl_cooldown.sql', sad + '\n\n' + seh + '\n\n' + veh + '\n\n' + ld);
await c.end();
