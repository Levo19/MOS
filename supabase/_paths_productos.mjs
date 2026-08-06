// Enumera TODAS las funciones de la BD que insertan o editan mos.productos, para
// demostrar que la herencia automática (triggers a nivel de TABLA) cubre cada camino.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const fns = (await c.query(String.raw`
select n.nspname||'.'||p.proname fn, pg_get_functiondef(p.oid) def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('mos','wh','me','ruta','public','fac') and p.prokind = 'f'
   and pg_get_functiondef(p.oid) ~* '(insert into|update)\s+mos\.productos'`)).rows;
for (const f of fns) {
  const ins = /insert into\s+mos\.productos/i.test(f.def);
  const upNombre = /update\s+mos\.productos[\s\S]{0,1500}?\bdescripcion\s*=/i.test(f.def);
  const upCodigo = /update\s+mos\.productos[\s\S]{0,1500}?\bcodigo_barra\s*=/i.test(f.def);
  const replica = /session_replication_role/i.test(f.def);
  if (ins || upNombre || upCodigo)
    console.log(`· ${f.fn}  ${ins ? 'INSERTA' : ''}${upNombre ? ' edita-NOMBRE' : ''}${upCodigo ? ' edita-CÓDIGO' : ''}${replica ? ' ⚠REPLICA(sin triggers)' : ''}`);
}
await c.end();
