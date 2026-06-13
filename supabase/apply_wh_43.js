const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host:'aws-1-us-east-1.pooler.supabase.com', port:5432, user:'postgres.rzbzdeipbtqkzjqdchqk', password:PASS, database:'postgres', ssl:{rejectUnauthorized:false} });
(async()=>{ await c.connect();
  try { await c.query(fs.readFileSync(__dirname+'/43_wh_agregar_detalle_guia.sql','utf8'));
    const fn = await c.query(`select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh' and proname='agregar_detalle_guia'`);
    const flag = await c.query(`select valor from mos.config where clave='WH_AGREGAR_DETALLE_GUIA_DIRECTO'`);
    console.log('RPC creada:', fn.rowCount===1, '| flag:', flag.rows[0].valor);
    console.log(fn.rowCount===1 && flag.rows[0].valor==='0' ? '✅ aplicada INERTE' : '❌');
  } catch(e){ console.error('ERROR:', e.message); process.exitCode=1; }
  finally { await c.end(); }
})();
