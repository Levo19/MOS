// Validación tx-ROLLBACK de wh.reabrir_guia: revierte stock del cierre, idempotencia, AUTOCERRADA no revierte, envasado.
const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host: 'aws-1-us-east-1.pooler.supabase.com', port: 5432, user: 'postgres.rzbzdeipbtqkzjqdchqk', password: PASS, database: 'postgres', ssl: { rejectUnauthorized: false } });
const q = (s,a)=>c.query(s,a);
const call = async (p) => (await q(`select wh.reabrir_guia($1::jsonb) r`, [JSON.stringify(p)])).rows[0].r;
const stock = async (cod) => { const r = await q(`select cantidad_disponible n from wh.stock where cod_producto=$1`,[cod]); return r.rows.length?Number(r.rows[0].n):null; };
const estado = async (id) => (await q(`select estado e from wh.guias where id_guia=$1`,[id])).rows[0].e;
let pass=0,fail=0; const chk=(n,cond,ex)=>{ if(cond){pass++;console.log('  ✅',n);}else{fail++;console.log('  ❌',n,JSON.stringify(ex)||'');} };
(async () => {
  await c.connect();
  try {
    await q('begin');
    await q(`update mos.config set valor='1' where clave='WH_REABRIR_GUIA_DIRECTO'`);

    // INGRESO CERRADA → reabrir RESTA stock (reverso) + ABIERTA
    await q(`insert into wh.guias(id_guia,tipo,fecha,estado,monto_total) values('RGI','INGRESO_PROVEEDOR',now(),'CERRADA',50)`);
    await q(`insert into wh.stock(id_stock,cod_producto,cantidad_disponible,ultima_actualizacion) values('RSI','RCODI',10,now())`);
    let r = await call({ id_guia:'RGI', usuario:'val', detalles:[{ codigo_producto:'RCODI', cantidad_recibida:10, id_mov:'RMVI' }]});
    chk('INGRESO reabrir ok revertido', r.ok===true && r.revertido===true, r);
    chk('INGRESO reverso: stock 10-10 = 0', (await stock('RCODI'))===0);
    chk('INGRESO estado ABIERTA', (await estado('RGI'))==='ABIERTA');
    let mv=(await q(`select delta,stock_antes,stock_despues from wh.stock_movimientos where id_mov='RMVI'`)).rows[0];
    chk('INGRESO movimiento delta -10', mv && Number(mv.delta)===-10 && Number(mv.stock_despues)===0, mv);

    // idempotencia: reabrir de nuevo (ya ABIERTA) NO vuelve a restar
    r = await call({ id_guia:'RGI', usuario:'val', detalles:[{ codigo_producto:'RCODI', cantidad_recibida:10, id_mov:'RMVI2' }]});
    chk('idempotencia: NO revierte (ya ABIERTA)', r.revertido===false, r);
    chk('idempotencia: stock sigue 0 (no -20)', (await stock('RCODI'))===0);

    // SALIDA CERRADA → reabrir SUMA stock
    await q(`insert into wh.guias(id_guia,tipo,fecha,estado,monto_total) values('RGS','SALIDA_ZONA',now(),'CERRADA',0)`);
    await q(`insert into wh.stock(id_stock,cod_producto,cantidad_disponible,ultima_actualizacion) values('RSS','RCODS',50,now())`);
    r = await call({ id_guia:'RGS', usuario:'val', detalles:[{ codigo_producto:'RCODS', cantidad_recibida:20, id_mov:'RMVS' }]});
    chk('SALIDA reverso: stock 50+20 = 70', (await stock('RCODS'))===70);

    // AUTOCERRADA → NO revierte (nunca aplicó stock)
    await q(`insert into wh.guias(id_guia,tipo,fecha,estado,monto_total) values('RGA','INGRESO_PROVEEDOR',now(),'AUTOCERRADA',0)`);
    await q(`insert into wh.stock(id_stock,cod_producto,cantidad_disponible,ultima_actualizacion) values('RSA','RCODA',30,now())`);
    r = await call({ id_guia:'RGA', usuario:'val', detalles:[{ codigo_producto:'RCODA', cantidad_recibida:5, id_mov:'RMVA' }]});
    chk('AUTOCERRADA NO revierte stock (sigue 30)', (await stock('RCODA'))===30 && r.revertido===false, r);
    chk('AUTOCERRADA pasa a ABIERTA', (await estado('RGA'))==='ABIERTA');

    // ANULADO en detalle → se salta
    await q(`insert into wh.guias(id_guia,tipo,fecha,estado,monto_total) values('RGAN','INGRESO_PROVEEDOR',now(),'CERRADA',0)`);
    await q(`insert into wh.stock(id_stock,cod_producto,cantidad_disponible,ultima_actualizacion) values('RSAN','RCODAN',10,now())`);
    r = await call({ id_guia:'RGAN', usuario:'val', detalles:[{ codigo_producto:'RCODAN', cantidad_recibida:10, observacion:'ANULADO', id_mov:'RMVAN' }]});
    chk('ANULADO no revierte esa linea (stock sigue 10)', (await stock('RCODAN'))===10);

    r = await call({ id_guia:'NOEX', detalles:[] });   chk('guia inexistente rechazada', r.ok===false && r.error==='GUIA_NO_ENCONTRADA', r);

    console.log(`\n${fail===0?'✅ TODOS':'❌ HAY FALLOS'} — pass:${pass} fail:${fail}`);
  } catch (e) { console.error('❌ ERROR:', e.message); fail++; }
  finally { await q('rollback').catch(()=>{}); await c.end(); console.log('(rollback — nada persistió)'); }
})();
