const { Client } = require('pg'); const fs=require('fs');
const PASS=fs.readFileSync(__dirname+'/.pgpass','utf8').trim();
const c=new Client({host:'aws-1-us-east-1.pooler.supabase.com',port:5432,user:'postgres.rzbzdeipbtqkzjqdchqk',password:PASS,database:'postgres',ssl:{rejectUnauthorized:false}});
const q=(s,a)=>c.query(s,a);
let pass=0,fail=0; const chk=(n,cond,ex)=>{cond?(pass++,console.log('  OK',n)):(fail++,console.log('  FAIL',n,JSON.stringify(ex)||''));};
(async()=>{ await c.connect();
  try { await q(fs.readFileSync(__dirname+'/45_wh_rls_lecturas.sql','utf8'));
    const fn=await q(`select proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh' and proname in ('stock_enriquecido_rls','rotacion_semanal_rls') order by 1`);
    console.log('wrappers creados:', fn.rows.map(r=>r.proname).join(', '));
    await q('begin');
    // sin claim (service_role/GAS)
    let r=(await q(`select wh.stock_enriquecido_rls(false) r`)).rows[0].r;
    chk('sin claim (GAS): devuelve data', r.ok===true && Array.isArray(r.data), {ok:r.ok, n:(r.data||[]).length});
    // claim warehouseMos
    await q(`select set_config('request.jwt.claims','{"app":"warehouseMos"}',true)`);
    r=(await q(`select wh.stock_enriquecido_rls(true) r`)).rows[0].r;
    chk('claim warehouseMos: devuelve data (alertas)', r.ok===true && Array.isArray(r.data), {ok:r.ok});
    r=(await q(`select wh.rotacion_semanal_rls(8,null) r`)).rows[0].r;
    chk('rotacion warehouseMos: ok', r.ok===true, {ok:r.ok});
    // claim ajeno
    await q(`select set_config('request.jwt.claims','{"app":"mosExpress"}',true)`);
    r=(await q(`select wh.stock_enriquecido_rls(false) r`)).rows[0].r;
    chk('claim mosExpress: APP_NO_AUTORIZADA', r.ok===false && r.error==='APP_NO_AUTORIZADA', r);
    r=(await q(`select wh.rotacion_semanal_rls(8,null) r`)).rows[0].r;
    chk('rotacion mosExpress: APP_NO_AUTORIZADA', r.ok===false && r.error==='APP_NO_AUTORIZADA', r);
    await q('rollback');
    console.log(`\n${fail===0?'OK TODOS':'HAY FALLOS'} pass:${pass} fail:${fail}`);
  } catch(e){ console.error('ERR',e.message); fail++; } finally { await c.end(); }
})();
