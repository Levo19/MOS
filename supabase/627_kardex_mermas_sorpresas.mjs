// 627 · CERRAR EL AGUJERO DEL KARDEX: mermas y sorpresas movían wh.stock sin dejar
// movimiento en wh.stock_movimientos.
//
// Auditoría previa: los 11.470 renglones del kardex cuadran uno por uno y no hay ni un
// movimiento duplicado (o sea: NO hay doble descuento). Pero 168 enlaces de la cadena
// tienen salto — el `stock_antes` de un movimiento no coincide con el `stock_despues`
// del anterior — y casi todos separados por más de un día, o sea: alguien movió el
// stock por fuera. De las 17 funciones que escriben wh.stock, 13 registran el kardex
// y estas 4 no: registrar_sorpresa, merma_alta_manual, procesar_merma y
// mermas_eliminar_batch.
//
// Se agrega un helper central wh._kardex() y se lo llama justo después de cada uno de
// los 6 updates de stock. Nada cambia en la lógica de negocio: sólo queda el rastro.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

// ── helper central: se llama DESPUÉS del update; lee el stock ya aplicado y deduce el antes.
const HELPER = `
create or replace function wh._kardex(p_cod text, p_delta numeric, p_tipo text, p_origen text, p_usuario text)
returns void language plpgsql security definer set search_path to '' as $$
declare v_desp numeric; v_id text;
begin
  if coalesce(btrim(p_cod),'') = '' or coalesce(p_delta,0) = 0 then return; end if;
  select cantidad_disponible into v_desp from wh.stock
   where upper(cod_producto) = upper(btrim(p_cod)) order by id_stock limit 1;
  if not found then return; end if;
  v_id := 'MOV-' || upper(btrim(p_tipo)) || '-' || md5(p_cod || coalesce(p_origen,'') || p_delta::text || clock_timestamp()::text);
  insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
  values (v_id, now(), btrim(p_cod), p_delta, round(v_desp - p_delta, 3), v_desp,
          upper(btrim(p_tipo)), nullif(btrim(coalesce(p_origen,'')),''), nullif(btrim(coalesce(p_usuario,'')),''))
  on conflict (id_mov) do nothing;
exception when others then null;  -- el kardex jamás puede tumbar la operación
end; $$;`;

// ── los 6 puntos donde hay que dejar rastro
const PARCHES = [
  { fn: 'registrar_sorpresa', tipo: 'SORPRESA', usuario: 'v_admin',
    from: `    update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_delta,
                        ultima_actualizacion = now()
     where upper(cod_producto) = upper(v_cod);`,
    cod: 'v_cod', delta: '-v_delta', origen: 'v_id_guia' },

  { fn: 'merma_alta_manual', tipo: 'MERMA_ALTA', usuario: 'v_usuario',
    from: `  update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_cant,
                      ultima_actualizacion = now()
   where upper(cod_producto) = upper(v_cod);`,
    cod: 'v_cod', delta: '-v_cant', origen: 'v_id' },

  { fn: 'procesar_merma', tipo: 'MERMA_TRANSFORMA_INGRESO', usuario: 'v_usuario',
    from: `      update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) + v_qdst,
                          ultima_actualizacion = now()
       where upper(cod_producto) = upper(v_cdst);`,
    cod: 'v_cdst', delta: 'v_qdst', origen: 'v_id' },

  { fn: 'procesar_merma', tipo: 'MERMA_DESECHO', usuario: 'v_usuario',
    from: `        update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_cant,
                            ultima_actualizacion = now()
         where upper(cod_producto) = upper(m.cod_producto);`,
    cod: 'm.cod_producto', delta: '-v_cant', origen: 'v_id' },

  { fn: 'procesar_merma', tipo: 'MERMA_REPARADA', usuario: 'v_usuario',
    from: `        update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) + v_cant,
                            ultima_actualizacion = now()
         where upper(cod_producto) = upper(m.cod_producto);`,
    cod: 'm.cod_producto', delta: 'v_cant', origen: 'v_id' },

  { fn: 'mermas_eliminar_batch', tipo: 'MERMA_ELIMINADA', usuario: 'v_usuario',
    from: `      update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - m.cantidad_pendiente,
                          ultima_actualizacion = now()
       where upper(cod_producto) = upper(m.cod_producto);`,
    cod: 'm.cod_producto', delta: '-m.cantidad_pendiente', origen: 'm.id_merma' },
];

const traer = async (fn) => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh' and p.proname=$1 and p.prokind='f' limit 1`, [fn])).rows[0].d;

// variables que existen en cada función (para no referenciar una inexistente)
const defs = {};
for (const fn of ['registrar_sorpresa', 'merma_alta_manual', 'procesar_merma', 'mermas_eliminar_batch']) defs[fn] = await traer(fn);

const nuevas = {};
for (const p of PARCHES) {
  let d = nuevas[p.fn] || defs[p.fn];
  const n = d.split(p.from).length - 1;
  if (n !== 1) throw new Error(`[${p.fn}/${p.tipo}] esperaba 1 coincidencia, hay ${n}`);
  // usuario: si la variable no existe en esa función, mandamos literal
  const usr = new RegExp(`\\b${p.usuario}\\b`).test(d) ? p.usuario : `'sistema'`;
  const org = new RegExp(`\\b${p.origen.replace('.', '\\.')}\\b`).test(d) ? p.origen : `'${p.tipo}'`;
  d = d.replace(p.from, `${p.from}
    -- [627] dejar rastro en el kardex (antes esto movía stock sin registrar el movimiento)
    perform wh._kardex(${p.cod}, ${p.delta}, '${p.tipo}', ${org}, ${usr});`);
  nuevas[p.fn] = d;
}

// ── verificación en tx
await c.query('begin');
await c.query(HELPER);
for (const fn of Object.keys(nuevas)) await c.query(nuevas[fn]);

const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };
chk('el helper wh._kardex existe',
  (await c.query(`select count(*) n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname='wh' and p.proname='_kardex'`)).rows[0].n === '1');

for (const fn of Object.keys(nuevas)) {
  const viva = await traer(fn);
  chk(`wh.${fn} ahora registra el kardex`, /perform wh\._kardex\(/.test(viva));
}
chk('procesar_merma cubre sus TRES movimientos',
  ((await traer('procesar_merma')).match(/perform wh\._kardex\(/g) || []).length === 3);

// prueba de humo REAL: mover stock por el helper y ver el renglón
const cod = (await c.query(`select cod_producto from wh.stock where cantidad_disponible > 5 order by random() limit 1`)).rows[0]?.cod_producto;
if (cod) {
  const antes = (await c.query(`select cantidad_disponible q from wh.stock where cod_producto=$1`, [cod])).rows[0].q;
  await c.query(`update wh.stock set cantidad_disponible = cantidad_disponible - 3 where upper(cod_producto)=upper($1)`, [cod]);
  await c.query(`select wh._kardex($1, -3, 'TEST627', 'PRUEBA', 'test')`, [cod]);
  const m = (await c.query(`select stock_antes, delta, stock_despues, tipo_operacion from wh.stock_movimientos
     where cod_producto=$1 and tipo_operacion='TEST627'`, [cod])).rows[0];
  chk('el movimiento queda registrado con antes/delta/después coherentes',
    m && Math.abs(Number(m.stock_antes) - Number(antes)) < 0.001 &&
         Math.abs(Number(m.stock_despues) - (Number(antes) - 3)) < 0.001,
    m ? `antes=${m.stock_antes} delta=${m.delta} desp=${m.stock_despues}` : 'no se registró');
  chk('la cadena queda continua (stock_despues = stock real)',
    m && Math.abs(Number(m.stock_despues) -
      Number((await c.query(`select cantidad_disponible q from wh.stock where cod_producto=$1`, [cod])).rows[0].q)) < 0.001);
}
chk('un delta 0 no ensucia el kardex',
  (await c.query(`select count(*) n from (select wh._kardex('X627',0,'T','o','u')) _,
     lateral (select 1) __ where exists (select 1 from wh.stock_movimientos where tipo_operacion='T')`)).rows[0].n === '0');

t.forEach(([s, n, x]) => console.log(' ', s, n, x ? '· ' + String(x).slice(0, 90) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }

await c.query(HELPER);
for (const fn of Object.keys(nuevas)) await c.query(nuevas[fn]);
console.log(`\n✅ ${t.length}/${t.length} — 627 aplicado (mermas y sorpresas ya dejan rastro)`);
fs.writeFileSync('627_kardex_mermas_sorpresas.sql', HELPER + '\n\n' + Object.values(nuevas).join('\n\n'));
await c.end();
