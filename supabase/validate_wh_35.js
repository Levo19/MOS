// Validación tx-ROLLBACK EXHAUSTIVA (40x) de wh.cerrar_guia: stock + lotes + FIFO + idempotencia + envasado.
// Crea guías/stock/lotes de prueba dentro de la tx, ejecuta cierres, verifica, y SIEMPRE rollback (no persiste).
const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host: 'aws-1-us-east-1.pooler.supabase.com', port: 5432, user: 'postgres.rzbzdeipbtqkzjqdchqk', password: PASS, database: 'postgres', ssl: { rejectUnauthorized: false } });
const q = (s, a) => c.query(s, a);
const call = async (p) => (await c.query(`select wh.cerrar_guia($1::jsonb) r`, [JSON.stringify(p)])).rows[0].r;
const stock = async (cod) => { const r = await q(`select cantidad_disponible n from wh.stock where cod_producto=$1`, [cod]); return r.rows.length ? Number(r.rows[0].n) : null; };
const lote = async (id) => (await q(`select cantidad_actual ca, estado e from wh.lotes_vencimiento where id_lote=$1`, [id])).rows[0];
let pass = 0, fail = 0;
const chk = (n, cond, extra) => { if (cond) { pass++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, JSON.stringify(extra)||''); } };
(async () => {
  await c.connect();
  try {
    await q('begin');
    await q(`update mos.config set valor='1' where clave='WH_CERRAR_GUIA_DIRECTO'`);

    // ===== CASO INGRESO: suma stock + crea lote + monto =====
    await q(`insert into wh.guias(id_guia,tipo,fecha,estado,monto_total) values('GTI','INGRESO_PROVEEDOR',now(),'ABIERTA',0)`);
    let r = await call({ id_guia:'GTI', usuario:'val', detalles:[
      { codigo_producto:'CODTI', cantidad_recibida:10, precio_unitario:5, id_lote:'', fecha_vencimiento:'2027-01-01', id_lote_nuevo:'LOTI', id_mov:'MVI' }
    ]});
    chk('INGRESO ok estado CERRADA', r.ok===true && r.estado==='CERRADA', r);
    chk('INGRESO monto = 10*5 = 50', Number(r.montoTotal)===50, r);
    chk('INGRESO stock CODTI = 10 (creado)', (await stock('CODTI'))===10);
    let L = await lote('LOTI'); chk('INGRESO lote LOTI creado cant10 ACTIVO', L && Number(L.ca)===10 && L.e==='ACTIVO', L);
    let mv = (await q(`select stock_antes,stock_despues,delta from wh.stock_movimientos where id_mov='MVI'`)).rows[0];
    chk('INGRESO movimiento antes0/despues10/delta+10', mv && Number(mv.stock_antes)===0 && Number(mv.stock_despues)===10 && Number(mv.delta)===10, mv);
    chk('INGRESO guia CERRADA en tabla', (await q(`select estado from wh.guias where id_guia='GTI'`)).rows[0].estado==='CERRADA');

    // idempotencia: cerrar de nuevo NO reaplica
    r = await call({ id_guia:'GTI', usuario:'val', detalles:[{ codigo_producto:'CODTI', cantidad_recibida:10, precio_unitario:5, id_mov:'MVI2' }]});
    chk('idempotencia yaCerrada=true', r.yaCerrada===true, r);
    chk('idempotencia stock NO cambió (sigue 10)', (await stock('CODTI'))===10);

    // ===== CASO SALIDA: resta stock + consume FIFO (lote viejo primero) =====
    await q(`insert into wh.guias(id_guia,tipo,fecha,estado,monto_total) values('GTS','SALIDA_ZONA',now(),'ABIERTA',0)`);
    await q(`insert into wh.stock(id_stock,cod_producto,cantidad_disponible,ultima_actualizacion) values('STKS','CODTS',100,now())`);
    await q(`insert into wh.lotes_vencimiento(id_lote,cod_producto,fecha_vencimiento,cantidad_inicial,cantidad_actual,id_guia,estado,fecha_creacion) values
      ('LOTA','CODTS','2025-01-01',30,30,'GX','ACTIVO',now()),
      ('LOTB','CODTS','2025-06-01',40,40,'GX','ACTIVO',now())`);
    r = await call({ id_guia:'GTS', usuario:'val', detalles:[{ codigo_producto:'CODTS', cantidad_recibida:50, id_mov:'MVS' }]});
    chk('SALIDA ok', r.ok===true && r.estado==='CERRADA', r);
    chk('SALIDA stock 100-50 = 50', (await stock('CODTS'))===50);
    let la = await lote('LOTA'), lb = await lote('LOTB');
    chk('FIFO: LOTA (más viejo) agotado 0 AGOTADO', la && Number(la.ca)===0 && la.e==='AGOTADO', la);
    chk('FIFO: LOTB consumido 40-20 = 20 ACTIVO', lb && Number(lb.ca)===20 && lb.e==='ACTIVO', lb);

    // ===== CASO SALIDA huérfano: pide más que lotes disponibles =====
    await q(`insert into wh.guias(id_guia,tipo,fecha,estado,monto_total) values('GTH','SALIDA_ZONA',now(),'ABIERTA',0)`);
    await q(`insert into wh.stock(id_stock,cod_producto,cantidad_disponible,ultima_actualizacion) values('STKH','CODTH',100,now())`);
    await q(`insert into wh.lotes_vencimiento(id_lote,cod_producto,fecha_vencimiento,cantidad_inicial,cantidad_actual,id_guia,estado,fecha_creacion) values('LOTH','CODTH','2025-01-01',5,5,'GX','ACTIVO',now())`);
    r = await call({ id_guia:'GTH', usuario:'val', detalles:[{ codigo_producto:'CODTH', cantidad_recibida:8, id_mov:'MVH' }]});
    chk('SALIDA huérfano: stock baja igual 100-8 = 92', (await stock('CODTH'))===92);
    chk('SALIDA huérfano: lote agotado (5→0)', Number((await lote('LOTH')).ca)===0);

    // ===== CASO ENVASADO: NO toca stock =====
    await q(`insert into wh.guias(id_guia,tipo,fecha,estado,monto_total) values('GTE','SALIDA_ENVASADO',now(),'ABIERTA',0)`);
    await q(`insert into wh.stock(id_stock,cod_producto,cantidad_disponible,ultima_actualizacion) values('STKE','CODTE',100,now())`);
    r = await call({ id_guia:'GTE', usuario:'val', detalles:[{ codigo_producto:'CODTE', cantidad_recibida:30, id_mov:'MVE' }]});
    chk('ENVASADO cierra ok', r.ok===true && r.estado==='CERRADA', r);
    chk('ENVASADO NO tocó stock (sigue 100)', (await stock('CODTE'))===100);
    chk('ENVASADO sin movimiento', (await q(`select count(*)::int n from wh.stock_movimientos where id_mov='MVE'`)).rows[0].n===0);

    // ===== guía inexistente =====
    r = await call({ id_guia:'NOEXISTE', detalles:[] });   chk('guia inexistente rechazada', r.ok===false && r.error==='GUIA_NO_ENCONTRADA', r);

    console.log(`\n${fail===0?'✅ TODOS':'❌ HAY FALLOS'} — pass:${pass} fail:${fail}`);
  } catch (e) { console.error('❌ ERROR:', e.message); fail++; }
  finally { await q('rollback').catch(()=>{}); await c.end(); console.log('(rollback — nada persistió)'); }
})();
