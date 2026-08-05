import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
await c.query(`grant execute on function mos.catalogo_version(jsonb) to anon`);
const def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname='catalogo_toggle_mosgo'`)).rows[0].d;
console.log('OFF sin cascada aplicado:', def.includes('SOLO lo saca del canal MosGo') ? '✅' : '❌');
fs.writeFileSync('632_go_off_sin_cascada.sql', def + '\n\ngrant execute on function mos.catalogo_version(jsonb) to anon;');
// prueba tx del comportamiento
await c.query('begin');
const master = (await c.query(`select nombre from mos.personal where upper(rol)='MASTER' limit 1`)).rows[0].nombre;
await c.query(`update mos.productos set canal_mayoreo=true, estado=true where codigo_barra='WHNAXMTO250GR'`);
const off = (await c.query(`select mos.catalogo_toggle_mosgo($1::jsonb) r`,[JSON.stringify({codigoBarra:'WHNAXMTO250GR',on:false,usuario:master})])).rows[0].r;
console.log('apagar GO deja el producto vivo en ME:', off.canalMayoreo===false && off.estado===true ? '✅' : '❌ '+JSON.stringify(off));
await c.query('rollback');
await c.end();
