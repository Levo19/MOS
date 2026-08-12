// [743] EL ESCENARIO DE SERGIO, tal cual lo contó Luis:
//   "despacha 20 ajinomoto, lo emite y todo; al rato lo vuelve a retomar y aparecía
//    la barra de 20 ajinomoto como si hubiera estado separado otra vez"
// Regla del dueño: al retomar solo debe verse LO QUE FALTA, nunca lo ya despachado.
// Todo en transacción + ROLLBACK.
import pg from 'pg';
import fs from 'fs';

const c = new pg.Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim() });
await c.connect();
const T = [];
const ok = (cond, n, extra) => T.push((cond ? 'PASS' : 'FAIL') + ' · ' + n + (extra !== undefined ? ' — ' + extra : ''));
const Z = 'ZONA-TEST-743';
const ACU = 'PCK-ACU-' + Z + '-2026-08-09';

try {
  await c.query('begin');
  await c.query(`select set_config('request.jwt.claims', '{"app":"warehouseMos"}', true)`);
  for (const k of ['WH_PICKUP_ESTADO_DIRECTO', 'WH_CERRAR_PICKUP_DIRECTO', 'WH_DESPACHO_RAPIDO_DIRECTO'])
    await c.query(`insert into mos.config (clave,valor) values ($1,'1')
                   on conflict (clave) do update set valor='1'`, [k]);

  // Un producto real, para que la guía pueda crearse
  const prod = await c.query(`select codigo_barra, sku_base from mos.productos
                              where coalesce(codigo_barra,'') <> '' limit 1`);
  const CB = prod.rows[0].codigo_barra, SKU = prod.rows[0].sku_base;

  // Acumulado: se deben 20 (5 que venían de ayer + 15 de hoy)
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, creado_por, fecha_creado, ultima_actividad)
     values ($1,'ACUMULADO_SEMANAL','EN_PROCESO',$2::jsonb,$3,'sistema',now(),now())`,
    [ACU, JSON.stringify([
      { skuBase: SKU, nombre: 'AJINOMOTO 1KG', solicitado: 20, despachado: 0, codigosOriginales: [CB] },
      { skuBase: 'SKU-OTRO', nombre: 'ARROZ', solicitado: 8, despachado: 0, codigosOriginales: ['0000000000001'] },
    ]), Z]);

  const rev0 = (await c.query(`select rev from wh.pickups where id_pickup=$1`, [ACU])).rows[0].rev;

  // ── Sergio despacha 20 del ajinomoto y emite la guía ──
  const cierre = await c.query(`select wh.cerrar_pickup_con_despacho($1::jsonb) j`, [JSON.stringify({
    id_pickup: ACU, usuario: 'SERGIO BAILON',
    items: [
      { skuBase: SKU, nombre: 'AJINOMOTO 1KG', solicitado: 20, despachado: 20, codigosOriginales: [CB] },
      { skuBase: 'SKU-OTRO', nombre: 'ARROZ', solicitado: 8, despachado: 0, codigosOriginales: ['0000000000001'] },
    ],
  })]);
  const j = cierre.rows[0].j;
  ok(j.ok === true, 'el despacho se cierra y emite guía', JSON.stringify(j.data?.idGuia || j.error));
  const GUIA = j.data?.idGuia;

  // ── Sergio RETOMA la lista ──
  const q = await c.query(`select jsonb_array_length(items) n, rev,
      (select (e->>'solicitado')::numeric from jsonb_array_elements(items) e where e->>'skuBase'=$2) aji_debe,
      (select (e->>'despachado')::numeric from jsonb_array_elements(items) e where e->>'skuBase'=$2) aji_desp,
      (select (e->>'solicitado')::numeric from jsonb_array_elements(items) e where e->>'skuBase'='SKU-OTRO') arroz_debe
    from wh.pickups where id_pickup=$1`, [ACU, SKU]);
  const row = q.rows[0];

  ok(row.aji_debe === null, 'el ajinomoto YA NO aparece: se despachó completo (ANTES volvía con la barra llena)',
     row.aji_debe === null ? 'ausente' : 'debe ' + row.aji_debe);
  ok(Number(row.n) === 1, 'solo queda el producto que falta', row.n + ' item(s)');
  ok(Number(row.arroz_debe) === 8, 'el que no se despachó sigue debiéndose entero', row.arroz_debe);
  ok(Number(row.rev) > Number(rev0), 'la versión de la lista subió → el celular sabe que está atrasado',
     rev0 + ' → ' + row.rev);

  // ── Despacho PARCIAL: pido 8, despacho 3 → deben quedar 5 ──
  await c.query(`select wh.cerrar_pickup_con_despacho($1::jsonb)`, [JSON.stringify({
    id_pickup: ACU, usuario: 'SERGIO BAILON',
    items: [{ skuBase: 'SKU-OTRO', nombre: 'ARROZ', solicitado: 8, despachado: 3, codigosOriginales: [CB] }],
  })]);
  const q2 = await c.query(`select
      (select (e->>'solicitado')::numeric from jsonb_array_elements(items) e where e->>'skuBase'='SKU-OTRO') debe,
      (select (e->>'despachado')::numeric from jsonb_array_elements(items) e where e->>'skuBase'='SKU-OTRO') desp,
      (select jsonb_array_length(e->'mov') from jsonb_array_elements(items) e where e->>'skuBase'='SKU-OTRO') movs
    from wh.pickups where id_pickup=$1`, [ACU]);
  ok(Number(q2.rows[0].debe) === 5, 'parcial: pedí 8, despaché 3 → debo 5 (la regla del dueño)', q2.rows[0].debe);
  ok(Number(q2.rows[0].desp) === 0, 'el despachado se limpia: no vuelve a contarse como pendiente', q2.rows[0].desp);
  ok(Number(q2.rows[0].movs) >= 1, 'quedó el movimiento en el historial para MOS', q2.rows[0].movs);

  // ── El historial cuenta la verdad (lo que Luis quiere ver en MOS) ──
  const h = await c.query(`select jsonb_pretty(e->'mov') m from wh.pickups p,
      jsonb_array_elements(p.items) e where p.id_pickup=$1 and e->>'skuBase'='SKU-OTRO'`, [ACU]);
  console.log('\nHistorial del producto (lo que verá MOS):\n' + h.rows[0].m + '\n');
  ok(/despacho/.test(h.rows[0].m), 'el historial registra el despacho con su guía');

  // ── No se puede duplicar: reemitir sin nada marcado no crea otra guía ──
  const guiasAntes = (await c.query(`select count(*)::int n from wh.guias where comentario like $1`, ['%[pickup:' + ACU + '%'])).rows[0].n;
  const dup = await c.query(`select wh.cerrar_pickup_con_despacho($1::jsonb) j`, [JSON.stringify({
    id_pickup: ACU, usuario: 'SERGIO BAILON',
    items: [{ skuBase: 'SKU-OTRO', nombre: 'ARROZ', solicitado: 5, despachado: 0, codigosOriginales: [CB] }],
  })]);
  // Sin nada marcado no hay firma → se trata como reintento y DEVUELVE la guía
  // anterior. Lo que importa es que NO nazca una guía nueva (eso sería el duplicado).
  ok(dup.rows[0].j.data?.idempotente === true && Number(guiasAntes) === Number(
       (await c.query(`select count(*)::int n from wh.guias where comentario like $1`, ['%[pickup:' + ACU + '%'])).rows[0].n),
     'sin nada marcado NO nace otra guía: se devuelve la anterior como reintento',
     'guías ' + guiasAntes + ' → sin cambio · idempotente=' + dup.rows[0].j.data?.idempotente);
  const q3 = await c.query(`select (select (e->>'solicitado')::numeric from jsonb_array_elements(items) e
      where e->>'skuBase'='SKU-OTRO') debe from wh.pickups where id_pickup=$1`, [ACU]);
  ok(Number(q3.rows[0].debe) === 5, 'y la deuda no se altera al reabrir/cerrar sin marcar', q3.rows[0].debe);

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
