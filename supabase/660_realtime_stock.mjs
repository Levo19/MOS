// 660 · PROPAGACION EN TIEMPO REAL — capa de senales (bumps) del ecosistema.
//
//  A) BUG del bump perdido: mos._bump_catalogo_version usaba pg_try_advisory_xact_lock y, si
//     no conseguia el lock, SALTABA el bump. Reproducido: dos writers concurrentes (mos.zonas ||
//     mos.categorias) -> version subio 1 sola vez en vez de 2. El comentario "otro writer lo hara"
//     es falso: el otro writer ya bumpeo ANTES de que este commiteara, asi que su cambio queda
//     invisible hasta el siguiente bump ajeno. ME y MosGo dependen de esa version.
//     FIX: bump INCONDICIONAL + dedupe por transaccion (GUC local) -> nunca se pierde y ademas
//     una transaccion que toca 5 tablas del catalogo genera 1 solo bump (antes: hasta 5).
//
//  B) THROTTLE de bumps: wh._bump_ops / me._bump_ops se llamaban una vez por STATEMENT. Cerrar
//     una guia de 50 lineas podia disparar decenas de bumps -> decenas de eventos realtime.
//     FIX: mismo dedupe por transaccion -> 1 bump por dominio por transaccion.
//
//  C) SENALES QUE FALTABAN:
//     - mos.promociones: NO tenia trigger de bump. Cambiar una promo no se propagaba a nadie.
//     - wh.stock_movimientos: NO tenia trigger. El kardex depende de esta tabla; wh.stock si
//       bumpea, pero un movimiento que deja el saldo igual (ajuste +x / -x, correccion) no
//       cambiaba wh.stock y el kardex nunca se enteraba.
//
//  NOTA session_replication_role=replica: apaga TODOS los triggers. Toda escritura por esa via
//  debe llamar a mano a wh._bump_ops('stock') / mos._bump_catalogo_version_manual().
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const SQL_FN = `
create or replace function mos._bump_catalogo_version() returns trigger
language plpgsql security definer set search_path to '' as $fn$
begin
  -- [660] Bump INCONDICIONAL (antes: pg_try_advisory_xact_lock -> perdia bumps concurrentes).
  -- Dedupe por transaccion: la primera llamada bumpea, el resto de la misma tx no repite.
  if coalesce(current_setting('mosrt.cat', true), '') = 'y' then
    return null;
  end if;
  perform set_config('mosrt.cat', 'y', true);
  update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1;
  return null;
end; $fn$;

-- Version invocable a mano (replica / Edge / cron que escriben con triggers apagados).
create or replace function mos.bump_catalogo_version_manual() returns bigint
language plpgsql security definer set search_path to '' as $fn$
declare v bigint;
begin
  update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1
    returning version into v;
  return v;
end; $fn$;

create or replace function wh._bump_ops(p_dominio text) returns void
language plpgsql security definer set search_path to '' as $fn$
declare k text := 'mosrt.wh_' || p_dominio;
begin
  -- [660] 1 bump por dominio por transaccion (antes: 1 por statement -> tormenta de eventos).
  if coalesce(current_setting(k, true), '') = 'y' then return; end if;
  perform set_config(k, 'y', true);
  insert into wh.ops_meta (dominio, version, updated_at) values (p_dominio, 1, now())
  on conflict (dominio) do update set version = wh.ops_meta.version + 1, updated_at = now();
end; $fn$;

create or replace function me._bump_ops(p_dominio text) returns void
language plpgsql security definer set search_path to '' as $fn$
declare k text := 'mosrt.me_' || p_dominio;
begin
  -- [660] 1 bump por dominio por transaccion.
  if coalesce(current_setting(k, true), '') = 'y' then return; end if;
  perform set_config(k, 'y', true);
  insert into me.ops_meta (dominio, version, updated_at) values (p_dominio, 1, now())
  on conflict (dominio) do update set version = me.ops_meta.version + 1, updated_at = now();
end; $fn$;
`;

const SQL_TRG = `
-- promociones -> catalogo_version (faltaba por completo)
drop trigger if exists tg_bump_catversion_promociones on mos.promociones;
create trigger tg_bump_catversion_promociones after insert or update or delete on mos.promociones
  for each statement execute function mos._bump_catalogo_version();

-- movimientos de stock -> wh.ops_meta['stock'] (el kardex vive de esta tabla)
drop trigger if exists tg_bump_ops_stock_movimientos on wh.stock_movimientos;
create trigger tg_bump_ops_stock_movimientos after insert or update or delete on wh.stock_movimientos
  for each statement execute function wh._tg_bump_ops('stock');
`;

const ver = async (cl) => (await cl.query(`select version from mos.catalogo_meta where id=1`)).rows[0].version;
const vwh = async (cl) => (await cl.query(`select version from wh.ops_meta where dominio='stock'`)).rows[0].version;

// ---------- TEST en transaccion (begin/rollback) ----------
console.log('== TEST en begin/rollback ==');
await c.query('begin');
await c.query(SQL_FN);
await c.query(SQL_TRG);

// T1: dedupe por transaccion (2 tablas del catalogo en la misma tx = 1 bump)
let v0 = await ver(c);
await c.query(`update mos.zonas set nombre = nombre where true`);
await c.query(`update mos.categorias set nombre = nombre where true`);
let v1 = await ver(c);
console.log('T1 dedupe mismo tx (zonas+categorias): bumps=' + (Number(v1) - Number(v0)) + ' (esperado 1)');

// T2: promociones ahora bumpea
await c.query(`select set_config('mosrt.cat','',true)`); // simular otra tx
v0 = await ver(c);
await c.query(`update mos.promociones set activa = activa where true`);
v1 = await ver(c);
console.log('T2 promociones bumpea: bumps=' + (Number(v1) - Number(v0)) + ' (esperado 1, antes 0)');

// T3: stock_movimientos bumpea wh.ops_meta['stock']
let w0 = await vwh(c);
await c.query(`update wh.stock_movimientos set usuario = usuario where id_mov = (select id_mov from wh.stock_movimientos order by fecha desc limit 1)`);
let w1 = await vwh(c);
console.log('T3 stock_movimientos bumpea stock: bumps=' + (Number(w1) - Number(w0)) + ' (esperado 1, antes 0)');

// T4: throttle — 5 updates sueltos de wh.stock en la misma tx = 1 bump
await c.query(`select set_config('mosrt.wh_stock','',true)`);
w0 = await vwh(c);
const { rows: cods } = await c.query(`select cod_producto from wh.stock order by cod_producto limit 5`);
for (const r of cods) await c.query(`update wh.stock set cantidad_disponible = cantidad_disponible where cod_producto=$1`, [r.cod_producto]);
w1 = await vwh(c);
console.log('T4 throttle 5 statements wh.stock: bumps=' + (Number(w1) - Number(w0)) + ' (esperado 1, antes 5)');

await c.query('rollback');
console.log('rollback ok\n');

// ---------- APLICAR ----------
console.log('== APLICANDO ==');
await c.query('begin');
await c.query(SQL_FN);
await c.query(SQL_TRG);
await c.query('commit');
console.log('aplicado.');

// ---------- VERIFICACION post-aplicacion: el bug del bump perdido ----------
const mk = async () => { const x = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl: { rejectUnauthorized: false } }); await x.connect(); return x; };
const A = await mk(), B = await mk();
const v_ini = await ver(c);
await A.query('begin'); await B.query('begin');
await A.query(`update mos.zonas set nombre = nombre where true`);
await B.query(`update mos.categorias set nombre = nombre where true`);
await A.query('commit'); await B.query('commit');
const v_fin = await ver(c);
console.log('\nVERIF bug bump perdido (2 writers concurrentes): bumps=' + (Number(v_fin) - Number(v_ini)) + ' (antes del fix: 1 · esperado ahora: 2)');
await A.end(); await B.end();
await c.end();
process.exit(0);
