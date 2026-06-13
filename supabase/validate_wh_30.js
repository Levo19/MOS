// Validación tx-ROLLBACK de wh.crear_ajuste: prende el flag y ejecuta casos DENTRO de una transacción
// que SIEMPRE se revierte (rollback) → no persiste NADA. Verifica correctitud vs la lógica esperada (GAS).
const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host: 'aws-1-us-east-1.pooler.supabase.com', port: 5432, user: 'postgres.rzbzdeipbtqkzjqdchqk', password: PASS, database: 'postgres', ssl: { rejectUnauthorized: false } });
const call = async (p) => (await c.query(`select wh.crear_ajuste($1::jsonb) r`, [JSON.stringify(p)])).rows[0].r;
const stockDe = async (cod) => { const r = await c.query(`select cantidad_disponible n from wh.stock where cod_producto=$1 limit 1`, [cod]); return r.rows.length ? Number(r.rows[0].n) : null; };
let pass = 0, fail = 0;
const chk = (name, cond, extra) => { if (cond) { pass++; console.log('  ✅', name); } else { fail++; console.log('  ❌', name, extra || ''); } };
(async () => {
  await c.connect();
  try {
    await c.query('begin');
    await c.query(`update mos.config set valor='1' where clave='WH_CREAR_AJUSTE_DIRECTO'`);
    const cod = (await c.query(`select cod_producto from wh.stock order by id_stock limit 1`)).rows[0].cod_producto;
    const base = await stockDe(cod);
    console.log('Producto existente', cod, 'stock base:', base);
    let r = await call({ id_ajuste:'AJTEST_INC', codigo_producto:cod, tipo:'INC', cantidad:7, motivo:'test', usuario:'val', id_mov:'MVTEST_INC' });
    chk('INC ok', r.ok===true, r);
    chk('INC stockNuevo = base+7', Number(r.stockNuevo)===base+7, r);
    chk('INC stock real actualizado', (await stockDe(cod))===base+7);
    r = await call({ id_ajuste:'AJTEST_DEC', codigo_producto:cod, tipo:'DEC', cantidad:3, motivo:'test', usuario:'val', id_mov:'MVTEST_DEC' });
    chk('DEC stockNuevo = base+4', Number(r.stockNuevo)===base+4, r);
    r = await call({ id_ajuste:'AJTEST_INC', codigo_producto:cod, tipo:'INC', cantidad:7, motivo:'test', usuario:'val', id_mov:'MVTEST_INC' });
    chk('idempotencia dedup=true', r.dedup===true, r);
    chk('idempotencia stock NO cambió (sigue base+4)', (await stockDe(cod))===base+4, await stockDe(cod));
    const codN = 'TESTNUEVO_'+base;
    r = await call({ id_ajuste:'AJTEST_NEW', codigo_producto:codN, tipo:'INC', cantidad:5, motivo:'inicial', usuario:'val', id_stock_nuevo:'STKTEST', id_mov:'MVTEST_NEW' });
    chk('nuevo producto stockNuevo=5', Number(r.stockNuevo)===5, r);
    chk('nuevo producto fila creada', (await stockDe(codN))===5);
    r = await call({ id_ajuste:'AJX', codigo_producto:cod, tipo:'XX', cantidad:1 });   chk('tipo invalido rechazado', r.ok===false && r.error==='TIPO_INVALIDO', r);
    r = await call({ id_ajuste:'AJY', codigo_producto:cod, tipo:'INC', cantidad:0 });   chk('cantidad 0 rechazada', r.ok===false && r.error==='CANTIDAD_INVALIDA', r);
    r = await call({ id_ajuste:'', codigo_producto:cod, tipo:'INC', cantidad:1 });       chk('falta id rechazado', r.ok===false && r.error==='FALTAN_PARAMS', r);
    const mv = (await c.query(`select stock_antes,stock_despues,delta from wh.stock_movimientos where id_mov='MVTEST_INC'`)).rows[0];
    chk('movimiento antes/despues correctos', mv && Number(mv.stock_antes)===base && Number(mv.stock_despues)===base+7, mv);
    console.log(`\n${fail===0?'✅ TODOS':'❌ HAY FALLOS'} — pass:${pass} fail:${fail}`);
  } catch (e) { console.error('❌ ERROR:', e.message); fail++; }
  finally { await c.query('rollback').catch(()=>{}); await c.end(); console.log('(rollback — nada persistió)'); }
})();
