-- 56_wh_registrar_actividad.sql — [PASO 5 · B4 soporte] Tracking de desempeño para la ESCRITURA DIRECTA.
-- Replica registrarActividad (GAS): incrementa el contador del tipo + total_actividades en la sesión ACTIVA del
-- personal (wh.desempeno, sombra de DESEMPENO). Resuelve el HALLAZGO 40x #3 (la escritura directa no debe perder el
-- tracking que alimenta la liquidación de jornales). El cliente la llama tras cada operación directa (best-effort).
-- Gate wh._claim_ok(). NOTA: incremental, no idempotente (= GAS); el cliente debe llamarla 1 vez por operación.

create or replace function wh.registrar_actividad(p_id_sesion text, p_tipo text, p_cantidad int default 1)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_col  text;
  v_cant int := greatest(1, coalesce(p_cantidad, 1));
  v_n    int;
begin
  if not wh._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if p_id_sesion is null or btrim(p_id_sesion) = '' then
    return jsonb_build_object('ok', true, 'skip', 'sin_sesion');   -- = GAS: sin idSesion no hace nada
  end if;
  v_col := case upper(coalesce(p_tipo,''))
    when 'GUIA_CREADA'         then 'guias_creadas'
    when 'GUIA_CERRADA'        then 'guias_cerradas'
    when 'ENVASADO_REGISTRADO' then 'envasados_registrados'
    when 'UNIDADES_ENVASADAS'  then 'unidades_envasadas'
    when 'MERMA_REGISTRADA'    then 'mermas_registradas'
    when 'AUDITORIA_EJECUTADA' then 'auditoria_ejecutadas'
    when 'PREINGRESO_CREADO'   then 'preingreso_creados'
    when 'AJUSTE_REALIZADO'    then 'ajustes_realizados'
    else null
  end;
  if v_col is null then
    return jsonb_build_object('ok', false, 'error', 'TIPO_INVALIDO', 'tipo', p_tipo);
  end if;
  -- v_col es de la whitelist (no entrada del usuario) → %I seguro. Incrementa contador + total en la sesión ACTIVA.
  execute format(
    'update wh.desempeno set %I = coalesce(%I,0) + $1, total_actividades = coalesce(total_actividades,0) + $1 '
    || 'where id_sesion = $2 and estado = ''ACTIVA''', v_col, v_col
  ) using v_cant, p_id_sesion;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'actualizadas', v_n, 'columna', v_col);
end;
$fn$;

revoke all on function wh.registrar_actividad(text, text, int) from public;
grant execute on function wh.registrar_actividad(text, text, int) to service_role, authenticated;
