
create or replace function mos.ia_desc_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object(
             'codigo_barra', pr.codigo_barra,
             'descripcion',  pr.descripcion,
             'marca_actual', coalesce(nullif(btrim(pr.marca),''),''),
             'equivalentes', coalesce((select string_agg(e.codigo_barra, ', ')
                                         from mos.equivalencias e
                                        where e.sku_base = pr.sku_base and e.activo), '')
           ) as x
      from mos.productos pr
     where pr.tipo_producto::text = 'CANONICO'
       and coalesce(pr.estado, true) = true
       and pr.descripcion_ia is null
       and coalesce(pr.es_insumo, false) = false
       and length(btrim(pr.descripcion)) >= 6
       and pr.descripcion !~* '^[0-9 .,x*/-]+\s*(metros?|unidades?|mil(lar)?|cm|mm|gr?|kg|ml|lt|litros?)?\.?\s*$'
       and coalesce(pr.fecha_creacion, pr.created_at) > now() - interval '7 days'   -- solo lo NUEVO (el backlog es de los agentes)
     order by coalesce(pr.fecha_creacion, pr.created_at) desc
     limit least(greatest(coalesce((p->>'max')::int, 2), 1), 5)
  ) t;
$fn$;
revoke all on function mos.ia_desc_pendientes(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_desc_pendientes(jsonb) to service_role;


create or replace function mos.ia_guardar_descripcion(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod text := btrim(coalesce(p->>'codigoBarra',''));
  v_txt text := coalesce(p->>'texto','');
  v_marca text := btrim(coalesce(p->>'marca',''));
  v_n int;
begin
  if v_cod = '' then return jsonb_build_object('ok',false,'error','codigoBarra requerido'); end if;
  -- guard de formato: las 6 líneas (🏷 … ✅) o no se guarda
  if length(v_txt) < 60 or position('🏷' in v_txt) = 0 or position('✅' in v_txt) = 0 then
    return jsonb_build_object('ok',false,'error','FORMATO: faltan las líneas 🏷…✅');
  end if;
  -- sin bump de catálogo: las cajas no re-descargan por una descripción
  set local session_replication_role = replica;
  update mos.productos
     set descripcion_ia = v_txt,
         marca = case when nullif(btrim(coalesce(marca,'')),'') is null and v_marca <> ''
                      then v_marca else marca end
   where codigo_barra = v_cod and tipo_producto::text = 'CANONICO';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n = 1, 'actualizados', v_n);
end; $fn$;
revoke all on function mos.ia_guardar_descripcion(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_guardar_descripcion(jsonb) to service_role;