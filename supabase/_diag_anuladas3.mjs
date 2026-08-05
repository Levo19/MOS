import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const F = ['crear_cpe_directo', 'crear_venta_directa', 'ventas_hoy_zona_auth', 'ventas_hoy_zona',
           'limpiar_ventas_huerfanas', 'emitir_cpe_fac', 'ventas_hoy_vendedor', 'tributario_cpe_mes'];
for (const f of F) {
  const r = (await c.query(`select n.nspname||'.'||p.proname nom, pg_get_functiondef(p.oid) d
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where p.proname=$1 and p.prokind='f' and n.nspname in ('me','mos') limit 1`, [f])).rows[0];
  if (!r) { console.log('?? no existe', f); continue; }
  fs.writeFileSync('_def_' + f + '.sql', r.d);
  console.log('\n=== ' + r.nom + '  (' + r.d.split('\n').length + ' líneas)');
  r.d.split('\n').forEach((l, i) => { if (/estado_envio/i.test(l)) console.log('   L' + (i + 1) + ': ' + l.trim().slice(0, 125)); });
}
await c.end();
