// Repesca: los canónicos marcados "sin ficha web" QUE SÍ tienen EAN buscable (el pedido
// original exigía búsqueda web y a estos no les tocó por el cupo agotado de los agentes).
import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const rows = (await c.query(String.raw`
  select p.codigo_barra, p.descripcion, coalesce(nullif(btrim(p.marca),''),'') marca_actual,
         coalesce((select string_agg(e.codigo_barra, ', ') from mos.equivalencias e
                    where e.sku_base=p.sku_base and e.activo), '') equivalentes
    from mos.productos p
   where p.tipo_producto::text='CANONICO'
     and p.descripcion_ia like '%sin ficha web específica%'
     and (p.codigo_barra ~ '^\d{8,13}$'
          or exists(select 1 from mos.equivalencias e where e.sku_base=p.sku_base and e.activo and e.codigo_barra ~ '^\d{8,13}$'))
   order by p.descripcion`)).rows;
const TAM = 24;
const dir = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/_ia_repesca';
fs.mkdirSync(dir, { recursive: true });
let n = 0;
for (let i = 0; i < rows.length; i += TAM) { n++;
  fs.writeFileSync(`${dir}/rep_${String(n).padStart(2,'0')}.json`, JSON.stringify(rows.slice(i, i+TAM), null, 1)); }
console.log(`repesca: ${rows.length} productos · ${n} lotes de ${TAM}`);
await c.end();
