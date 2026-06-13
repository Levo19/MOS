// Aplica 37_wh_stock_integridad.sql (consolida duplicados + indice unico), atómico + verificado.
const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host: 'aws-1-us-east-1.pooler.supabase.com', port: 5432, user: 'postgres.rzbzdeipbtqkzjqdchqk', password: PASS, database: 'postgres', ssl: { rejectUnauthorized: false } });
const sql = fs.readFileSync(__dirname + '/37_wh_stock_integridad.sql', 'utf8');
(async () => {
  await c.connect();
  try {
    const dupAntes = await c.query(`select count(*)::int n from (select cod_producto from wh.stock group by cod_producto having count(*)>1) x`);
    await c.query('begin'); await c.query(sql);
    const dupDespues = await c.query(`select count(*)::int n from (select cod_producto from wh.stock group by cod_producto having count(*)>1) x`);
    const idx = await c.query(`select 1 from pg_indexes where indexname='ux_wh_stock_cod'`);
    const total = await c.query(`select count(*)::int n from wh.stock`);
    console.log('grupos dup antes:', dupAntes.rows[0].n, '| despues:', dupDespues.rows[0].n, '| indice unico:', idx.rowCount===1, '| total filas:', total.rows[0].n);
    if (dupDespues.rows[0].n === 0 && idx.rowCount === 1) { await c.query('commit'); console.log('\n✅ COMMIT — 1 fila por producto + índice único.'); }
    else { await c.query('rollback'); console.log('\n❌ ROLLBACK'); process.exitCode = 1; }
  } catch (e) { await c.query('rollback').catch(()=>{}); console.error('❌ ERROR, rollback:', e.message); process.exitCode = 1; }
  finally { await c.end(); }
})();
