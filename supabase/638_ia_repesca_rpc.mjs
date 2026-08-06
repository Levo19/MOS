// 638 · RPC para la REPESCA vía Edge: lista los canónicos marcados "sin ficha web" QUE
// tienen EAN buscable (el pedido original exigía búsqueda web; el cupo local se agotó,
// la Edge busca por la API directa sin ese límite).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
await c.query(String.raw`
create or replace function mos.ia_repesca_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object(
             'codigo_barra', pr.codigo_barra, 'descripcion', pr.descripcion,
             'marca_actual', coalesce(nullif(btrim(pr.marca),''),''),
             'equivalentes', coalesce((select string_agg(e.codigo_barra, ', ')
                                         from mos.equivalencias e
                                        where e.sku_base = pr.sku_base and e.activo), '')) as x
      from mos.productos pr
     where pr.tipo_producto::text = 'CANONICO'
       and pr.descripcion_ia like '%sin ficha web específica%'
       and (pr.codigo_barra ~ '^\d{8,13}$'
            or exists(select 1 from mos.equivalencias e
                       where e.sku_base = pr.sku_base and e.activo and e.codigo_barra ~ '^\d{8,13}$'))
     order by pr.descripcion
     limit least(greatest(coalesce((p->>'max')::int, 3), 1), 6)
  ) t;
$fn$;
revoke all on function mos.ia_repesca_pendientes(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_repesca_pendientes(jsonb) to service_role;`);
const n = (await c.query(`select jsonb_array_length(mos.ia_repesca_pendientes('{"max":6}'::jsonb)) n`)).rows[0].n;
console.log('✅ RPC repesca lista · muestra de', n, 'pendientes');
fs.writeFileSync('638_ia_repesca_rpc.sql', '-- ver 638_ia_repesca_rpc.mjs');
await c.end();
