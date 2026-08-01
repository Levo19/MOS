// _envases_smoke_wh.mjs — smoke 599: registrar/anular envasado consume y devuelve el ENVASE.
// TODO dentro de una TX con ROLLBACK (no persiste nada).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const q = async (sql, args) => (await c.query(sql, args)).rows;
let fallos = 0;
const ok = (nombre, cond, extra) => { console.log((cond ? '✓' : '✗ FALLO'), nombre, extra ?? ''); if (!cond) fallos++; };

// datos reales: derivado ACHIOTE 250GR (envase LEV1008), su granel, y el celofán
const der = (await q(`select codigo_barra, envase_sku from mos.productos where codigo_barra='WHACXOVO250GR'`))[0];
const gran = (await q(`select codigo_barra from mos.productos where sku_base='LEV192' and coalesce(btrim(codigo_producto_base),'')='' limit 1`))[0];
const celo = (await q(`select codigo_barra, descripcion from mos.productos where sku_base=$1 and es_insumo limit 1`, [der.envase_sku]))[0];
console.log('derivado WHACXOVO250GR → envase', der.envase_sku, '→ insumo', celo.codigo_barra, celo.descripcion);

await c.query('begin');
try {
  const stockCelo0 = (await q(`select coalesce((select cantidad_disponible from wh.stock where cod_producto=$1 order by id_stock limit 1),0) s`, [celo.codigo_barra]))[0].s;

  // 1) envasar 1 unidad → 0.001 MLL
  const r1 = (await q(`select wh.registrar_envasado(jsonb_build_object(
    'id_envasado','TEST599A','cod_producto_base',$1::text,'cod_producto_envasado','WHACXOVO250GR',
    'cantidad_base','0.25','unidades_producidas','1','unidad_base','KGM','usuario','PRUEBA CLAUDE')) r`, [gran.codigo_barra]))[0].r;
  ok('registrar 1 und ok', r1.ok === true, JSON.stringify(r1));
  ok('envase_cod = celofán', r1.envase_cod === celo.codigo_barra, r1.envase_cod);
  ok('envase_cant = 0.001', Number(r1.envase_cant) === 0.001, r1.envase_cant);
  const linEnv = await q(`select cant_recibida, observacion from wh.guia_detalle where id_detalle='ENVDET_ETEST599A'`);
  ok('línea de envase en guía salida', linEnv.length === 1 && Number(linEnv[0].cant_recibida) === 0.001, JSON.stringify(linEnv));
  const stockCelo1 = (await q(`select cantidad_disponible from wh.stock where cod_producto=$1 order by id_stock limit 1`, [celo.codigo_barra]))[0].cantidad_disponible;
  ok('stock celofán bajó exacto 0.001 (3 decimales)', Number(stockCelo1) === Number(stockCelo0) - 0.001, `${stockCelo0} → ${stockCelo1}`);
  const mov = await q(`select delta, tipo_operacion from wh.stock_movimientos where id_mov='MOVEETEST599A'`);
  ok('kardex ENVASADO_ENVASE -0.001', mov.length === 1 && Number(mov[0].delta) === -0.001 && mov[0].tipo_operacion === 'ENVASADO_ENVASE', JSON.stringify(mov));

  // 2) envasar 1234 unidades → 1.234 MLL
  const r2 = (await q(`select wh.registrar_envasado(jsonb_build_object(
    'id_envasado','TEST599B','cod_producto_base',$1::text,'cod_producto_envasado','WHACXOVO250GR',
    'cantidad_base','308.5','unidades_producidas','1234','unidad_base','KGM','usuario','PRUEBA CLAUDE')) r`, [gran.codigo_barra]))[0].r;
  ok('1234 und → 1.234 MLL', Number(r2.envase_cant) === 1.234, r2.envase_cant);

  // 3) derivado SIN_ENVASE (Nakamito 250) → sin línea de envase, sin error
  const nak = (await q(`select codigo_barra from mos.productos where envase_sku='SIN_ENVASE' limit 1`))[0];
  const r3 = (await q(`select wh.registrar_envasado(jsonb_build_object(
    'id_envasado','TEST599C','cod_producto_base',$1::text,'cod_producto_envasado',$2::text,
    'cantidad_base','1','unidades_producidas','4','unidad_base','KGM','usuario','PRUEBA CLAUDE')) r`, [gran.codigo_barra, nak.codigo_barra]))[0].r;
  ok('SIN_ENVASE: ok y sin envase', r3.ok === true && r3.envase_cod == null, JSON.stringify({ c: r3.envase_cod, q: r3.envase_cant }));

  // 4) derivado PENDIENTE (envase_sku null) → sin línea, sin error
  const pend = (await q(`select codigo_barra from mos.productos where envase_sku is null and coalesce(btrim(codigo_producto_base),'')<>'' limit 1`))[0];
  const r4 = (await q(`select wh.registrar_envasado(jsonb_build_object(
    'id_envasado','TEST599D','cod_producto_base',$1::text,'cod_producto_envasado',$2::text,
    'cantidad_base','1','unidades_producidas','2','unidad_base','KGM','usuario','PRUEBA CLAUDE')) r`, [gran.codigo_barra, pend.codigo_barra]))[0].r;
  ok('PENDIENTE: ok y sin envase', r4.ok === true && r4.envase_cod == null, JSON.stringify({ c: r4.envase_cod }));

  // 5) anular el 1ro → stock celofán restituido y línea ANULADA
  const rA = (await q(`select wh.anular_envasado(jsonb_build_object('id_envasado','TEST599A','usuario','PRUEBA CLAUDE','motivo','smoke')) r`))[0].r;
  ok('anular ok + envase_restit 0.001', rA.ok === true && Number(rA.envase_restit) === 0.001, JSON.stringify(rA));
  const stockCelo2 = (await q(`select cantidad_disponible from wh.stock where cod_producto=$1 order by id_stock limit 1`, [celo.codigo_barra]))[0].cantidad_disponible;
  ok('stock celofán volvió (menos el TEST599B 1.234)', Math.abs(Number(stockCelo2) - (Number(stockCelo0) - 1.234)) < 1e-9, `${stockCelo0} → ${stockCelo2}`);
  const linAn = await q(`select observacion from wh.guia_detalle where id_detalle='ENVDET_ETEST599A'`);
  ok('línea envase marcada ANULADO', /^ANULADO/.test(linAn[0].observacion), linAn[0].observacion);

  // 6) re-anular (idempotencia) → yaAnulado, stock NO doble-restituido
  const rA2 = (await q(`select wh.anular_envasado(jsonb_build_object('id_envasado','TEST599A','usuario','PRUEBA CLAUDE','motivo','smoke2')) r`))[0].r;
  const stockCelo3 = (await q(`select cantidad_disponible from wh.stock where cod_producto=$1 order by id_stock limit 1`, [celo.codigo_barra]))[0].cantidad_disponible;
  ok('re-anular = yaAnulado, stock intacto', rA2.yaAnulado === true && Number(stockCelo3) === Number(stockCelo2), JSON.stringify(rA2));
} finally {
  await c.query('rollback');
  console.log('ROLLBACK OK — nada persistió');
}
const resid = await q(`select count(*) n from wh.envasados where id_envasado like 'TEST599%'`);
console.log('residuos post-rollback:', resid[0].n, '· FALLOS:', fallos);
await c.end();
process.exit(fallos ? 1 : 0);
