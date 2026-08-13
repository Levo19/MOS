-- 767 · Costos registrados por guía (13-ago-2026). Las líneas de una compra EN ZONA
-- (me.guias_detalle) NO tienen columna de monto: al reabrir el Paso 1 el formulario
-- decía "Falta costo" aunque el admin YA lo cotejó (caso AJO zona02: Javier cotejó
-- S/5.50 y el modal mostraba 0.00 — la Mesa decía 1/1 con razón). Esta RPC devuelve
-- el ÚLTIMO costo cotejado por producto de una guía para que el front re-hidrate.
create or replace function mos.costos_registrados_guia(p jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_out  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_guia is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'idProducto', z.pid, 'sku', z.sku, 'valor', z.valor, 'ts', z.ts)), '[]'::jsonb)
    into v_out
    from (
      select distinct on (coalesce(nullif(btrim(h.id_producto),''), h.sku_base))
             nullif(btrim(h.id_producto),'') as pid,
             nullif(btrim(h.sku_base),'')    as sku,
             h.valor, h.ts
        from mos.historial_precio_costo h
       where h.id_guia = v_guia
         and upper(btrim(coalesce(h.tipo,''))) = 'COSTO'
       order by coalesce(nullif(btrim(h.id_producto),''), h.sku_base), h.ts desc
    ) z;

  return jsonb_build_object('ok', true, 'data', coalesce(v_out, '[]'::jsonb));
end;
$function$;
