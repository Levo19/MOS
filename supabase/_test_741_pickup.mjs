// [741] Pruebas del incidente "a cada operador le aparece distinto / a Sergio se le
// atora la lista / hay dos acumulados en una zona". Todo en transacción + ROLLBACK:
// no toca un solo dato real.
import pg from 'pg';
import fs from 'fs';

const c = new pg.Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim() });
await c.connect();
const T = [];
const ok = (cond, n, extra) => T.push((cond ? 'PASS' : 'FAIL') + ' · ' + n + (extra !== undefined ? ' — ' + extra : ''));
const Z = 'ZONA-TEST-741';

try {
  await c.query('begin');
  // wh._claim_ok() acepta app vacía o 'warehouseMos' (me.jwt_app())
  await c.query(`select set_config('request.jwt.claims', '{"app":"warehouseMos"}', true)`);
  // Los flags de escritura directa tienen que estar en 1 para que las RPC no se corten.
  await c.query(`insert into mos.config (clave, valor) values ('WH_PICKUP_ESTADO_DIRECTO','1')
                 on conflict (clave) do update set valor='1'`);

  const items = (arr) => JSON.stringify(arr);
  const ACU = 'PCK-ACU-' + Z + '-2026-08-09';

  // ── Escenario 1: el autosave con una copia VIEJA no puede borrar productos ──
  // La lista en la base tiene 3 productos (llegó un cierre de caja mientras el
  // operador la tenía abierta). Su dispositivo solo conoce 1.
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, creado_por, fecha_creado, ultima_actividad)
                 values ($1,'ACUMULADO_SEMANAL','EN_PROCESO',$2::jsonb,$3,'sistema',now(),now())`,
    [ACU, items([
      { skuBase: 'SKU-A', nombre: 'ARROZ', solicitado: 10, despachado: 0 },
      { skuBase: 'SKU-B', nombre: 'ACEITE', solicitado: 5, despachado: 0 },
      { skuBase: 'SKU-C', nombre: 'AZUCAR', solicitado: 8, despachado: 2 },
    ]), Z]);

  const r1 = await c.query(`select wh.guardar_progreso_pickup($1::jsonb) j`, [JSON.stringify({
    id_pickup: ACU, lock_usuario: 'SERGIO BAILON',
    items: [{ skuBase: 'SKU-A', nombre: 'ARROZ', solicitado: 10, despachado: 4 }],
  })]);
  ok(r1.rows[0].j.ok === true, 'el autosave con copia vieja no falla', JSON.stringify(r1.rows[0].j));

  const q1 = await c.query(`select jsonb_array_length(items) n,
      (select (e->>'despachado')::numeric from jsonb_array_elements(items) e where e->>'skuBase'='SKU-A') a,
      (select (e->>'despachado')::numeric from jsonb_array_elements(items) e where e->>'skuBase'='SKU-C') cc
    from wh.pickups where id_pickup=$1`, [ACU]);
  ok(Number(q1.rows[0].n) === 3, 'los 3 productos siguen ahí (ANTES quedaba 1)', q1.rows[0].n);
  ok(Number(q1.rows[0].a) === 4, 'se guardó el avance del producto que sí tocó', q1.rows[0].a);
  ok(Number(q1.rows[0].cc) === 2, 'no pisó el avance de un producto que su copia no traía', q1.rows[0].cc);

  // ── Escenario 2: el operador puede corregir HACIA ABAJO ──
  await c.query(`select wh.guardar_progreso_pickup($1::jsonb)`, [JSON.stringify({
    id_pickup: ACU, lock_usuario: 'SERGIO BAILON',
    items: [{ skuBase: 'SKU-A', despachado: 1 }],
  })]);
  const q2 = await c.query(`select (select (e->>'despachado')::numeric from jsonb_array_elements(items) e where e->>'skuBase'='SKU-A') a
    from wh.pickups where id_pickup=$1`, [ACU]);
  ok(Number(q2.rows[0].a) === 1, 'el botón − puede corregir hacia abajo', q2.rows[0].a);

  // ── Escenario 3: un producto que solo trae el dispositivo no se pierde ──
  await c.query(`select wh.guardar_progreso_pickup($1::jsonb)`, [JSON.stringify({
    id_pickup: ACU, lock_usuario: 'SERGIO BAILON',
    items: [{ skuBase: 'SKU-Z', nombre: 'NUEVO DEL DISPOSITIVO', solicitado: 3, despachado: 1 }],
  })]);
  const q3 = await c.query(`select jsonb_array_length(items) n from wh.pickups where id_pickup=$1`, [ACU]);
  ok(Number(q3.rows[0].n) === 4, 'un producto que solo tenía el dispositivo se conserva', q3.rows[0].n);

  // ── Escenario 4: el candado se suelta SOLO a la hora de inactividad real ──
  await c.query(`update wh.pickups set estado='EN_PROCESO', atendido_por='SERGIO BAILON',
                 ultima_actividad = now() - interval '20 minutes' where id_pickup=$1`, [ACU]);
  const l1 = await c.query(`select wh.cron_liberar_pickups_atorados() j`);
  const e1 = await c.query(`select estado, atendido_por from wh.pickups where id_pickup=$1`, [ACU]);
  ok(e1.rows[0].estado === 'EN_PROCESO' && e1.rows[0].atendido_por === 'SERGIO BAILON',
     'a los 20 min sigue tomada (no se le arranca al que está trabajando)', e1.rows[0].estado);

  await c.query(`update wh.pickups set ultima_actividad = now() - interval '61 minutes' where id_pickup=$1`, [ACU]);
  const l2 = await c.query(`select wh.cron_liberar_pickups_atorados() j`);
  const e2 = await c.query(`select estado, atendido_por from wh.pickups where id_pickup=$1`, [ACU]);
  ok(e2.rows[0].estado === 'PENDIENTE' && (e2.rows[0].atendido_por || '') === '',
     'pasada 1 hora se suelta sola', e2.rows[0].estado + '/' + JSON.stringify(e2.rows[0].atendido_por));
  ok(Number(l2.rows[0].j.liberados) >= 1, 'el cron reporta cuántas soltó', JSON.stringify(l2.rows[0].j.liberados));

  // ── Escenario 5: el candado YA NO bloquea la consolidación ──
  // Acumulado de la semana pasada vivo + acumulado de esta semana TOMADO + un
  // cierre de caja nuevo esperando. Antes: el consolidador se iba sin hacer nada.
  const VIEJO = 'PCK-ACU-' + Z + '-2026-08-02';
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, creado_por, fecha_creado, ultima_actividad)
                 values ($1,'ACUMULADO_SEMANAL','PENDIENTE',$2::jsonb,$3,'sistema', now() - interval '9 days', now() - interval '9 days')`,
    [VIEJO, items([{ skuBase: 'SKU-VIEJO', nombre: 'DE LA SEMANA PASADA', solicitado: 7, despachado: 0 }]), Z]);
  await c.query(`update wh.pickups set estado='EN_PROCESO', atendido_por='SERGIO BAILON', ultima_actividad=now()
                 where id_pickup=$1`, [ACU]);
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, creado_por, fecha_creado, ultima_actividad)
                 values ($1,'ME_CIERRE_CAJA','PENDIENTE',$2::jsonb,$3,'Shadya', now(), now())`,
    ['PK-VENTAS-CAJA-TEST741', items([{ skuBase: 'SKU-NUEVO', nombre: 'VENDIDO AYER', solicitado: 6, despachado: 0 }]), Z]);

  const cons = await c.query(`select wh.consolidar_pickup_zona($1, '2026-08-09'::date) j`, [Z]);
  const j = cons.rows[0].j;
  ok(!j.skip, 'el consolidador YA NO se rinde ante el candado (antes: skip EN_PROCESO)', JSON.stringify(j.skip));

  const q5 = await c.query(`select
      (select estado from wh.pickups where id_pickup=$1) viejo,
      (select estado from wh.pickups where id_pickup='PK-VENTAS-CAJA-TEST741') cierre,
      (select count(*) from wh.pickups where id_zona=$2 and fuente='ACUMULADO_SEMANAL'
        and upper(estado) in ('PENDIENTE','EN_PROCESO','PARCIAL')) acumulados_vivos,
      (select bool_or(e->>'skuBase'='SKU-NUEVO') from wh.pickups p, jsonb_array_elements(p.items) e where p.id_pickup=$3) entro
    `, [VIEJO, Z, ACU]);
  ok(q5.rows[0].viejo === 'REZAGADO', 'el acumulado de la semana pasada muere', q5.rows[0].viejo);
  ok(Number(q5.rows[0].acumulados_vivos) === 1, 'queda UN SOLO acumulado vivo por zona', q5.rows[0].acumulados_vivos);
  ok(q5.rows[0].cierre === 'ABSORBIDO', 'el cierre de caja se absorbe aunque la lista esté tomada', q5.rows[0].cierre);
  ok(q5.rows[0].entro === true, 'lo vendido entra al acumulado del operador que está trabajando', q5.rows[0].entro);

  // ── Escenario 6: consolidar NO rejuvenece el candado ──
  await c.query(`update wh.pickups set estado='EN_PROCESO', atendido_por='SERGIO BAILON',
                 ultima_actividad = now() - interval '55 minutes' where id_pickup=$1`, [ACU]);
  await c.query(`select wh.consolidar_pickup_zona($1, '2026-08-09'::date)`, [Z]);
  const q6 = await c.query(`select extract(epoch from (now() - ultima_actividad))/60 min from wh.pickups where id_pickup=$1`, [ACU]);
  ok(Number(q6.rows[0].min) > 50,
     'tras consolidar, el reloj del candado sigue corriendo (ANTES se reiniciaba a 0)',
     Math.round(Number(q6.rows[0].min)) + ' min');

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
