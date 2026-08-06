// 644 · La reciprocidad de sust_guardar se PAUSA mientras existan líderes con
// sustitutos_internos NULL (backfill en curso): cada guardado marcaba hasta 3 stale y la
// cola crecía (1350→1426 medido). Terminado el backfill se reactiva sola — que es cuando
// importa (productos nuevos tipo Alpaso). Parche sobre la def VIVA (pg_get_functiondef).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='sust_guardar'`)).rows[0].d;
const ancla = `  update mos.productos t2
     set sust_stale = true`;
if (!def.includes(ancla) || /backfill en curso/.test(def)) { console.log('ya parchado o ancla ausente'); process.exit(1); }
const nuevo = def.replace(ancla, `  -- [644] reciprocidad EN PAUSA durante el backfill (mientras haya líderes vírgenes):
  -- evita que la cola crezca más rápido de lo que se procesa. Post-backfill se activa sola.
  if exists (select 1 from mos.productos z
              where z.tipo_producto::text in ('CANONICO','DERIVADO')
                and coalesce(z.estado, true) and coalesce(z.es_insumo, false) = false
                and z.descripcion_ia is not null and z.categoria_ia is not null
                and z.sustitutos_internos is null) then
    return jsonb_build_object('ok', true, 'internos', jsonb_array_length(v_int),
      'externos', jsonb_array_length(v_ext), 'presentaciones', v_n, 'reciprocos', 0);
  end if;
  update mos.productos t2
     set sust_stale = true`);
await c.query('begin');
await c.query(nuevo);
// prueba: guardar sobre un líder real NO debe marcar recíprocos mientras haya nulls
const h = (await c.query(`select p.codigo_barra, (select cd.codigo_barra from mos.productos cd
    where cd.tipo_producto::text='CANONICO' and coalesce(cd.estado,true)
      and cd.categoria_ia->>'categoria' = p.categoria_ia->>'categoria'
      and cd.sku_base <> p.sku_base and cd.sustitutos_internos is not null limit 1) cand
  from mos.productos p where p.tipo_producto::text='CANONICO' and p.sustitutos_internos is not null
    and p.categoria_ia is not null limit 1`)).rows[0];
const g = (await c.query(`select mos.sust_guardar($1::jsonb) r`, [JSON.stringify({ codigoBarra: h.codigo_barra, internos: [{ cod: h.cand, motivo: 't' }], externos: [] })])).rows[0].r;
if (!(g.ok === true && g.reciprocos === 0)) { console.log('❌ test:', JSON.stringify(g)); await c.query('rollback'); process.exit(1); }
await c.query('rollback');
await c.query(nuevo);
console.log('✅ 644 aplicado — reciprocidad pausada hasta acabar el backfill · test reciprocos=0 ok');
await c.end();
