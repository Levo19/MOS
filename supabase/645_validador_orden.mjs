// 645 · sust_validar re-marcaba stale EN CADA corrida: jsonb_agg sin ORDER BY re-armaba la
// lista en otro orden → "is distinct from" verdadero aunque nada cambió → re-generaciones
// infinitas pagadas (medido: +49/+76 pendientes tras cada corrida :07/:37). Fix: ordinality.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const V3 = String.raw`
create or replace function mos.sust_validar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_n int;
begin
  set local session_replication_role = replica;
  with filtrados as (
    select h.codigo_barra cb,
           coalesce(jsonb_agg(e.val order by e.ord) filter (where exists (
             select 1 from mos.productos t
              where t.codigo_barra = e.val->>'cod' and coalesce(t.estado, true)
                and t.tipo_producto::text in ('CANONICO','DERIVADO')
                and t.categoria_ia->>'subcategoria' = e.val->>'sub')), '[]'::jsonb) nuevo
      from mos.productos h
      cross join lateral jsonb_array_elements(h.sustitutos_internos) with ordinality e(val, ord)
     where h.tipo_producto::text in ('CANONICO','DERIVADO')
       and h.sustitutos_internos is not null and jsonb_array_length(h.sustitutos_internos) > 0
     group by h.codigo_barra
  )
  update mos.productos h
     set sustitutos_internos = f.nuevo,
         sust_stale = true
    from filtrados f
   where h.codigo_barra = f.cb and h.sustitutos_internos is distinct from f.nuevo;
  get diagnostics v_n = row_count;
  update mos.productos pr
     set sustitutos_internos = l.sustitutos_internos
    from mos.productos l
   where l.tipo_producto::text in ('CANONICO','DERIVADO') and pr.tipo_producto::text = 'PRESENTACION'
     and pr.sku_base = l.sku_base and pr.sustitutos_internos is distinct from l.sustitutos_internos;
  return jsonb_build_object('ok', true, 'limpiados', v_n);
end $fn$;
revoke all on function mos.sust_validar(jsonb) from public, anon, authenticated;
grant execute on function mos.sust_validar(jsonb) to service_role;`;

await c.query('begin');
await c.query(V3);
// test de idempotencia REAL: dos corridas seguidas → la segunda debe limpiar 0
const r1 = (await c.query(`select mos.sust_validar('{}'::jsonb) r`)).rows[0].r;
const r2 = (await c.query(`select mos.sust_validar('{}'::jsonb) r`)).rows[0].r;
console.log('corrida1:', JSON.stringify(r1), '· corrida2:', JSON.stringify(r2));
if (Number(r2.limpiados) !== 0) { console.log('❌ NO idempotente — rollback'); await c.query('rollback'); process.exit(1); }
await c.query('rollback');
await c.query(V3);
console.log('✅ 645 aplicado — validador idempotente (2ª corrida limpia 0)');
// des-marcar los stale FALSOS que el bug dejó (listas completas re-marcadas sin motivo):
// stale=true con lista sana (≥1 entradas todas válidas) → volver a false
const fix = await c.query(String.raw`
  update mos.productos h set sust_stale = false
   where h.tipo_producto::text in ('CANONICO','DERIVADO') and h.sust_stale
     and h.sustitutos_internos is not null and jsonb_array_length(h.sustitutos_internos) >= 1
     and not exists (
       select 1 from jsonb_array_elements(h.sustitutos_internos) e
        where not exists (select 1 from mos.productos t
               where t.codigo_barra = e->>'cod' and coalesce(t.estado, true)
                 and t.tipo_producto::text in ('CANONICO','DERIVADO')
                 and t.categoria_ia->>'subcategoria' = e->>'sub'))`);
console.log('stale falsos des-marcados:', fix.rowCount);
await c.end();
