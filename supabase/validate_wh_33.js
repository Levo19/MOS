const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host: 'aws-1-us-east-1.pooler.supabase.com', port: 5432, user: 'postgres.rzbzdeipbtqkzjqdchqk', password: PASS, database: 'postgres', ssl: { rejectUnauthorized: false } });
const callC = async (p) => (await c.query(`select wh.crear_preingreso($1::jsonb) r`, [JSON.stringify(p)])).rows[0].r;
const callU = async (p) => (await c.query(`select wh.actualizar_preingreso($1::jsonb) r`, [JSON.stringify(p)])).rows[0].r;
let pass = 0, fail = 0;
const chk = (n, cond, extra) => { if (cond) { pass++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra || ''); } };
(async () => {
  await c.connect();
  try {
    await c.query('begin');
    await c.query(`update mos.config set valor='1' where clave in ('WH_CREAR_PREINGRESO_DIRECTO','WH_ACTUALIZAR_PREINGRESO_DIRECTO')`);

    await callC({ id_preingreso:'PIU1', id_proveedor:'PROV1', usuario:'val', monto:'100', comentario:'orig' });
    let r = await callU({ id_preingreso:'PIU1', monto:'250.5', comentario:'editado' });
    chk('update ok', r.ok===true, r);
    let p = (await c.query(`select * from wh.preingresos where id_preingreso='PIU1'`)).rows[0];
    chk('monto+comentario actualizados', Number(p.monto)===250.5 && p.comentario==='editado', p);
    chk('id_proveedor NO tocado (no vino)', p.id_proveedor==='PROV1', p);
    chk('estado intacto PENDIENTE', p.estado==='PENDIENTE', p);

    // patch parcial: solo cargadores
    r = await callU({ id_preingreso:'PIU1', cargadores:'[{"id":"X"}]' });
    p = (await c.query(`select * from wh.preingresos where id_preingreso='PIU1'`)).rows[0];
    chk('solo cargadores cambia, monto se mantiene', p.cargadores==='[{"id":"X"}]' && Number(p.monto)===250.5, p);

    // snapshot_aviso jsonb
    r = await callU({ id_preingreso:'PIU1', snapshot_aviso:{ tagComp:'si', monto:250.5 } });
    p = (await c.query(`select snapshot_aviso from wh.preingresos where id_preingreso='PIU1'`)).rows[0];
    chk('snapshot_aviso guardado como jsonb', p.snapshot_aviso && p.snapshot_aviso.tagComp==='si', p.snapshot_aviso);

    r = await callU({ id_preingreso:'NOEXISTE', monto:'1' });   chk('preingreso inexistente rechazado', r.ok===false && r.error==='PREINGRESO_NO_ENCONTRADO', r);
    r = await callU({ monto:'1' });                              chk('falta id rechazado', r.ok===false && r.error==='FALTAN_PARAMS', r);

    console.log(`\n${fail===0?'✅ TODOS':'❌ HAY FALLOS'} — pass:${pass} fail:${fail}`);
  } catch (e) { console.error('❌ ERROR:', e.message); fail++; }
  finally { await c.query('rollback').catch(()=>{}); await c.end(); console.log('(rollback — nada persistió)'); }
})();
