CREATE OR REPLACE FUNCTION wh.vencer_listas_sombra()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_disp int := 0; v_uso int := 0;
begin
  update wh.listas_sombra
     set estado='ANULADA', fecha_completada=now(),
         nota = coalesce(nota,'') || ' [vencida: 24h sin despachar]'
   where upper(coalesce(estado,'')) = 'DISPONIBLE'
     and fecha_creacion < now() - interval '24 hours';
  get diagnostics v_disp = row_count;
  update wh.listas_sombra
     set estado='ANULADA', fecha_completada=now(),
         nota = coalesce(nota,'') || ' [vencida: 24h jalada sin cerrar]'
   where upper(coalesce(estado,'')) = 'EN_USO'
     and coalesce(fecha_tomada, fecha_creacion) < now() - interval '24 hours';
  get diagnostics v_uso = row_count;
  return jsonb_build_object('ok',true,'vencidasDisponibles',v_disp,'vencidasEnUso',v_uso);
end;
$function$
