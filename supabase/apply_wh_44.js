const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass','utf8').trim();
const c = new Client({ host:'aws-1-us-east-1.pooler.supabase.com', port:5432, user:'postgres.rzbzdeipbtqkzjqdchqk', password:PASS, database:'postgres', ssl:{rejectUnauthorized:false} });
(async()=>{ await c.connect();
  try { await c.query(fs.readFileSync(__dirname+'/44_wh_marcar_producto_nuevo_aprobado.sql','utf8'));
    const fn=await c.query(`select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh' and proname='marcar_producto_nuevo_aprobado'`);
    const fl=await c.query(`select valor from mos.config where clave='WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO'`);
    console.log('creada:',fn.rowCount===1,'| flag:',fl.rows[0].valor, fn.rowCount===1&&fl.rows[0].valor==='0'?'✅ INERTE':'❌');
  } catch(e){ console.error('ERROR:',e.message); process.exitCode=1; } finally { await c.end(); }
})();
