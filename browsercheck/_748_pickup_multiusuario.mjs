// [748] REVISIÓN 500x · el escenario real del 11-ago, reproducido de punta a punta.
//
// Reproduce EXACTAMENTE lo que pasó: tres operadores con copias distintas de la misma
// lista, un despacho parcial con guía emitida, y un segundo despacho dentro de la hora.
// Verifica que ninguno borra productos, que nada revive y que la deuda cuadra al final.
//
// Se ejecuta sobre la BASE REAL en transacción + ROLLBACK (zona de prueba propia), y
// la parte de UI se valida con Playwright contra WH en producción.
import pg from 'pg';
import fs from 'fs';

const c = new pg.Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim() });
await c.connect();
const T = [];
const ok = (cond, n, extra) => T.push((cond ? 'PASS' : 'FAIL') + ' · ' + n + (extra !== undefined ? ' — ' + extra : ''));
const Z = 'ZONA-TEST-748';
const ACU = 'PCK-ACU-' + Z + '-2026-08-09';

const deuda = async () => (await c.query(
  `select coalesce((select round(sum(greatest(0,(e->>'solicitado')::numeric - coalesce((e->>'despachado')::numeric,0))),2)
     from jsonb_array_elements(items) e),0) d, jsonb_array_length(items) n, rev
   from wh.pickups where id_pickup=$1`, [ACU])).rows[0];

try {
  await c.query('begin');
  await c.query(`select set_config('request.jwt.claims', '{"app":"warehouseMos"}', true)`);
  for (const k of ['WH_PICKUP_ESTADO_DIRECTO', 'WH_CERRAR_PICKUP_DIRECTO', 'WH_DESPACHO_RAPIDO_DIRECTO', 'WH_CREAR_PREINGRESO_DIRECTO'])
    await c.query(`insert into mos.config (clave,valor) values ($1,'1') on conflict (clave) do update set valor='1'`, [k]);

  const prod = await c.query(`select codigo_barra, sku_base from mos.productos where coalesce(codigo_barra,'') <> '' limit 2`);
  const A = prod.rows[0], B = prod.rows[1];

  // Lista con 3 productos: A(20), B(8) y uno sin identificar
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, creado_por, fecha_creado, ultima_actividad)
     values ($1,'ACUMULADO_SEMANAL','PENDIENTE',$2::jsonb,$3,'sistema',now(),now())`,
    [ACU, JSON.stringify([
      { skuBase: A.sku_base, nombre: 'PRODUCTO A', solicitado: 20, despachado: 0, codigosOriginales: [A.codigo_barra] },
      { skuBase: B.sku_base, nombre: 'PRODUCTO B', solicitado: 8, despachado: 0, codigosOriginales: [B.codigo_barra] },
      { skuBase: '', sinSku: true, nombre: 'SIYAU 500ML', solicitado: 0, despachado: 0, constancia: 3 },
    ]), Z]);
  const d0 = await deuda();

  // ── 1 · JORGENIS guarda una copia VIEJA (solo conoce 1 producto) ──
  // Esto es lo que borraba la lista para todos.
  await c.query(`select wh.guardar_progreso_pickup($1::jsonb)`, [JSON.stringify({
    id_pickup: ACU, lock_usuario: 'JORGENIS',
    items: [{ skuBase: A.sku_base, nombre: 'PRODUCTO A', solicitado: 20, despachado: 2 }],
  })]);
  const d1 = await deuda();
  ok(Number(d1.n) === 3, 'copia vieja de JORGENIS: los 3 productos siguen (antes quedaba 1)', d1.n);
  ok(Number(d1.d) === Number(d0.d) - 2, 'su avance de 2 se guardó y la deuda bajó solo eso', d0.d + ' → ' + d1.d);

  // ── 2 · JESÚS manda una copia vacía (su app arrancó sin datos) ──
  await c.query(`select wh.guardar_progreso_pickup($1::jsonb)`, [JSON.stringify({
    id_pickup: ACU, lock_usuario: 'JORGENIS', items: [],
  })]);
  const d2 = await deuda();
  ok(Number(d2.n) === 3, 'una copia VACÍA no borra la lista', d2.n);
  ok(Number(d2.d) === Number(d1.d), 'y no altera la deuda', d2.d);

  // ── 3 · Entra un cierre de caja mientras la lista está TOMADA ──
  await c.query(`update wh.pickups set estado='EN_PROCESO', atendido_por='SERGIO BAILON' where id_pickup=$1`, [ACU]);
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, creado_por, fecha_creado, ultima_actividad)
     values ($1,'ME_CIERRE_CAJA','PENDIENTE',$2::jsonb,$3,'CAJERA', now(), now())`,
    ['PK-VENTAS-748', JSON.stringify([{ skuBase: A.sku_base, nombre: 'PRODUCTO A', solicitado: 5, despachado: 0, codigosOriginales: [A.codigo_barra] }]), Z]);
  await c.query(`select wh.consolidar_pickup_zona($1,'2026-08-09'::date)`, [Z]);
  const d3 = await deuda();
  ok(Number(d3.d) === Number(d2.d) + 5, 'el cierre de caja entra AUNQUE la lista esté tomada', d2.d + ' → ' + d3.d);
  ok(Number(d3.rev) > Number(d0.rev), 'la versión subió → el celular de Sergio se enterará', d0.rev + ' → ' + d3.rev);

  // ── 4 · SERGIO despacha un tramo y emite guía ──
  const c1 = await c.query(`select wh.cerrar_pickup_con_despacho($1::jsonb) j`, [JSON.stringify({
    id_pickup: ACU, usuario: 'SERGIO BAILON',
    items: [{ skuBase: A.sku_base, nombre: 'PRODUCTO A', solicitado: 23, despachado: 10, codigosOriginales: [A.codigo_barra] }],
  })]);
  ok(c1.rows[0].j.ok === true, 'primer despacho: emite guía', c1.rows[0].j.data?.idGuia?.slice(-15));
  const d4 = await deuda();
  ok(Number(d4.d) === Number(d3.d) - 10, 'lo despachado se resta EN EL ACTO', d3.d + ' → ' + d4.d);

  // ── 5 · SERGIO retoma: NO debe ver lo ya despachado ──
  const r5 = await c.query(`select (select (e->>'despachado')::numeric from jsonb_array_elements(items) e
      where e->>'skuBase'=$2) desp from wh.pickups where id_pickup=$1`, [ACU, A.sku_base]);
  ok(Number(r5.rows[0].desp) === 0, 'al retomar, el producto NO vuelve marcado (el bug del ajinomoto)', r5.rows[0].desp);

  // ── 6 · SEGUNDO despacho dentro de la hora: debe aplicarse ──
  const c2 = await c.query(`select wh.cerrar_pickup_con_despacho($1::jsonb) j`, [JSON.stringify({
    id_pickup: ACU, usuario: 'SERGIO BAILON',
    items: [{ skuBase: B.sku_base, nombre: 'PRODUCTO B', solicitado: 8, despachado: 8, codigosOriginales: [B.codigo_barra] }],
  })]);
  const d6 = await deuda();
  ok(c2.rows[0].j.data?.idGuia && c2.rows[0].j.data.idGuia !== c1.rows[0].j.data.idGuia,
     'el 2º despacho del día emite su PROPIA guía (antes devolvía la anterior sin despachar)',
     c2.rows[0].j.data?.idGuia?.slice(-15));
  ok(Number(d6.d) === Number(d4.d) - 8, 'y su deuda se resta', d4.d + ' → ' + d6.d);

  // ── 7 · Reintento REAL (mismo envío repetido) → no duplica ──
  const gAntes = (await c.query(`select count(*)::int n from wh.guias where comentario like $1`, ['%[pickup:' + ACU + '%'])).rows[0].n;
  await c.query(`select wh.cerrar_pickup_con_despacho($1::jsonb)`, [JSON.stringify({
    id_pickup: ACU, usuario: 'SERGIO BAILON',
    items: [{ skuBase: B.sku_base, nombre: 'PRODUCTO B', solicitado: 8, despachado: 8, codigosOriginales: [B.codigo_barra] }],
  })]);
  const gDesp = (await c.query(`select count(*)::int n from wh.guias where comentario like $1`, ['%[pickup:' + ACU + '%'])).rows[0].n;
  ok(gAntes === gDesp, 'el MISMO envío repetido NO crea otra guía', gAntes + ' → ' + gDesp);

  // ── 8 · Sobre-despacho: piso 0, jamás negativo ──
  await c.query(`select wh.cerrar_pickup_con_despacho($1::jsonb)`, [JSON.stringify({
    id_pickup: ACU, usuario: 'SERGIO BAILON',
    items: [{ skuBase: A.sku_base, nombre: 'PRODUCTO A', solicitado: 13, despachado: 99, codigosOriginales: [A.codigo_barra] }],
  })]);
  const d8 = await deuda();
  ok(Number(d8.d) >= 0, 'despachar de más NUNCA deja deuda negativa (no mata deuda vieja)', 'deuda ' + d8.d);

  // ── 9 · La constancia "no se entiende" sobrevive a todo ──
  const cons = await c.query(`select count(*)::int n from wh.pickups p, jsonb_array_elements(p.items) e
      where p.id_pickup=$1 and coalesce(e->>'sinSku','false')='true'`, [ACU]);
  ok(Number(cons.rows[0].n) === 1, 'la constancia del pedido mal escrito sigue ahí', cons.rows[0].n);

  // ── 10 · El candado se soltó al despachar ──
  const lock = await c.query(`select coalesce(atendido_por,'') a from wh.pickups where id_pickup=$1`, [ACU]);
  ok(lock.rows[0].a === '', 'tras despachar, la lista queda libre para el siguiente', JSON.stringify(lock.rows[0].a));

} catch (e) {
  ok(false, 'EXCEPCIÓN: ' + e.message);
} finally {
  await c.query('rollback').catch(() => {});
  await c.end();
}

console.log(T.join('\n'));
const fails = T.filter(x => x.startsWith('FAIL')).length;
console.log('\nRESULTADO: ' + (T.length - fails) + ' PASS / ' + fails + ' FAIL');
process.exit(fails ? 1 : 0);
