CREATE OR REPLACE FUNCTION mos.limpiar_ventas_huerfanas(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  update me.ventas set estado_envio = 'HUERFANA_LIMPIADA'
   where upper(coalesce(tipo_doc,'')) in ('BOLETA','FACTURA')
     and correlativo ilike 'undefined%'
     and coalesce(estado_envio,'') <> 'HUERFANA_LIMPIADA';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('limpiadas', v_n));
end; $function$
