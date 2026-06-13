const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host: 'aws-1-us-east-1.pooler.supabase.com', port: 5432, user: 'postgres.rzbzdeipbtqkzjqdchqk', password: PASS, database: 'postgres', ssl: { rejectUnauthorized: false } });
const call = async (p) => (await c.query(`select wh.crear_guia($1::jsonb) r`, [JSON.stringify(p)])).rows[0].r;
let pass = 0, fail = 0;
const chk = (n, cond, extra) => { if (cond) { pass++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra || ''); } };
(async () => {
  await c.connect();
  try {
    await c.query('begin');
    await c.query(`update mos.config set valor='1' where clave='WH_CREAR_GUIA_DIRECTO'`);

    let r = await call({ id_guia:'GTEST1', tipo:'INGRESO_PROVEEDOR', usuario:'val', id_proveedor:'PROV1', comentario:'c', id_preingreso:'PI1' });
    chk('crea ok estado ABIERTA', r.ok===true && r.estado==='ABIERTA' && r.dedup===false, r);
    const g = (await c.query(`select * from wh.guias where id_guia='GTEST1'`)).rows[0];
    chk('cabecera correcta', g && g.tipo==='INGRESO_PROVEEDOR' && Number(g.monto_total)===0 && g.estado==='ABIERTA'
        && g.id_proveedor==='PROV1' && g.id_preingreso==='PI1', g);
    chk('OCR cols null en guia nueva', g.ocr_estado===null && g.ocr_total===null, {ocr_estado:g.ocr_estado});

    r = await call({ id_guia:'GTEST1', tipo:'INGRESO_PROVEEDOR', usuario:'val' });
    chk('idempotencia dedup=true', r.dedup===true, r);
    chk('idempotencia 1 sola fila', (await c.query(`select count(*)::int n from wh.guias where id_guia='GTEST1'`)).rows[0].n===1);

    r = await call({ id_guia:'GTEST2', tipo:'SALIDA_ZONA', usuario:'v' });   chk('tipo SALIDA_ZONA valido', r.ok===true, r);
    r = await call({ id_guia:'GTEST3', tipo:'BASURA', usuario:'v' });        chk('tipo invalido rechazado', r.ok===false && r.error==='TIPO_INVALIDO', r);
    r = await call({ tipo:'INGRESO_PROVEEDOR' });                            chk('falta id rechazado', r.ok===false && r.error==='FALTAN_PARAMS', r);

    console.log(`\n${fail===0?'✅ TODOS':'❌ HAY FALLOS'} — pass:${pass} fail:${fail}`);
  } catch (e) { console.error('❌ ERROR:', e.message); fail++; }
  finally { await c.query('rollback').catch(()=>{}); await c.end(); console.log('(rollback — nada persistió)'); }
})();
