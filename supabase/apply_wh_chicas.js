const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host:'aws-1-us-east-1.pooler.supabase.com', port:5432, user:'postgres.rzbzdeipbtqkzjqdchqk', password:PASS, database:'postgres', ssl:{rejectUnauthorized:false} });
(async()=>{ await c.connect();
  try {
    for (const f of ['39_wh_marcar_preingreso_procesado.sql','40_wh_crear_auditoria.sql','41_wh_get_o_crear_guia_dia.sql']) {
      await c.query(fs.readFileSync(__dirname+'/'+f,'utf8'));
    }
    const fns = await c.query(`select proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh' and proname in ('marcar_preingreso_procesado','crear_auditoria','get_o_crear_guia_dia') order by 1`);
    const flags = await c.query(`select count(*)::int n from mos.config where clave in ('WH_MARCAR_PREINGRESO_PROCESADO_DIRECTO','WH_CREAR_AUDITORIA_DIRECTO','WH_GET_O_CREAR_GUIA_DIA_DIRECTO') and valor='1'`);
    console.log('RPCs creadas:', fns.rows.map(r=>r.proname).join(', '));
    console.log('flags en 1 (deben ser 0):', flags.rows[0].n);
    if (fns.rowCount===3 && flags.rows[0].n===0) console.log('✅ 3 RPCs aplicadas, INERTES.');
    else { console.log('❌ revisar'); process.exitCode=1; }
  } catch(e){ console.error('ERROR:', e.message); process.exitCode=1; }
  finally { await c.end(); }
})();
