// _envases_gen_seed.mjs — genera 598_seed_envase_derivados.sql desde _envases_match.json
// (match verificado por el dueño en el HTML de revisión 2026-07-31).
import fs from 'fs';
const { match } = JSON.parse(fs.readFileSync('./_envases_match.json', 'utf8'));
const rows = match.filter(m => m.envase_sku);   // con sugerencia o SIN_ENVASE; null = queda pendiente
const esc = s => String(s).replace(/'/g, "''");
const values = rows.map(m => `('${esc(m.codigo_barra)}','${esc(m.envase_sku)}')`).join(',\n');
const sql = `-- 598_seed_envase_derivados.sql — [SEED envase_sku por derivado]
-- Generado de _envases_match.json (match tabla primigenia × catálogo, verificado por el dueño).
-- ${rows.length} derivados con envase (celofán por sku_base o 'SIN_ENVASE'); el resto queda null (pendiente).
-- Guard: solo pisa filas SIN envase ya asignado (no clobbrea ediciones posteriores del dueño).
update mos.productos t
   set envase_sku = v.env, updated_at = now()
  from (values
${values}
  ) as v(cb, env)
 where btrim(coalesce(t.codigo_barra,'')) = v.cb
   and coalesce(btrim(t.codigo_producto_base),'') <> ''
   and t.envase_sku is null;
`;
fs.writeFileSync('./598_seed_envase_derivados.sql', sql);
console.log('OK 598_seed_envase_derivados.sql ·', rows.length, 'filas');
