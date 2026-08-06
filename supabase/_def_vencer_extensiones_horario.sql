CREATE OR REPLACE FUNCTION mos.vencer_extensiones_horario()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_n int;
begin
  update mos.seguridad_alertas
     set estado = 'VENCIDA'
   where tipo = 'EXTENSION_HORARIO_PENDIENTE'
     and estado = 'PENDIENTE'
     and fecha < now() - interval '2 hours';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'vencidas', v_n);
end;
$function$
