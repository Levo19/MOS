import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const r = await c.query(String.raw`
  update mos.productos pr
     set descripcion = regexp_replace(pr.descripcion, '\((\s*[0-9.,]+)\s*un\)', '(\1 kg)')
   where pr.tipo_producto::text = 'PRESENTACION'
     and pr.descripcion ~* '\(\s*[0-9.,]+\s*un\)'
     and exists (select 1 from mos.productos b
                  where coalesce(nullif(btrim(b.sku_base),''), b.id_producto) = nullif(btrim(pr.sku_base),'')
                    and b.tipo_producto::text <> 'PRESENTACION'
                    and coalesce(nullif(b.factor_conversion,0),1) = 1
                    and upper(coalesce(nullif(btrim(b.unidad_medida),''), b.unidad,'')) = 'KGM')
  returning pr.codigo_barra, pr.descripcion`);
console.table(r.rows);
console.log('renombradas:', r.rowCount);
await c.end();
