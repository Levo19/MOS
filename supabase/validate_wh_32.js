const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host: 'aws-1-us-east-1.pooler.supabase.com', port: 5432, user: 'postgres.rzbzdeipbtqkzjqdchqk', password: PASS, database: 'postgres', ssl: { rejectUnauthorized: false } });
const call = async (p) => (await c.query(`select wh.crear_preingreso($1::jsonb) r`, [JSON.stringify(p)])).rows[0].r;
let pass = 0, fail = 0;
const chk = (n, cond, extra) => { if (cond) { pass++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra || ''); } };
(async () => {
  await c.connect();
  try {
    await c.query('begin');
    await c.query(`update mos.config set valor='1' where clave='WH_CREAR_PREINGRESO_DIRECTO'`);

    let r = await call({ id_preingreso:'PITEST1', id_proveedor:'PROV004', usuario:'val', monto:'652.5', cargadores:'[{"id":"C1"}]', comentario:'test' });
    chk('crea ok', r.ok===true && r.dedup===false, r);
    const p = (await c.query(`select * from wh.preingresos where id_preingreso='PITEST1'`)).rows[0];
    chk('fila correcta', p && p.estado==='PENDIENTE' && p.id_proveedor==='PROV004' && Number(p.monto)===652.5
        && p.cargadores==='[{"id":"C1"}]' && p.comentario==='test' && p.id_guia==='', p);

    r = await call({ id_preingreso:'PITEST1', id_proveedor:'PROV004', usuario:'val', monto:'652.5' });
    chk('idempotencia dedup=true', r.dedup===true, r);
    chk('idempotencia: 1 sola fila', (await c.query(`select count(*)::int n from wh.preingresos where id_preingreso='PITEST1'`)).rows[0].n===1);

    r = await call({ id_preingreso:'PITEST2', usuario:'val' });   chk('monto vacio → 0 ok', r.ok===true, r);
    chk('monto default 0', Number((await c.query(`select monto from wh.preingresos where id_preingreso='PITEST2'`)).rows[0].monto)===0);

    r = await call({ usuario:'val' });   chk('falta id rechazado', r.ok===false && r.error==='FALTAN_PARAMS', r);

    console.log(`\n${fail===0?'✅ TODOS':'❌ HAY FALLOS'} — pass:${pass} fail:${fail}`);
  } catch (e) { console.error('❌ ERROR:', e.message); fail++; }
  finally { await c.query('rollback').catch(()=>{}); await c.end(); console.log('(rollback — nada persistió)'); }
})();
