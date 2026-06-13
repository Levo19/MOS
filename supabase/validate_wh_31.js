// Validación tx-ROLLBACK de wh.registrar_merma: prende el flag y ejecuta casos en una tx que SIEMPRE
// se revierte → no persiste NADA. Verifica inserción correcta + idempotencia + validaciones (vs GAS).
const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host: 'aws-1-us-east-1.pooler.supabase.com', port: 5432, user: 'postgres.rzbzdeipbtqkzjqdchqk', password: PASS, database: 'postgres', ssl: { rejectUnauthorized: false } });
const call = async (p) => (await c.query(`select wh.registrar_merma($1::jsonb) r`, [JSON.stringify(p)])).rows[0].r;
let pass = 0, fail = 0;
const chk = (n, cond, extra) => { if (cond) { pass++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra || ''); } };
(async () => {
  await c.connect();
  try {
    await c.query('begin');
    await c.query(`update mos.config set valor='1' where clave='WH_REGISTRAR_MERMA_DIRECTO'`);

    let r = await call({ id_merma:'MTEST1', codigo_producto:'P001', cantidad:4, motivo:'roto', usuario:'val', responsable:'RECEPCION', foto:'http://x/f.jpg' });
    chk('registro ok', r.ok===true && r.dedup===false, r);
    const m = (await c.query(`select * from wh.mermas where id_merma='MTEST1'`)).rows[0];
    chk('fila insertada con campos correctos', m && Number(m.cantidad_original)===4 && Number(m.cantidad_pendiente)===4
        && m.estado==='EN_PROCESO' && m.cod_producto==='P001' && m.origen==='RECEPCION'
        && Number(m.cantidad_reparada)===0 && Number(m.cantidad_desechada)===0 && m.foto==='http://x/f.jpg', m);

    r = await call({ id_merma:'MTEST1', codigo_producto:'P001', cantidad:4, motivo:'roto', usuario:'val', responsable:'RECEPCION', foto:'http://x/f.jpg' });
    chk('idempotencia dedup=true', r.dedup===true, r);
    chk('idempotencia: sigue 1 sola fila', (await c.query(`select count(*)::int n from wh.mermas where id_merma='MTEST1'`)).rows[0].n===1);

    r = await call({ id_merma:'MTEST2', codigo_producto:'P001', cantidad:4, motivo:'x', usuario:'val' });   chk('sin foto rechazado', r.ok===false && r.error==='FOTO_OBLIGATORIA', r);
    r = await call({ id_merma:'MTEST3', codigo_producto:'P001', cantidad:0, foto:'http://x' });               chk('cantidad 0 rechazada', r.ok===false && r.error==='CANTIDAD_INVALIDA', r);
    r = await call({ id_merma:'', codigo_producto:'P001', cantidad:1, foto:'http://x' });                     chk('falta id rechazado', r.ok===false && r.error==='FALTAN_PARAMS', r);
    r = await call({ id_merma:'MTEST4', cantidad:1, foto:'http://x' });                                       chk('falta codigo rechazado', r.ok===false && r.error==='FALTAN_PARAMS', r);

    console.log(`\n${fail===0?'✅ TODOS':'❌ HAY FALLOS'} — pass:${pass} fail:${fail}`);
  } catch (e) { console.error('❌ ERROR:', e.message); fail++; }
  finally { await c.query('rollback').catch(()=>{}); await c.end(); console.log('(rollback — nada persistió)'); }
})();
