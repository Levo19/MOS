// 663 · Decisión dueño: PROMOCIONES conectadas al POS — catalogo_pos_rls devolvía '[]' hardcodeado.
//   Ahora manda las activas con las claves EXACTAS que ME espera (_promoVigente + cards):
//   SKU_Base, Tipo_Promo, Cant_Min, Valor_Promo, Valor_Modo, Items_JSON, Vigencia_Desde/Hasta, Activa, ID_Promo.
//   La vigencia por fechas la filtra el cliente (_promoVigente); aquí solo activa=true.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const def = async () => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='catalogo_pos_rls'`)).rows[0].d;
let d = await def();
if (d.includes('[663]')) { console.log('ya aplicado'); await c.end(); process.exit(0); }
const a = `'PROMOCIONES', '[]'::jsonb`;
const i = d.indexOf(a);
if (i < 0) throw new Error('ancla PROMOCIONES no encontrada');
if (d.indexOf(a, i + 1) >= 0) throw new Error('ancla dup');
d = d.slice(0, i) + `'PROMOCIONES', /* [663] promos reales al POS (decisión dueño) */ coalesce((
        select jsonb_agg(jsonb_build_object(
          'ID_Promo', pm.id_promo,
          'SKU_Base', pm.sku_base,
          'Tipo_Promo', pm.tipo_promo,
          'Cant_Min', pm.cant_min,
          'Valor_Promo', pm.valor_promo,
          'Valor_Modo', pm.valor_modo,
          'Descripcion', pm.descripcion,
          'Items_JSON', pm.items_json,
          'Vigencia_Desde', pm.vigencia_desde,
          'Vigencia_Hasta', pm.vigencia_hasta,
          'Activa', coalesce(pm.activa, true)
        ) order by pm.id_promo)
        from mos.promociones pm
        where coalesce(pm.activa, true)
      ), '[]'::jsonb)` + d.slice(i + a.length);

await c.query('begin');
await c.query(d);
// sembrar una promo de prueba en la MISMA tx para validar shape aunque no haya activas
const { rows: [{ sku }] } = await c.query(`select sku_base as sku from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true) limit 1`);
await c.query(`insert into mos.promociones (id_promo, sku_base, tipo_promo, cant_min, valor_promo, activa) values ('PRTEST663', $1, 'PORCENTAJE', 3, 10, true)`, [sku]);
const { rows: [{ r }] } = await c.query(`select mos.catalogo_pos_rls() r`);
const promos = r.data.PROMOCIONES || [];
const mia = promos.find(p => p.ID_Promo === 'PRTEST663');
console.log('promos en payload:', promos.length, '· la de prueba:', JSON.stringify(mia).slice(0, 200));
const claves = mia && ['SKU_Base','Tipo_Promo','Cant_Min','Valor_Promo','Activa'].every(k => k in mia);
// las demás secciones intactas
const { rows: [{ r: r0 }] } = await c.query(`select mos.catalogo_pos_rls() r`);
const okSecciones = ['PRODUCTO_BASE','PRESENTACIONES','STOCK_ZONAS','EQUIVALENCIAS'].every(s => JSON.stringify(r.data[s]).length === JSON.stringify(r0.data[s]).length);
console.log('claves ME ok:', !!claves, '· secciones intactas:', okSecciones);
await c.query('rollback');
if (!claves || !okSecciones) { console.log('NO SE APLICA'); process.exit(1); }
await c.query(d);
// bump manual para que todos los ME re-jalen el catálogo YA
await c.query(`update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1`);
const { rows: [{ n }] } = await c.query(`select count(*)::int n from mos.promociones where coalesce(activa,true)`);
console.log(`✅ 663 APLICADO · promos activas viajando al POS ahora: ${n} · bump enviado (los ME refrescan solos)`);
await c.end();
