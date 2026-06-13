// Aplica 30_wh_crear_ajuste.sql al proyecto MOS, atómico + verificado. RPC INERTE (flag '0') → seguro.
const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host: 'aws-1-us-east-1.pooler.supabase.com', port: 5432, user: 'postgres.rzbzdeipbtqkzjqdchqk', password: PASS, database: 'postgres', ssl: { rejectUnauthorized: false } });
const sql = fs.readFileSync(__dirname + '/30_wh_crear_ajuste.sql', 'utf8');
(async () => {
  await c.connect();
  try {
    await c.query('begin');
    await c.query(sql);
    const fn = await c.query(`select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh' and p.proname='crear_ajuste'`);
    const flag = await c.query(`select valor from mos.config where clave='WH_CREAR_AJUSTE_DIRECTO' limit 1`);
    const inert = !flag.rows.length || flag.rows[0].valor !== '1';
    console.log('wh.crear_ajuste existe:', fn.rowCount === 1, '| flag:', flag.rows[0] ? flag.rows[0].valor : '(seed)', '| inerte:', inert);
    if (fn.rowCount === 1 && inert) { await c.query('commit'); console.log('\n✅ COMMIT — RPC aplicada, INERTE.'); }
    else { await c.query('rollback'); console.log('\n❌ ROLLBACK'); process.exitCode = 1; }
  } catch (e) { await c.query('rollback').catch(()=>{}); console.error('❌ ERROR, rollback:', e.message); process.exitCode = 1; }
  finally { await c.end(); }
})();
