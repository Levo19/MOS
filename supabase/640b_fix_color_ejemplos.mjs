// 640b · fix regla "COLOR" (bolsas de compra caían en ESPECIAS/Ajíes) + re-seed reglas,
// reclasificación de afectados, herencia, espejo, y EJEMPLOS regenerados desde productos VIVOS.
import fs from 'fs';
import pkg from 'pg';
import { REGLAS, clasificar } from './_tax_flat.mjs';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
await c.query('begin');
// re-seed reglas con la nueva numeración
await c.query('truncate mos.taxonomia_reglas');
const filas = [];
REGLAS.forEach(([pat, cat, subs], i) => subs.forEach(([sp, sub], j) =>
  filas.push([(i + 1) * 100 + j, pat.replaceAll('\b', '\y'), sp ? sp.replaceAll('\b', '\y') : null, cat, sub])));
for (const f of filas)
  await c.query('insert into mos.taxonomia_reglas(orden,patron,patron2,categoria,subcategoria) values ($1,$2,$3,$4,$5)', f);
// reclasificar canónicos que cambian (en replica, luego herencia+espejo explícitos)
await c.query(`set local session_replication_role = replica`);
const canon = (await c.query(`select codigo_barra, descripcion, coalesce(descripcion_ia,'') dia, categoria_ia
  from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true) and descripcion_ia is not null`)).rows;
let recls = 0;
for (const p of canon) {
  const h = clasificar(p.descripcion, p.dia);
  if (!h) continue;
  const nuevo = { categoria: h.cat, subcategoria: h.sub };
  if (JSON.stringify(nuevo) !== JSON.stringify(p.categoria_ia)) {
    await c.query(`update mos.productos set categoria_ia=$2::jsonb where codigo_barra=$1`, [p.codigo_barra, JSON.stringify(nuevo)]);
    console.log('  recls:', p.descripcion, '→', h.cat + '/' + h.sub);
    recls++;
  }
}
await c.query(`update mos.productos d
   set categoria_ia = coalesce(c2.categoria_ia, d.categoria_ia)
  from mos.productos c2
 where d.tipo_producto::text='DERIVADO' and c2.tipo_producto::text='CANONICO' and c2.sku_base = d.codigo_producto_base`);
await c.query(`update mos.productos pr
   set categoria_ia = coalesce(l.categoria_ia, pr.categoria_ia)
  from (select distinct on (x.sku_base) x.sku_base, x.categoria_ia
          from mos.productos x where x.tipo_producto::text in ('CANONICO','DERIVADO')
         order by x.sku_base, (x.descripcion_ia is not null) desc, (x.codigo_barra !~* '^PRE[0-9]') desc, length(x.descripcion) desc) l
 where pr.tipo_producto::text='PRESENTACION' and l.sku_base = pr.sku_base`);
await c.query(`update mos.productos set id_categoria = categoria_ia->>'categoria'
 where categoria_ia is not null and id_categoria is distinct from (categoria_ia->>'categoria')`);
// EJEMPLOS desde productos VIVOS (2 por subcategoría, canónicos, no-auto)
const ej = await c.query(`
  with e as (
    select categoria_ia->>'categoria' cat, categoria_ia->>'subcategoria' sub,
           string_agg(descripcion, ' · ' order by descripcion) filter (where rn <= 2) ejemplos
      from (select descripcion, categoria_ia,
                   row_number() over (partition by categoria_ia->>'categoria', categoria_ia->>'subcategoria' order by length(descripcion)) rn
              from mos.productos
             where tipo_producto::text='CANONICO' and coalesce(estado,true) and categoria_ia is not null) t
     group by 1, 2)
  update mos.taxonomia_catalogo tc set ejemplos = coalesce(e.ejemplos, tc.ejemplos)
    from e where e.cat = tc.categoria and e.sub = tc.subcategoria`);
const chk = (await c.query(`select count(*) n from mos.productos
  where categoria_ia->>'subcategoria'='Ajíes y colorantes naturales' and descripcion ~* 'BOLSA DE COMPRA'`)).rows[0].n;
console.log(`reclasificados: ${recls} · ejemplos refrescados: ${ej.rowCount} · bolsas aún en Ajíes: ${chk}`);
if (Number(chk) > 0) { console.log('❌ ROLLBACK'); await c.query('rollback'); process.exit(1); }
await c.query('commit');
console.log('✅ 640b aplicado');
await c.end();
