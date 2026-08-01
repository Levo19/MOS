// Smoke 604 en TX + ROLLBACK: aviso 20h, anulación 24h sin escaneos, auto-cierre con escaneos.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const q = async (sql, args) => (await c.query(sql, args)).rows;
let fallos = 0;
const ok = (n, cond, x) => { console.log((cond ? '✓' : '✗ FALLO'), n, x ?? ''); if (!cond) fallos++; };
await c.query('begin');
try {
  // fabricar 3 listas: A=25h con escaneos (auto-cierre) · B=25h sin escaneos (anular) · C=21h sin escaneos (aviso)
  const itemsA = JSON.stringify([
    { skuBase: 'LEV192', nombre: 'ACHIOTE GRANEL', cantidad: 5, cantidadEscaneada: 3 },
    { skuBase: 'LEV149', nombre: 'AJONJOLI BLANCO', cantidad: 10, cantidadEscaneada: 0 }
  ]);
  const itemsB = JSON.stringify([{ skuBase: 'LEV192', nombre: 'ACHIOTE', cantidad: 4, cantidadEscaneada: 0 }]);
  await c.query(`insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, zona)
    values ('LSTEST604A', now() - interval '25 hours', 'PRUEBA CLAUDE', $1::jsonb, 'DISPONIBLE', 'ZONA-01'),
           ('LSTEST604B', now() - interval '25 hours', 'PRUEBA CLAUDE', $2::jsonb, 'DISPONIBLE', 'ZONA-01'),
           ('LSTEST604C', now() - interval '21 hours', 'PRUEBA CLAUDE', $2::jsonb, 'DISPONIBLE', 'ZONA-01')`,
    [itemsA, itemsB]);

  const r1 = (await q(`select wh.vencer_listas_sombra() r`))[0].r;
  console.log('cron →', JSON.stringify(r1));
  ok('B anulada + C avisada + A auto-cerrada contadas', r1.autoCerradas >= 1 && r1.avisadas >= 1 && r1.vencidasDisponibles >= 1, '');

  const a = (await q(`select estado, nota from wh.listas_sombra where id_lista='LSTEST604A'`))[0];
  ok('A → COMPLETADA con nota 604', a.estado === 'COMPLETADA' && /604: auto-cierre/.test(a.nota), a.nota?.slice(-70));
  const guiaA = await q(`select id_guia, (select count(*) from wh.guia_detalle gd where gd.id_guia=g.id_guia) lineas
    from wh.guias g where id_guia='GLSC_LSTEST604A'`);
  ok('A → guía GLSC creada con 1 línea (solo lo escaneado)', guiaA.length === 1 && Number(guiaA[0].lineas) === 1, JSON.stringify(guiaA));
  const pickA = await q(`select estado, jsonb_array_length(items) n from wh.pickups where id_pickup='PCK-LSC-LSTEST604A'`);
  ok('A → pickup PCK-LSC (sol/desp al acumulado)', pickA.length === 1, JSON.stringify(pickA));
  const b = (await q(`select estado, nota from wh.listas_sombra where id_lista='LSTEST604B'`))[0];
  ok('B → ANULADA sin acumular', b.estado === 'ANULADA' && /vencida/.test(b.nota), '');
  const pickB = await q(`select 1 from wh.pickups where id_pickup='PCK-LSC-LSTEST604B'`);
  ok('B → sin pickup', pickB.length === 0);
  const cRow = (await q(`select estado, nota from wh.listas_sombra where id_lista='LSTEST604C'`))[0];
  ok('C → sigue DISPONIBLE con [aviso-ttl]', cRow.estado === 'DISPONIBLE' && /\[aviso-ttl\]/.test(cRow.nota), '');

  // idempotencia: 2ª corrida no re-avisa ni re-cierra
  const r2 = (await q(`select wh.vencer_listas_sombra() r`))[0].r;
  ok('2ª corrida: 0 avisos y 0 auto-cierres nuevos', r2.avisadas === 0 && r2.autoCerradas === 0, JSON.stringify(r2));

  // [604b] GUÍA GEMELA: lista escaneada 3 uds/1 item + guía SALIDA ya existente misma zona/total/líneas
  await c.query(`insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, zona)
    values ('LSTEST604D', now() - interval '25 hours', 'PRUEBA CLAUDE',
            '[{"skuBase":"LEV192","nombre":"ACHIOTE","cantidad":5,"cantidadEscaneada":3}]'::jsonb, 'DISPONIBLE', 'ZONA-01')`);
  await c.query(`insert into wh.guias (id_guia,tipo,fecha,usuario,comentario,monto_total,estado,id_proveedor,id_zona,numero_documento,id_preingreso,foto)
    values ('GTEST604TWIN','SALIDA_ZONA', now() - interval '24 hours', 'PRUEBA CLAUDE','despacho normal',0,'CERRADA','','ZONA-01','','','')`);
  await c.query(`insert into wh.guia_detalle (id_guia,linea,cod_producto,cant_esperada,cant_recibida,precio_unitario,id_lote,observacion,id_producto_nuevo,id_detalle,fecha_vencimiento)
    values ('GTEST604TWIN',1,'X-ACHIOTE',3,3,0,'','','','DTEST604TWIN',null)`);
  const r3 = (await q(`select wh.vencer_listas_sombra() r`))[0].r;
  const d = (await q(`select estado, nota from wh.listas_sombra where id_lista='LSTEST604D'`))[0];
  ok('D → COMPLETADA con gemela detectada (sin guía nueva)', d.estado === 'COMPLETADA' && /gemela detectada GTEST604TWIN/.test(d.nota), d.nota?.slice(-70));
  const guiaD = await q(`select 1 from wh.guias where id_guia='GLSC_LSTEST604D'`);
  ok('D → NO se creó guía GLSC (evita doble descuento)', guiaD.length === 0, JSON.stringify(r3));

  // [605] candado frío: EN_USO tomada hace 40 min sin actividad → DISPONIBLE (escaneos intactos)
  await c.query(`insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, zona, usuario_tomada, fecha_tomada, ultima_actividad)
    values ('LSTEST605E', now() - interval '2 hours', 'PRUEBA CLAUDE',
            '[{"skuBase":"LEV192","nombre":"ACHIOTE","cantidad":5,"cantidadEscaneada":2}]'::jsonb,
            'EN_USO', 'ZONA-01', 'OPERADOR FANTASMA', now() - interval '40 minutes', now() - interval '40 minutes')`);
  const r4 = (await q(`select wh.vencer_listas_sombra() r`))[0].r;
  const e = (await q(`select estado, usuario_tomada, nota,
      (select sum((it->>'cantidadEscaneada')::numeric) from jsonb_array_elements(items) it) esc
    from wh.listas_sombra where id_lista='LSTEST605E'`))[0];
  ok('E → candado liberado a los 30min (DISPONIBLE, sin dueño, escaneos intactos)',
     e.estado === 'DISPONIBLE' && e.usuario_tomada === null && Number(e.esc) === 2 && /605: candado liberado/.test(e.nota),
     JSON.stringify(r4));
} finally {
  await c.query('rollback');
  console.log('ROLLBACK OK — nada persistió · FALLOS:', fallos);
}
const resid = await q(`select count(*) n from wh.listas_sombra where id_lista like 'LSTEST604%'`);
console.log('residuos:', resid[0].n);
await c.end();
process.exit(fallos ? 1 : 0);
