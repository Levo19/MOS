// _envases_defs.mjs — saca la definición de las RPCs de catálogo relevantes.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const fns = process.argv.slice(2);
for (const fn of fns) {
  const r = await c.query(
    `select p.proname, pg_get_functiondef(p.oid) def
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'mos' and p.proname = $1`, [fn]);
  for (const row of r.rows) {
    fs.writeFileSync(`./_def_${row.proname}.sql`, row.def);
    console.log('OK', row.proname, '→ _def_' + row.proname + '.sql (' + row.def.length + ' chars)');
  }
  if (!r.rows.length) console.log('NO EXISTE:', fn);
}
await c.end();
