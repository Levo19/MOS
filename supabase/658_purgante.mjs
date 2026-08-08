// 658 · EL PURGANTE — purga remota one-shot para las 3 PWA (MOS · ME · MosGo)
//
//   ── QUÉ RESUELVE ──────────────────────────────────────────────────────────────
//   Dispositivos que se quedan con el Service Worker viejo pegado y no actualizan.
//   El MASTER sube UN valor en mos.config y, al siguiente arranque, TODOS los equipos
//   se purgan UNA sola vez: matan el SW, borran cachés y storage basura, conservan
//   intacta la lista blanca (identidad, sesión, colas offline de dinero) y recargan
//   limpios contra la última versión.
//
//   ── EL FLAG ───────────────────────────────────────────────────────────────────
//   mos.config.MOS_PURGANTE_TOKEN, expuesto por mos.get_flags() como 'purganteToken'.
//   Se eligió mos.get_flags (y NO me.get_flags ni ruta_boot) porque:
//     · anon tiene EXECUTE sobre ella (verificado) → las 3 apps la llaman SIN sesión,
//       SIN token minteado y ANTES del candado DeviceAuth. Es lo más temprano posible.
//     · ya es el interruptor central de la flota: device-auth.js la consulta desde
//       ME/MosGo/WH en cada heartbeat. Un token nuevo NO agrega superficie.
//     · una sola clave manda sobre las 3 apps → un solo disparo, nada de desincronía.
//   NOMBRE: 'MOS_PURGANTE_TOKEN', NO 'MOS_PURGA_*'. Ya existe MOS_PURGA_DIRECTO, que
//   es OTRA COSA (purga de catálogo). Confundirlas sería caro.
//
//   ── VALOR INICIAL '0' = DESARMADO (el mecanismo queda DORMIDO) ─────────────────
//   El cliente trata '0' / vacío / ausente como "no hay orden" y NO hace NADA: ni
//   purga, ni marca, ni reporta. Costo cero. El gate solo actúa cuando el MASTER
//   sube el token a un epoch. Ningún dispositivo tiene '0' como "hecho", pero eso da
//   igual: '0' ni siquiera se compara.
//
//   ── TELEMETRÍA ────────────────────────────────────────────────────────────────
//   mos.purgante_log (RLS ON, 0 policies, REVOKE a anon/authenticated) + 2 RPC:
//     · mos.purgante_reportar(p) — anon, la llama el dispositivo recién purgado.
//       UNIQUE (device_id, app, token) ⇒ idempotente: reintentos no duplican fila.
//     · mos.purgante_estado(p)   — cerrada a anon. Quién ya se purgó y quién falta.
//
//   Parche con def VIVA verificada; tests dentro de begin/rollback ANTES de aplicar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const T = []; const chk = (n, cond, x) => { T.push([cond ? '✅' : '❌', n, x === undefined ? '' : String(x)]); return cond; };

await c.query('begin');

// ── 1 · el flag, DESARMADO ────────────────────────────────────────────────────
await c.query(`
insert into mos.config (clave, valor, descripcion) values
  ('MOS_PURGANTE_TOKEN', '0',
   'PURGANTE · orden de purga remota one-shot para MOS/ME/MosGo. 0 = DESARMADO (nadie hace nada). ' ||
   'Subirlo a un epoch (select extract(epoch from now())::bigint::text) ordena a TODA la flota purgarse ' ||
   'UNA vez al siguiente arranque. No confundir con MOS_PURGA_DIRECTO (purga de catalogo).')
on conflict (clave) do nothing;
`);

// ── 2 · mos.get_flags — se parcha la def VIVA, no se reescribe de memoria ──────
{
  const viva = (await c.query(
    `select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'mos' and p.proname = 'get_flags' limit 1`)).rows[0].d;

  chk('get_flags · def viva recuperada', /jsonb_build_object/.test(viva), viva.length + ' chars');
  chk('get_flags · aun NO tiene purganteToken', !/purganteToken/.test(viva));

  // El CTE `f` filtra por `clave like 'MOS\_%'` ⇒ MOS_PURGANTE_TOKEN ya entra sin tocar el WHERE.
  chk('get_flags · el CTE f ya captura MOS\\_%', /clave like 'MOS/.test(viva));

  const ancla = `'catalogoDirecto',    coalesce((select valor from f where clave='MOS_CATALOGO_DIRECTO'),    '0'),`;
  chk('get_flags · ancla de inserción presente', viva.includes(ancla));

  const nuevo = viva.replace(ancla, ancla + `
    -- ── [658 · PURGANTE] orden de purga remota one-shot. '0' = DESARMADO ────────
    'purganteToken',      coalesce((select valor from f where clave='MOS_PURGANTE_TOKEN'),      '0'),`);
  chk('get_flags · reemplazo aplicado', nuevo !== viva && /purganteToken/.test(nuevo));
  await c.query(nuevo);
}

// ── 3 · tabla de telemetría ───────────────────────────────────────────────────
await c.query(`
create table if not exists mos.purgante_log (
  id            bigserial primary key,
  device_id     text        not null,
  app           text        not null,
  token         text        not null,
  version_antes text,
  reintento     boolean     not null default false,
  user_agent    text,
  created_at    timestamptz not null default now()
);
create unique index if not exists purgante_log_uk    on mos.purgante_log (device_id, app, token);
create index        if not exists purgante_log_tok_ix on mos.purgante_log (token, created_at desc);

alter table mos.purgante_log enable  row level security;
alter table mos.purgante_log force   row level security;
revoke all on table    mos.purgante_log        from public, anon, authenticated;
revoke all on sequence mos.purgante_log_id_seq from public, anon, authenticated;
`);

// ── 4 · RPC purgante_reportar — la llama el dispositivo YA purgado (anon) ──────
await c.query(`
create or replace function mos.purgante_reportar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
set statement_timeout to '8s'
as $fn$
declare
  v_dev text := left(btrim(coalesce(p->>'device', '')), 80);
  v_app text := left(btrim(coalesce(p->>'app',    '')), 24);
  v_tok text := left(btrim(coalesce(p->>'token',  '')), 40);
  v_ver text := left(btrim(coalesce(p->>'version_antes', '')), 40);
  v_ua  text := left(btrim(coalesce(p->>'ua', '')), 400);
  v_re  boolean := coalesce((p->>'reintento')::boolean, false);
begin
  -- Sin device o sin token no hay nada que registrar: se contesta ok igual para que
  -- el cliente NUNCA reintente en bucle por un dato que jamás va a mejorar.
  if v_dev = '' or v_tok = '' or v_tok = '0' then
    return jsonb_build_object('ok', true, 'guardado', false, 'razon', 'incompleto');
  end if;
  if v_app not in ('MOS', 'mosExpress', 'mosGo', 'warehouseMos') then
    return jsonb_build_object('ok', true, 'guardado', false, 'razon', 'app_desconocida');
  end if;

  insert into mos.purgante_log (device_id, app, token, version_antes, reintento, user_agent)
  values (v_dev, v_app, v_tok, nullif(v_ver, ''), v_re, nullif(v_ua, ''))
  on conflict (device_id, app, token) do nothing;

  return jsonb_build_object('ok', true, 'guardado', true);
exception when others then
  -- La telemetría JAMÁS puede romperle el arranque a un equipo.
  return jsonb_build_object('ok', true, 'guardado', false, 'razon', 'error');
end;
$fn$;

revoke all on function mos.purgante_reportar(jsonb) from public;
grant execute on function mos.purgante_reportar(jsonb) to anon, authenticated, service_role;
`);

// ── 5 · RPC purgante_estado — avance de la purga (NO anon) ─────────────────────
await c.query(`
create or replace function mos.purgante_estado(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
set statement_timeout to '15s'
as $fn$
declare
  v_tok  text := nullif(btrim(coalesce(p->>'token', '')), '');
  v_dias int  := least(greatest(coalesce((p->>'dias')::int, 30), 1), 365);
  v_res  jsonb;
begin
  if current_user not in ('postgres', 'service_role', 'authenticated') then
    return jsonb_build_object('error', 'NO_AUTORIZADO');
  end if;

  if v_tok is null then
    select valor into v_tok from mos.config where clave = 'MOS_PURGANTE_TOKEN';
    v_tok := coalesce(v_tok, '0');
  end if;

  with viv as (
    select d.id_dispositivo, d.app, d.nombre_equipo, d.estado, d.ultima_conexion
      from mos.dispositivos d
     where d.app in ('MOS', 'mosExpress', 'mosGo')
       and d.estado = 'ACTIVO'
       and d.ultima_conexion > now() - (v_dias || ' days')::interval
  ),
  j as (
    select v.*, l.created_at purgado_at, l.version_antes
      from viv v
      left join mos.purgante_log l
        on l.device_id = v.id_dispositivo and l.app = v.app and l.token = v_tok
  )
  select jsonb_build_object(
    'token',      v_tok,
    'armado',     (v_tok <> '0' and v_tok <> ''),
    'total',      count(*),
    'purgados',   count(*) filter (where purgado_at is not null),
    'pendientes', count(*) filter (where purgado_at is null),
    'detalle',    coalesce(jsonb_agg(jsonb_build_object(
                    'device',        id_dispositivo,
                    'app',           app,
                    'nombre',        nombre_equipo,
                    'purgado',       purgado_at is not null,
                    'purgado_at',    purgado_at,
                    'version_antes', version_antes,
                    'ultima_conexion', ultima_conexion
                  ) order by app, purgado_at nulls first, ultima_conexion desc), '[]'::jsonb)
  ) into v_res from j;

  return coalesce(v_res, jsonb_build_object('token', v_tok, 'total', 0));
end;
$fn$;

revoke all on function mos.purgante_estado(jsonb) from public, anon;
grant execute on function mos.purgante_estado(jsonb) to authenticated, service_role;
`);

// ══ TESTS ═════════════════════════════════════════════════════════════════════
const anon = async (sql, params) => {
  await c.query('savepoint spa'); await c.query(`set local role anon`);
  let r, e = null;
  try { r = await c.query(sql, params); } catch (err) { e = err; }
  // OJO: si la sentencia falló, la transacción queda ABORTADA y `reset role` también
  // reventaría. Primero se deshace el savepoint, recién después se suelta el rol.
  if (e) { await c.query('rollback to savepoint spa'); await c.query('reset role'); throw e; }
  await c.query('reset role'); await c.query('release savepoint spa');
  return r;
};

// 1 · el flag nace DESARMADO y viaja por get_flags
{
  const v = (await c.query(`select valor from mos.config where clave='MOS_PURGANTE_TOKEN'`)).rows[0];
  chk('flag · MOS_PURGANTE_TOKEN existe y vale 0 (DORMIDO)', v && v.valor === '0', v && v.valor);

  const f = (await anon(`select mos.get_flags() f`)).rows[0].f;
  chk('get_flags · anon ve purganteToken', Object.prototype.hasOwnProperty.call(f, 'purganteToken'));
  chk('get_flags · purganteToken = 0 (desarmado)', f.purganteToken === '0', f.purganteToken);
  chk('get_flags · NO rompió el resto de flags', f.catalogoDirecto === '1' && Array.isArray(f.dispositivos_revocados),
    'catalogoDirecto=' + f.catalogoDirecto);
}

// 2 · al ARMARLO el token viaja tal cual
{
  await c.query(`update mos.config set valor='1754600000' where clave='MOS_PURGANTE_TOKEN'`);
  const f = (await anon(`select mos.get_flags() f`)).rows[0].f;
  chk('get_flags · armado → el token nuevo llega al cliente', f.purganteToken === '1754600000', f.purganteToken);
}

const TOK = '1754600000';
const DEV_MOS = '7e57c1a0-de1c-4a7e-b0de-c47a10906474';
const DEV_ME  = '7e57c1a0-de1c-4a7e-b0de-c47a10906476';

// 3 · purgante_reportar
{
  const r1 = (await anon(`select mos.purgante_reportar($1::jsonb) r`,
    [JSON.stringify({ device: DEV_MOS, app: 'MOS', token: TOK, version_antes: '2.43.708', ua: 'harness-658' })])).rows[0].r;
  chk('reportar · anon puede reportar', r1.ok === true && r1.guardado === true, JSON.stringify(r1));

  const n1 = (await c.query(`select count(*)::int n from mos.purgante_log where token=$1`, [TOK])).rows[0].n;
  chk('reportar · quedó 1 fila', n1 === 1, n1);

  const r2 = (await anon(`select mos.purgante_reportar($1::jsonb) r`,
    [JSON.stringify({ device: DEV_MOS, app: 'MOS', token: TOK, reintento: true, ua: 'harness-658' })])).rows[0].r;
  const n2 = (await c.query(`select count(*)::int n from mos.purgante_log where token=$1`, [TOK])).rows[0].n;
  chk('reportar · IDEMPOTENTE (reintento no duplica)', r2.ok === true && n2 === 1, 'filas=' + n2);

  const sinDev = (await anon(`select mos.purgante_reportar($1::jsonb) r`,
    [JSON.stringify({ app: 'MOS', token: TOK })])).rows[0].r;
  chk('reportar · sin device → ok pero NO guarda (no hay bucle)', sinDev.ok === true && sinDev.guardado === false,
    sinDev.razon);

  const tok0 = (await anon(`select mos.purgante_reportar($1::jsonb) r`,
    [JSON.stringify({ device: DEV_MOS, app: 'MOS', token: '0' })])).rows[0].r;
  chk('reportar · token 0 (desarmado) NUNCA se registra', tok0.guardado === false, tok0.razon);

  const appMala = (await anon(`select mos.purgante_reportar($1::jsonb) r`,
    [JSON.stringify({ device: DEV_MOS, app: 'DROP TABLE', token: TOK })])).rows[0].r;
  chk('reportar · app desconocida rechazada', appMala.guardado === false, appMala.razon);

  await anon(`select mos.purgante_reportar($1::jsonb) r`,
    [JSON.stringify({ device: DEV_ME, app: 'mosExpress', token: TOK, version_antes: '2.8.267', ua: 'harness-658' })]);
}

// 4 · la tabla NO es legible por PostgREST
{
  let leyo = true;
  try { await anon(`select count(*) from mos.purgante_log`); } catch (_) { leyo = false; }
  chk('purgante_log · anon NO la puede leer', leyo === false);

  let escribio = true;
  try { await anon(`insert into mos.purgante_log(device_id,app,token) values ('x','MOS','y')`); } catch (_) { escribio = false; }
  chk('purgante_log · anon NO la puede escribir directo (solo por RPC)', escribio === false);
}

// 5 · purgante_estado
{
  let anonVio = null;
  try { anonVio = (await anon(`select mos.purgante_estado('{}'::jsonb) r`)).rows[0].r; } catch (_) { anonVio = 'EXCEPCION'; }
  chk('estado · anon NO puede (sin grant)', anonVio === 'EXCEPCION');

  const E = (await c.query(`select mos.purgante_estado($1::jsonb) r`, [JSON.stringify({ dias: 365 })])).rows[0].r;
  chk('estado · reporta el token armado', E.token === TOK && E.armado === true, E.token);
  chk('estado · cuenta purgados', E.purgados >= 2, 'purgados=' + E.purgados + ' de ' + E.total);
  chk('estado · cuenta pendientes', E.pendientes === E.total - E.purgados,
    'pendientes=' + E.pendientes);
  const d = (E.detalle || []).find(x => x.device === DEV_MOS);
  chk('estado · el TEST-CLAUDE MOS figura purgado con su versión', d && d.purgado === true && d.version_antes === '2.43.708',
    JSON.stringify(d || {}).slice(0, 90));

  const E0 = (await c.query(`select mos.purgante_estado($1::jsonb) r`, [JSON.stringify({ token: '0' })])).rows[0].r;
  chk('estado · token 0 → armado=false', E0.armado === false);
}

// 6 · el retrato del avance (lo que verá el MASTER)
{
  const E = (await c.query(`select mos.purgante_estado($1::jsonb) r`, [JSON.stringify({ dias: 365 })])).rows[0].r;
  console.log(`\n🧹 AVANCE DE PURGA (token de prueba ${E.token}): ${E.purgados}/${E.total} purgados, ${E.pendientes} pendientes`);
  for (const x of (E.detalle || []).slice(0, 8)) {
    console.log(`   ${x.purgado ? '✔' : '·'} ${String(x.app).padEnd(11)} ${x.device.slice(0, 8)}  ${x.nombre || '(sin nombre)'}` +
      `${x.version_antes ? '  desde v' + x.version_antes : ''}`);
  }
}

// ── DEJAR EL MECANISMO DORMIDO ────────────────────────────────────────────────
// Los tests ARMARON el token para probarlo. Se vuelve a '0' y se borra la telemetría
// del harness: al aplicar, producción queda con el purgante CONSTRUIDO pero DORMIDO.
{
  await c.query(`update mos.config set valor='0' where clave='MOS_PURGANTE_TOKEN'`);
  const del = (await c.query(`delete from mos.purgante_log where coalesce(user_agent,'') like 'harness-658%' or token=$1`, [TOK])).rowCount;
  const quedan = (await c.query(`select count(*)::int n from mos.purgante_log`)).rows[0].n;
  const v = (await c.query(`select valor from mos.config where clave='MOS_PURGANTE_TOKEN'`)).rows[0].valor;
  chk('DORMIDO · el token vuelve a 0 tras los tests', v === '0', v);
  chk('DORMIDO · el harness no deja telemetría en PROD', quedan === 0, `borradas=${del} quedan=${quedan}`);
  if (quedan === 0) await c.query(`alter sequence mos.purgante_log_id_seq restart with 1`);

  const f = (await anon(`select mos.get_flags() f`)).rows[0].f;
  chk('DORMIDO · get_flags entrega purganteToken=0 → ningún equipo hará nada', f.purganteToken === '0');
}

const ok = T.every(t => t[0] === '✅');
console.log('\n' + T.map(t => `${t[0]} ${t[1]}${t[2] ? '  → ' + t[2] : ''}`).join('\n'));
if (ok && process.argv.includes('--apply')) { await c.query('commit'); console.log('\n🟢 658 APLICADO — purgante CONSTRUIDO y DORMIDO (MOS_PURGANTE_TOKEN=0)'); }
else { await c.query('rollback'); console.log(ok ? '\n🟡 tests OK — corre con --apply para aplicar' : '\n🔴 ROLLBACK: hay tests en rojo'); }
await c.end();
