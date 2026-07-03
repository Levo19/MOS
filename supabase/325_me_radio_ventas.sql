-- 325_me_radio_ventas.sql
-- [Migración Sheet→Supabase · Etapa 2/3] Radio TV (MosExpress).
-- Mueve la ÚNICA lectura de la Hoja VENTAS del camino del radio: el GAS
-- `topProductosHoy` leía VENTAS_CABECERA + VENTAS_DETALLE; ahora esta RPC lo
-- computa 100% sobre la sombra Supabase (me.ventas + me.ventas_detalle).
--
-- Devuelve EXACTAMENTE la forma que consumía radioProductos()/topProductosHoy():
--   { status:'ok', fecha:'YYYY-MM-DD', es_fallback_7d:bool,
--     productos:[{sku,nombre,vendidos}]  (top 20 por cantidad, hoy o 7d si hoy vacío),
--     skus_de_la_tienda:[sku...]        (vendidos en 30d; "alguna vez" si 30d vacío),
--     rango_filtro:'30d'|'alguna_vez' }
--
-- Reglas (espejo del GAS):
--   · Excluye ventas ANULADO y HUERFANA_LIMPIADA (esta última es estado sólo-sombra
--     de huérfanas depuradas; no son ventas reales).
--   · Día de NEGOCIO en TZ America/Lima (espeja Session.getScriptTimeZone del GAS).
--   · Sólo líneas con sku no vacío y cantidad > 0.
-- Read-only, SECURITY DEFINER, STABLE. Cero-GAS, sin fallback a la Hoja.

create or replace function me.radio_ventas()
returns jsonb
language plpgsql
security definer
set search_path = me, public
stable
as $$
declare
  v_hoy   date := (now() at time zone 'America/Lima')::date;
  v_prod  jsonb;
  v_skus  jsonb;
  v_rango text;
  v_fb    boolean;
begin
  -- SKUs de la tienda: vendidos en 30d; fallback "alguna vez" si 30d vacío.
  select coalesce(jsonb_agg(sku), '[]'::jsonb) into v_skus
  from (
    select distinct d.sku
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
    where v.fecha is not null
      and coalesce(v.estado_envio,'COMPLETADO') not in ('ANULADO','HUERFANA_LIMPIADA')
      and d.sku is not null and btrim(d.sku) <> '' and coalesce(d.cantidad,0) > 0
      and (v.fecha at time zone 'America/Lima')::date >= v_hoy - 29
  ) x;
  if v_skus = '[]'::jsonb then
    select coalesce(jsonb_agg(sku), '[]'::jsonb) into v_skus
    from (
      select distinct d.sku
      from me.ventas v
      join me.ventas_detalle d on d.id_venta = v.id_venta
      where v.fecha is not null
        and coalesce(v.estado_envio,'COMPLETADO') not in ('ANULADO','HUERFANA_LIMPIADA')
        and d.sku is not null and btrim(d.sku) <> '' and coalesce(d.cantidad,0) > 0
    ) x;
    v_rango := 'alguna_vez';
  else
    v_rango := '30d';
  end if;

  -- ¿Hay ventas HOY? Si no, el top cae a 7d (es_fallback_7d=true).
  select not exists (
    select 1
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
    where v.fecha is not null
      and coalesce(v.estado_envio,'COMPLETADO') not in ('ANULADO','HUERFANA_LIMPIADA')
      and d.sku is not null and btrim(d.sku) <> '' and coalesce(d.cantidad,0) > 0
      and (v.fecha at time zone 'America/Lima')::date = v_hoy
  ) into v_fb;

  -- Top 20 productos por cantidad vendida (hoy, o últimos 7 días si hoy vacío).
  select coalesce(jsonb_agg(to_jsonb(t) order by t.vendidos desc), '[]'::jsonb) into v_prod
  from (
    select d.sku,
           max(d.nombre)        as nombre,
           sum(d.cantidad)::float8 as vendidos
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
    where v.fecha is not null
      and coalesce(v.estado_envio,'COMPLETADO') not in ('ANULADO','HUERFANA_LIMPIADA')
      and d.sku is not null and btrim(d.sku) <> '' and coalesce(d.cantidad,0) > 0
      and (v.fecha at time zone 'America/Lima')::date >= case when v_fb then v_hoy - 6 else v_hoy end
      and (v.fecha at time zone 'America/Lima')::date <= v_hoy
    group by d.sku
    order by vendidos desc
    limit 20
  ) t;

  return jsonb_build_object(
    'status',            'ok',
    'fecha',             to_char(v_hoy,'YYYY-MM-DD'),
    'es_fallback_7d',    v_fb,
    'productos',         v_prod,
    'skus_de_la_tienda', v_skus,
    'rango_filtro',      v_rango
  );
end;
$$;

grant execute on function me.radio_ventas() to service_role;
