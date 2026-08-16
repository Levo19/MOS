CREATE OR REPLACE FUNCTION mos.costos_registrados_guia(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_out  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_guia is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'idProducto', z.pid, 'sku', z.sku, 'valor', z.valor, 'ts', z.ts,
           'bonificacion', z.bonif, 'percepcionPct', z.perc)), '[]'::jsonb)
    into v_out
    from (
      select distinct on (coalesce(nullif(btrim(h.id_producto),''), h.sku_base))
             nullif(btrim(h.id_producto),'') as pid,
             nullif(btrim(h.sku_base),'')    as sku,
             h.valor, h.ts,
             coalesce((h.meta->>'bonificacion')::boolean, false) as bonif,
             mos._numn(h.meta->>'percepcionPct') as perc
        from mos.historial_precio_costo h
       where h.id_guia = v_guia
         and upper(btrim(coalesce(h.tipo,''))) = 'COSTO'
       order by coalesce(nullif(btrim(h.id_producto),''), h.sku_base),
                coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts) desc,
                h.id desc   -- desempate: dos registros en el mismo instante → gana el último
    ) z;

  return jsonb_build_object('ok', true, 'data', coalesce(v_out, '[]'::jsonb));
end;
$function$
