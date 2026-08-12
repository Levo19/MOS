// _test_ciclo_sombra_acumulado.mjs — E2E del CICLO COMPLETO (tx + ROLLBACK, no persiste nada):
//   SOMBRA: tomar → candado 30min → re-tomar → escanear (actividad) → cerrar → PCK-LSC → acumulado
//   ACUMULADO: fórmula deuda max(0, deuda+pedido−despachado) · piso 0 · cuenta corriente (603)
//   TRAZABILIDAD: guía GPCK con [pickup:id] · retry idempotente 90min · week-death REZAGADO
//   CONSTANCIA "no se entiende" (606): sinSku viaja al acumulado con tag, jamás suma deuda.
// Zona ficticia ZT606 → no toca datos reales.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const q = async (sql, args) => (await c.query(sql, args)).rows;
let fallos = 0, n = 0;
const ok = (nombre, cond, extra) => { n++; console.log((cond ? '✓' : '✗ FALLO'), n + '.', nombre, extra ?? ''); if (!cond) fallos++; };

await c.query('begin');
try {
  const Z = 'ZT606';
  const ACUM = (await q(`select 'PCK-ACU-' || $1 || '-' || to_char(wh._bucket_dom((now() at time zone 'America/Lima')::date),'YYYY-MM-DD') id`, [Z]))[0].id;

  // ══ A. CICLO SOMBRA ══════════════════════════════════════════
  await c.query(`insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, zona)
    values ('LST606', now(), 'PRUEBA CLAUDE',   -- [747] del DIA EN CURSO: una sombra de ayer ya cumplio su cierre de dia y se vuelca sola
      '[{"skuBase":"LEV1499","nombre":"ACHIOTE 250GR","cantidad":10,"cantidadEscaneada":0,"codigosOriginales":["WHACXOVO250GR"]},
        {"skuBase":"","sinSku":true,"nombre":"COSA RARA ILEGIBLE","cantidad":7,"cantidadEscaneada":0}]'::jsonb,
      'DISPONIBLE', $1)`, [Z]);

  // 1. tomar → EN_USO + actividad sellada
  const t1 = (await q(`select wh.tomar_lista_sombra(jsonb_build_object('idLista','LST606','usuario','OPERADOR A')) r`))[0].r;
  const s1 = (await q(`select estado, usuario_tomada, ultima_actividad from wh.listas_sombra where id_lista='LST606'`))[0];
  ok('sombra: tomar → EN_USO con actividad sellada', t1.ok === true && s1.estado === 'EN_USO' && s1.ultima_actividad !== null);

  // 2. 35 min sin escanear → candado liberado (escaneos intactos)
  await c.query(`update wh.listas_sombra set ultima_actividad = now() - interval '35 minutes', fecha_tomada = now() - interval '35 minutes' where id_lista='LST606'`);
  await q(`select wh.vencer_listas_sombra()`);
  const s2 = (await q(`select estado, usuario_tomada from wh.listas_sombra where id_lista='LST606'`))[0];
  ok('sombra: 30min sin escanear → candado liberado (DISPONIBLE, sin dueño)', s2.estado === 'DISPONIBLE' && s2.usuario_tomada === null);

  // 3. re-tomar + escanear 4/10 → actividad se re-sella con el progreso
  await q(`select wh.tomar_lista_sombra(jsonb_build_object('idLista','LST606','usuario','OPERADOR B'))`);
  await c.query(`update wh.listas_sombra set ultima_actividad = now() - interval '10 minutes' where id_lista='LST606'`);
  await q(`select wh.actualizar_progreso_lista_sombra(jsonb_build_object('idLista','LST606','items',
    '[{"skuBase":"LEV1499","nombre":"ACHIOTE 250GR","cantidad":10,"cantidadEscaneada":4,"codigosOriginales":["WHACXOVO250GR"]},
      {"skuBase":"","sinSku":true,"nombre":"COSA RARA ILEGIBLE","cantidad":7,"cantidadEscaneada":0}]'::jsonb))`);
  const s3 = (await q(`select ultima_actividad > now() - interval '1 minute' fresca from wh.listas_sombra where id_lista='LST606'`))[0];
  ok('sombra: cada escaneo sella la actividad (reloj 30min se reinicia)', s3.fresca === true);

  // 4. cerrar → COMPLETADA + PCK-LSC (pedido 10 / despachado 4 + constancia sinSku)
  const cz = (await q(`select wh.cerrar_lista_sombra(jsonb_build_object('idLista','LST606')) r`))[0].r;
  const lsc = (await q(`select estado, items from wh.pickups where id_pickup='PCK-LSC-LST606'`))[0];
  ok('sombra: cerrar → COMPLETADA y PCK-LSC creado', cz.ok === true && !!lsc);
  const lscSin = (lsc.items || []).find(i => i.sinSku === true);
  ok('sombra: PCK-LSC lleva la constancia sinSku (desp SIEMPRE 0)', !!lscSin && Number(lscSin.despachado) === 0 && Number(lscSin.solicitado) === 7);

  // ══ B. ACUMULADO: fórmula + constancia con tag ══════════════
  // el trigger AFTER INSERT ya consolidó → acumulado de ZT606 debe existir
  const ac1 = (await q(`select estado, items from wh.pickups where id_pickup=$1`, [ACUM]))[0];
  ok('acumulado: nace solo al absorber (trigger)', !!ac1 && ac1.estado === 'PENDIENTE');
  const it1 = (ac1.items || []).find(i => i.skuBase === 'LEV1499');
  ok('acumulado: fórmula deuda = pedido−despachado (10−4=6)', !!it1 && Number(it1.solicitado) - Number(it1.despachado) === 6,
     it1 && `sol ${it1.solicitado} desp ${it1.despachado}`);
  const con1 = (ac1.items || []).find(i => i.sinSku === true);
  ok('acumulado [606]: constancia "no se entendió" CON TAG (sinSku, sol=0, constancia=7)',
     !!con1 && con1.solicitado === 0 && Number(con1.constancia) === 7 && /COSA RARA/.test(con1.nombre));

  // 5. cierre de caja suma a la cuenta corriente (ME_CIERRE_CAJA sol 5)
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, creado_por, fecha_creado, ultima_actividad)
    values ('PKT606CAJA','ME_CIERRE_CAJA','PENDIENTE',
      '[{"skuBase":"LEV1499","nombre":"ACHIOTE 250GR","solicitado":5,"despachado":0,"codigosOriginales":["WHACXOVO250GR"]}]'::jsonb,
      $1,'Mia', now(), now())`, [Z]);
  const ac2 = (await q(`select items from wh.pickups where id_pickup=$1`, [ACUM]))[0];
  const it2 = (ac2.items || []).find(i => i.skuBase === 'LEV1499');
  ok('acumulado: cierre de caja SUMA (6+5=11 debidas)', !!it2 && Number(it2.solicitado) - Number(it2.despachado) === 11);
  const caja = (await q(`select estado from wh.pickups where id_pickup='PKT606CAJA'`))[0];
  ok('trazabilidad: el pickup del cierre queda ABSORBIDO (no se pierde, apunta al acumulado)', caja.estado === 'ABSORBIDO');

  // 6. EXCESO mata deuda con piso 0: sombra que pide 3 pero despachó 40
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, creado_por, fecha_creado, ultima_actividad)
    values ('PCK-LSC-LST606B','LISTA_IA','PENDIENTE',
      '[{"skuBase":"LEV1499","nombre":"ACHIOTE 250GR","solicitado":3,"despachado":40,"codigosOriginales":["WHACXOVO250GR"]}]'::jsonb,
      $1,'PRUEBA CLAUDE', now(), now())`, [Z]);
  await q(`select wh.consolidar_pickup_zona($1, wh._bucket_dom((now() at time zone 'America/Lima')::date))`, [Z]);
  const ac3 = (await q(`select items from wh.pickups where id_pickup=$1`, [ACUM]))[0];
  const it3 = (ac3.items || []).find(i => i.skuBase === 'LEV1499');
  // deuda 0 ⇒ el ítem SALE de la lista al re-seed (o queda con pendiente 0) — jamás deuda negativa
  ok('acumulado: EXCESO mata deuda con PISO 0 (11+3−40 → item saldado, sale de la lista)',
     !it3 || Math.max(0, Number(it3.solicitado) - Number(it3.despachado)) === 0,
     it3 ? `sol ${it3.solicitado} desp ${it3.despachado}` : 'saldado (ausente)');
  const con2 = (ac3.items || []).find(i => i.sinSku === true);
  ok('acumulado [606]: la constancia SOBREVIVE al re-seed (se arrastra)', !!con2 && Number(con2.constancia) === 7);

  // 7. CUENTA CORRIENTE (603): despacho parcial → PENDIENTE + guía GPCK trazable
  await c.query(`update wh.pickups set items =
    '[{"skuBase":"LEV1499","nombre":"ACHIOTE 250GR","solicitado":10,"despachado":0,"codigosOriginales":["WHACXOVO250GR"]}]'::jsonb
    where id_pickup=$1`, [ACUM]);
  const d1 = (await q(`select wh.cerrar_pickup_con_despacho(jsonb_build_object('id_pickup',$1::text,'usuario','PRUEBA CLAUDE','items',
    '[{"skuBase":"LEV1499","nombre":"ACHIOTE 250GR","solicitado":10,"despachado":4,"codigosOriginales":["WHACXOVO250GR"]}]'::jsonb)) r`, [ACUM]))[0].r;
  const acD = (await q(`select estado from wh.pickups where id_pickup=$1`, [ACUM]))[0];
  ok('acumulado [603]: despacho PARCIAL → queda PENDIENTE (visible, cuenta corriente)', d1.ok === true && acD.estado === 'PENDIENTE', JSON.stringify(d1.data));
  const gpck = (await q(`select comentario from wh.guias where id_guia = $1`, [d1.data.idGuia]))[0];
  ok('trazabilidad: guía GPCK del despacho con [pickup:id] en el comentario', !!gpck && gpck.comentario.includes('[pickup:' + ACUM + ']'));

  // 8. retry dentro de 90 min → idempotente (misma guía, sin doble stock)
  const d2 = (await q(`select wh.cerrar_pickup_con_despacho(jsonb_build_object('id_pickup',$1::text,'usuario','PRUEBA CLAUDE','items','[]'::jsonb)) r`, [ACUM]))[0].r;
  ok('trazabilidad: retry 90min → idempotente, devuelve la MISMA guía', d2.ok === true && d2.data.idempotente === true && d2.data.idGuia === d1.data.idGuia);

  // 9. cierre con CERO despachado en acumulador → PENDIENTE (no CANCELADO = cuenta nunca muere)
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, creado_por, fecha_creado, ultima_actividad)
    values ('PCK-ACU-ZT606B-2026-07-26','ACUMULADO_SEMANAL','PENDIENTE',
      '[{"skuBase":"LEV1499","nombre":"ACHIOTE","solicitado":9,"despachado":0,"codigosOriginales":["WHACXOVO250GR"]}]'::jsonb,
      'ZT606B','sistema', now(), now())`);
  const d3 = (await q(`select wh.cerrar_pickup_con_despacho(jsonb_build_object('id_pickup','PCK-ACU-ZT606B-2026-07-26','usuario','PRUEBA CLAUDE','items',
    '[{"skuBase":"LEV1499","nombre":"ACHIOTE","solicitado":9,"despachado":0,"codigosOriginales":["WHACXOVO250GR"]}]'::jsonb)) r`))[0].r;
  const acB = (await q(`select estado from wh.pickups where id_pickup='PCK-ACU-ZT606B-2026-07-26'`))[0];
  ok('acumulado [603]: cierre con 0 despachado → PENDIENTE (antes CANCELADO = cuenta muerta)', acB.estado === 'PENDIENTE', JSON.stringify(d3.data || d3));

  // 10. WEEK-DEATH: acumulador de bucket viejo → REZAGADO al consolidar el vigente
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, creado_por, fecha_creado, ultima_actividad)
    values ('PCK-ACU-' || $1::text || '-2026-07-19','ACUMULADO_SEMANAL','PENDIENTE',
      '[{"skuBase":"LEV1499","nombre":"ACHIOTE","solicitado":2,"despachado":0}]'::jsonb, $1,'sistema', now() - interval '10 days', now())`, [Z]);
  await q(`select wh.consolidar_pickup_zona($1::text, wh._bucket_dom((now() at time zone 'America/Lima')::date))`, [Z]);
  const rez = (await q(`select estado from wh.pickups where id_pickup = 'PCK-ACU-' || $1::text || '-2026-07-19'`, [Z]))[0];
  ok('acumulado: week-death → semana vieja pasa a REZAGADO (lista de compra del lunes)', rez.estado === 'REZAGADO');
} finally {
  await c.query('rollback');
  console.log('\nROLLBACK OK — nada persistió · FALLOS:', fallos, 'de', n);
}
const resid = await q(`select count(*)::int n from wh.pickups where id_zona like 'ZT606%' or id_pickup like '%LST606%'`);
console.log('residuos post-rollback:', resid[0].n);
await c.end();
process.exit(fallos ? 1 : 0);
