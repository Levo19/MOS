// Runner de la renormalizacion 1005-A (el dueño la ejecuta: node supabase/_run1005_renorm.cjs)
// tx + guardas dentro del DO block (aborta solo si algo cambiara wh.stock) + re-corre el detector.
const fs=require('fs'),pg=require('pg');
(async()=>{
  const c=new pg.Client({connectionString:fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(),ssl:{rejectUnauthorized:false},connectionTimeoutMillis:30000,query_timeout:180000});
  await c.connect();
  const sql=fs.readFileSync(__dirname+'/1005_kardex_renormalizar_y_resumen.sql','utf8');
  const doBlock=sql.slice(sql.indexOf('do $$'), sql.indexOf('-- B)'));
  try{ await c.query(doBlock); console.log('OK: libro renormalizado (guardas pasaron).'); }
  catch(e){ console.log('ABORTADO:', e.message.split('\n')[0]); await c.end(); process.exit(1); }
  try{ const r=await c.query('select mos.cron_reconciliar_stock() j'); console.log('detector re-corrido:', JSON.stringify(r.rows[0].j).slice(0,200)); }catch(e){ console.log('detector ERR:', e.message.split('\n')[0]); }
  const t=await c.query(`select ambito, tipo_error, count(*) n from mos.stock_diferencias where estado='ABIERTA' and tipo_error in (1,2,3) group by 1,2 order by 1,2`);
  console.log('sistemicos ABIERTOS tras renormalizar:'); console.table(t.rows);
  await c.end();
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
