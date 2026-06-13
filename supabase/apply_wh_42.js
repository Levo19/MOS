const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host:'aws-1-us-east-1.pooler.supabase.com', port:5432, user:'postgres.rzbzdeipbtqkzjqdchqk', password:PASS, database:'postgres', ssl:{rejectUnauthorized:false} });
(async()=>{ await c.connect();
  try { await c.query(fs.readFileSync(__dirname+'/42_wh_guia_detalle_cols.sql','utf8'));
    const cols = await c.query(`select column_name from information_schema.columns where table_schema='wh' and table_name='guia_detalle' and column_name in ('id_detalle','fecha_vencimiento') order by 1`);
    console.log('columnas agregadas:', cols.rows.map(r=>r.column_name).join(', '));
    console.log(cols.rowCount===2 ? '✅ ambas columnas presentes' : '❌ falta alguna');
  } catch(e){ console.error('ERROR:', e.message); process.exitCode=1; }
  finally { await c.end(); }
})();
