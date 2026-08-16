CREATE OR REPLACE FUNCTION mos.cotejo_costos_guias(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_guias text[];
  v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(p->'idGuias') <> 'array' then
    return jsonb_build_object('ok',false,'error','Requiere idGuias[]');
  end if;

  select array_agg(btrim(x)) into v_guias
    from jsonb_array_elements_text(p->'idGuias') t(x)
   where btrim(coalesce(x,'')) <> '';

  if v_guias is null or array_length(v_guias,1) is null then
    return jsonb_build_object('ok',true,'data', '{}'::jsonb);
  end if;
  if array_length(v_guias,1) > 400 then
    return jsonb_build_object('ok',false,'error','Demasiadas guías (máx 400)');
  end if;

  select coalesce(jsonb_object_agg(g.id_guia, jsonb_build_object(
           'n',  g.n,
           'ts', g.ts,
           'p',  g.p
         )), '{}'::jsonb)
    into v_out
    from (
      select c.id_guia,
             count(*) as n,
             max(c.cts) as ts,
             count(*) filter (where exists (
               select 1 from mos.historial_precio_costo hp
                where upper(btrim(coalesce(hp.tipo,''))) = 'PRECIO'
                  and hp.ts >= c.cts
                  and ( (c.pid is not null and nullif(btrim(hp.id_producto),'') = c.pid)
                        or (c.sku is not null and nullif(btrim(hp.sku_base),'') = c.sku) )
             )) as p
        from (
          select z.id_guia, z.key,
                 -- [770] el reloj: solo eventos significativos (siempre hay ≥1: el primero)
                 max(z.reg) filter (where z.sig) as cts,
                 max(z.pid) as pid,
                 max(z.sku) as sku
            from (
              select h.id_guia,
                     coalesce(nullif(btrim(h.id_producto),''), h.sku_base) as key,
                     nullif(btrim(h.id_producto),'') as pid,
                     nullif(btrim(h.sku_base),'')    as sku,
                     coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts) as reg,
                     ( h.valor is distinct from h.valor_anterior
                       or coalesce((h.meta->>'bonificacion')::boolean, false)
                       or row_number() over (
                            partition by h.id_guia, coalesce(nullif(btrim(h.id_producto),''), h.sku_base)
                            order by h.id) = 1
                     ) as sig
                from mos.historial_precio_costo h
               where h.id_guia = any(v_guias)
                 and upper(btrim(coalesce(h.tipo,''))) = 'COSTO'
            ) z
           group by z.id_guia, z.key
        ) c
       group by c.id_guia
    ) g;

  return jsonb_build_object('ok', true, 'data', v_out);
end; $function$
