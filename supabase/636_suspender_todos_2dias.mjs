// 636 · La regla de 2 días aplica a TODOS los dispositivos, panel MOS incluido
// (decisión dueña 2026-08-05: "¿por qué veo dispositivos con más de dos días?").
// La exclusión vieja ("los MOS solo se alertan") dejaba paneles ACTIVOS por 14 días
// ensuciando la zona VIP. Seguro ANTI-ENCIERRO: un panel MOS solo se suspende si
// queda al menos OTRO panel MOS activo con conexión fresca (<2 días) — jamás te
// quedas sin ninguna puerta para entrar a reactivar.
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
let def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='mos' and p.proname='cron_dispositivos_inactivos' and p.prokind='f'`)).rows[0].d;

def = rep(def,
  `  -- 1) SUSPENDER operativos con +2 días sin conectar (excluye panel MOS/'').
  with sus as (
    update mos.dispositivos set
        estado = 'SUSPENDIDO',
        suspendido_desde = now()
      where upper(coalesce(estado,'')) = 'ACTIVO'
        and upper(coalesce(app,'')) not in ('MOS','')
        and ultima_conexion is not null
        and ultima_conexion < now() - interval '2 days'
      returning id_dispositivo, coalesce(nullif(btrim(nombre_equipo),''), left(id_dispositivo,8)) nom, app
  )`,
  `  -- 1) [636] SUSPENDER +2 días sin conectar — TODOS, panel MOS incluido (decisión
  --    dueña). ANTI-ENCIERRO: un panel MOS solo cae si queda OTRO panel MOS activo
  --    con conexión fresca — nunca te quedas sin puerta para reactivar.
  with sus as (
    update mos.dispositivos set
        estado = 'SUSPENDIDO',
        suspendido_desde = now()
      where upper(coalesce(estado,'')) = 'ACTIVO'
        and ultima_conexion is not null
        and ultima_conexion < now() - interval '2 days'
        and (upper(coalesce(app,'')) not in ('MOS','')
             or exists (select 1 from mos.dispositivos m2
                         where upper(coalesce(m2.app,'')) in ('MOS','')
                           and upper(coalesce(m2.estado,'')) = 'ACTIVO'
                           and m2.ultima_conexion > now() - interval '2 days'
                           and m2.id_dispositivo <> mos.dispositivos.id_dispositivo))
      returning id_dispositivo, coalesce(nullif(btrim(nombre_equipo),''), left(id_dispositivo,8)) nom, app
  )`,
  'suspender-todos');

def = rep(def,
  `    where upper(coalesce(estado,'')) = 'SUSPENDIDO'
      and upper(coalesce(app,'')) not in ('MOS','')
      and ultima_conexion is not null
      and ultima_conexion < now() - interval '7 days';`,
  `    where upper(coalesce(estado,'')) = 'SUSPENDIDO'
      and ultima_conexion is not null
      and ultima_conexion < now() - interval '7 days';   -- [636] MOS incluido (sigue reversible)`,
  'cancelar-todos');

def = rep(def,
  `  -- 2) los MOS (o sin app) inactivos solo se ALERTAN (nunca auto-suspender/cancelar el panel)`,
  `  -- 2) [636] los MOS que QUEDARON activos pese a +2 días = el último panel (anti-encierro): solo alertar`,
  'comentario');

await c.query('begin');
await c.query(def);
const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };

const antes = (await c.query(`select count(*) n from mos.dispositivos where upper(estado)='ACTIVO' and ultima_conexion < now() - interval '2 days'`)).rows[0].n;
const r = (await c.query(`select mos.cron_dispositivos_inactivos() r`)).rows[0].r;
const despues = (await c.query(`select count(*) n from mos.dispositivos where upper(estado)='ACTIVO' and ultima_conexion < now() - interval '2 days'`)).rows[0].n;
chk(`el cron ahora suspende también paneles MOS (antes ${antes} rezagados → quedan ${despues})`, r.ok === true && Number(despues) < Number(antes), JSON.stringify(r));
// anti-encierro: queda al menos un MOS activo fresco
const frescos = (await c.query(`select count(*) n from mos.dispositivos where upper(coalesce(app,'')) in ('MOS','') and upper(estado)='ACTIVO'`)).rows[0].n;
chk('anti-encierro: sigue habiendo panel(es) MOS activos', Number(frescos) >= 1, frescos);
// suspendido_desde queda sellado (para el "suspendido hace X" de la UI)
const sinSello = (await c.query(`select count(*) n from mos.dispositivos where upper(estado)='SUSPENDIDO' and suspendido_desde is null`)).rows[0].n;
chk('todos los suspendidos tienen su fecha (duración visible)', Number(sinSello) === 0, sinSello);

t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 110) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }

await c.query(def);
// corrida REAL inmediata: limpia los rezagados de una vez (lo que Luis está viendo en VIP)
const rr = (await c.query(`select mos.cron_dispositivos_inactivos() r`)).rows[0].r;
console.log(`\n✅ ${t.length}/${t.length} — 636 aplicado · corrida real:`, JSON.stringify(rr));
fs.writeFileSync('636_suspender_todos_2dias.sql', def);
await c.end();
