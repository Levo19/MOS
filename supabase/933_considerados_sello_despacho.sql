-- [933] wh.considerados_listar v2 — SELLO DE DESPACHO por zona + solo informativo.
-- Pedido del dueño: por cada zona que se debía, mostrar si YA se le despachó el producto (y cuándo) tras
-- el ingreso — así sabe si de verdad lo "consideraron". Enriquece cada zona con `despachadoTs` = la última
-- SALIDA a esa zona, de ese sku, DESPUÉS de crearse el considerado (no anulada). null = aún sin despachar.
-- (El trigger tg_considerado_ingreso ya cubre INGRESO_PROVEEDOR **e INGRESO_ENVASADO**, o sea también los
--  derivados que entran por envasado.) El check/✕ se dejan de usar en el front → los ACTIVO expiran solos a 7d.
create or replace function wh.considerados_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_items jsonb;
  v_lim   int := greatest(1, least(200, coalesce((p->>'limite')::int, 50)));
begin
  if exists (select 1 from wh.considerados where estado='ACTIVO' and creado < now() - interval '7 days') then
    update wh.considerados set estado='VENCIDO' where estado='ACTIVO' and creado < now() - interval '7 days';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', z.id, 'skuBase', z.sku_base, 'nombre', z.nombre,
           'cant', z.cant_ingresada, 'guiaTipo', z.guia_tipo, 'idGuia', z.id_guia,
           'creado', to_char(z.creado at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI'),
           'zonas', (
             select coalesce(jsonb_agg(jsonb_build_object(
                      'zona', zz->>'zona',
                      'bucket', zz->>'bucket',
                      'pend', (zz->>'pend')::numeric,
                      'despachadoTs', (
                        select to_char(max(coalesce(gd.created_at, g.fecha)) at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI')
                          from wh.guias g
                          join wh.guia_detalle gd on gd.id_guia = g.id_guia
                          left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
                          left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
                         where g.tipo like 'SALIDA%'
                           and coalesce(g.id_zona,'') = (zz->>'zona')
                           and coalesce(pr.sku_base, eq.sku_base) = z.sku_base
                           and coalesce(gd.created_at, g.fecha) >= z.creado
                           and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
                      )
                    ) order by (zz->>'bucket') desc), '[]'::jsonb)
               from jsonb_array_elements(coalesce(z.zonas,'[]'::jsonb)) zz
           )
         ) order by z.creado desc), '[]'::jsonb)
    into v_items
    from (select * from wh.considerados where estado='ACTIVO' order by creado desc limit v_lim) z;

  return jsonb_build_object('ok', true, 'items', v_items,
    'total', (select count(*) from wh.considerados where estado='ACTIVO'));
end $function$;
grant execute on function wh.considerados_listar(jsonb) to authenticated, anon, service_role;

select wh.considerados_listar('{}'::jsonb) -> 'items' -> 0 as muestra;
