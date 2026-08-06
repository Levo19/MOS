// Genera los lotes de trabajo para los agentes IA: canónicos activos SIN descripcion_ia,
// filtrando la basura (medidas/envases tipo "0.5 METROS", insumos de envasado).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const rows = (await c.query(String.raw`
  select p.codigo_barra, p.descripcion, coalesce(nullif(btrim(p.marca),''),'') marca_actual,
         coalesce(string_agg(e.codigo_barra, ', '), '') equivalentes
    from mos.productos p
    left join mos.equivalencias e on e.sku_base = p.sku_base and e.activo
   where p.tipo_producto::text = 'CANONICO'
     and coalesce(p.estado, true) = true
     and p.descripcion_ia is null
     and coalesce(p.es_insumo, false) = false
     and length(btrim(p.descripcion)) >= 6
     and p.descripcion !~* '^[0-9 .,x*/-]+\s*(metros?|unidades?|mil(lar)?|cm|mm|gr?|kg|ml|lt|litros?)?\.?\s*$'
   group by p.codigo_barra, p.descripcion, p.marca
   order by p.descripcion`)).rows;
const TAM = 50;
const dir = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/_ia_lotes';
fs.mkdirSync(dir, { recursive: true });
let n = 0;
for (let i = 0; i < rows.length; i += TAM) {
  n++;
  fs.writeFileSync(`${dir}/lote_${String(n).padStart(2, '0')}.json`, JSON.stringify(rows.slice(i, i + TAM), null, 1));
}
console.log(`productos válidos: ${rows.length} · lotes de ${TAM}: ${n} · en ${dir}`);
await c.end();
