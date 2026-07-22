-- ════════════════════════════════════════════════════════════════════════════
-- 545 · ➕ De sus guías con ESTADO (ya agregado) + bulto a nivel PRODUCTO
-- ════════════════════════════════════════════════════════════════════════════
-- Feedback del dueño (2026-07-22):
--  1) "es absurdo ver que puedo agregar el mismo producto" → los candidatos de
--     guías ya NO se ocultan si están en el catálogo: se devuelven TODOS con
--     flag `yaAgregado` y el front pinta "✓ Ya está agregado" (deshabilitado).
--     (La exclusión anterior además fallaba con presentaciones del mismo padre.)
--  2) "lo que estoy editando es el PRODUCTO, no importa quién lo trae" → el
--     bulto (unidades_por_bulto) se propaga a TODOS los proveedores del mismo
--     sku_base vía mos.pp_set_bulto_global.

create or replace function mos.prov_guia_candidatos(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prov text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_data jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_prov is null then return jsonb_build_object('ok', false, 'error', 'idProveedor requerido'); end if;

  with det as (
    select gd.cod_producto as cod, g.fecha, gd.precio_unitario as precio, g.id_guia
    from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
    where g.id_proveedor = v_prov and g.tipo = 'INGRESO_PROVEEDOR'
  ),
  res as (
    select coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
           max(pr.descripcion) as descripcion,
           max(d.cod)  as cb,
           count(distinct d.id_guia) as veces,
           max(d.fecha) as ult,
           (array_agg(d.precio order by d.fecha desc))[1] as ult_costo
    from det d
    join mos.productos pr on pr.codigo_barra = d.cod or pr.id_producto = d.cod
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'skuBase', r.sku, 'descripcion', r.descripcion, 'codigoBarra', r.cb,
           'veces', r.veces,
           'ultFecha', to_char(r.ult at time zone 'America/Lima','DD Mon'),
           'ultCosto', case when coalesce(r.ult_costo,0) > 0 then round(r.ult_costo::numeric,2) else null end,
           'pocaEvidencia', (r.veces < 2),
           'yaAgregado', exists (select 1 from mos.proveedores_productos pp
                                  where pp.id_proveedor = v_prov and pp.sku_base = r.sku)
         ) order by exists (select 1 from mos.proveedores_productos pp
                             where pp.id_proveedor = v_prov and pp.sku_base = r.sku) asc,
                    r.ult desc), '[]'::jsonb)
    into v_data
  from res r
  limit 60;

  return jsonb_build_object('ok', true, 'data', coalesce(v_data,'[]'::jsonb));
end;
$fn$;

-- Bulto a NIVEL PRODUCTO: propaga a todos los proveedores del mismo sku_base.
create or replace function mos.pp_set_bulto_global(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sku text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_upb numeric := nullif(btrim(coalesce(p->>'unidadesPorBulto','')), '')::numeric;
  v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_sku is null then return jsonb_build_object('ok', false, 'error', 'skuBase requerido'); end if;
  if v_upb is null or v_upb < 1 then return jsonb_build_object('ok', false, 'error', 'unidadesPorBulto inválido'); end if;
  update mos.proveedores_productos
     set unidades_por_bulto = v_upb, ultima_actualizacion = now()
   where sku_base = v_sku;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('filas', v_n));
end;
$fn$;

revoke all on function mos.prov_guia_candidatos(jsonb), mos.pp_set_bulto_global(jsonb) from public;
grant execute on function mos.prov_guia_candidatos(jsonb), mos.pp_set_bulto_global(jsonb) to authenticated, service_role;
