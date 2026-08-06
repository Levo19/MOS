import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('════ CON FICHA WEB (búsqueda real) ════');
for (const r of (await c.query(`select descripcion, descripcion_ia from mos.productos
  where descripcion_ia is not null and descripcion_ia not like '%sin ficha web%'
    and descripcion ilike any(array['%alacena tari%','%costa%soda%']) limit 2`)).rows) {
  console.log('\n▶ ' + r.descripcion + '\n' + r.descripcion_ia);
}
console.log('\n════ SIN FICHA WEB (conocimiento general — los "faltantes") ════');
for (const r of (await c.query(`select descripcion, descripcion_ia from mos.productos
  where descripcion_ia like '%sin ficha web%'
    and (descripcion ilike '%nescafe%' or descripcion ilike '%maggi%') limit 2`)).rows) {
  console.log('\n▶ ' + r.descripcion + '\n' + r.descripcion_ia);
}
await c.end();
