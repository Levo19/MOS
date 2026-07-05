-- 392 · kill-GAS WH — procesarEliminacionMermas. Crea UNA guía SALIDA_MERMA (ABIERTA) con las mermas
-- descartadas (cantidad_desechada>0, sin id_guia_salida, estado<>ELIMINADO) + marca cada merma ELIMINADO.
-- El stock se descuenta cuando esa guía se CIERRA (flujo de guías ya migrado). Atómico. Valida clave admin.
create or replace function wh.procesar_eliminacion_mermas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_clave text := coalesce(p->>'claveAdmin','');
  v_usr   text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'almacen');
  v_verif jsonb; v_idguia text; v_lin int := 0; v_proc int := 0; rec record;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- auth admin (paridad con _requireAdmin del GAS)
  v_verif := mos.verificar_clave_admin(v_clave, 'PROCESAR_ELIMINACION_MERMAS', '', 'warehouseMos', '', 'Procesar mermas descartadas');
  if not coalesce((v_verif->>'autorizado')::boolean,false) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error',coalesce(v_verif->>'error','Clave incorrecta')));
  end if;

  -- ¿hay mermas para procesar?
  if not exists (select 1 from wh.mermas where coalesce(cantidad_desechada,0) > 0
      and coalesce(nullif(btrim(coalesce(id_guia_salida,'')),''),'') = '' and upper(coalesce(estado,'')) <> 'ELIMINADO') then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('idGuiaSalida','','procesados',0,'fallidos',0,'nada',true));
  end if;

  v_idguia := 'G_SM_' || (extract(epoch from clock_timestamp())*1000)::bigint::text;
  insert into wh.guias (id_guia, tipo, fecha, usuario, estado, comentario, ultima_actividad)
  values (v_idguia, 'SALIDA_MERMA', now(), v_usr, 'ABIERTA', 'Procesamiento de mermas descartadas', now());

  for rec in
    select id_merma, cod_producto, coalesce(cantidad_desechada,0) des, coalesce(motivo,'') motivo
      from wh.mermas
     where coalesce(cantidad_desechada,0) > 0
       and coalesce(nullif(btrim(coalesce(id_guia_salida,'')),''),'') = ''
       and upper(coalesce(estado,'')) <> 'ELIMINADO'
     for update
  loop
    v_lin := v_lin + 1;
    insert into wh.guia_detalle (id_guia, linea, cod_producto, cant_esperada, cant_recibida, observacion, id_detalle)
    values (v_idguia, v_lin, rec.cod_producto, rec.des, rec.des,
      'Merma '||rec.id_merma||' · '||rec.motivo, v_idguia||'_'||v_lin);
    update wh.mermas set id_guia_salida = v_idguia, estado = 'ELIMINADO', fecha_resolucion = coalesce(fecha_resolucion, now())
     where id_merma = rec.id_merma;
    v_proc := v_proc + 1;
  end loop;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'autorizado',true,'idGuiaSalida',v_idguia,'procesados',v_proc,'fallidos',0));
end; $fn$;

revoke all on function wh.procesar_eliminacion_mermas(jsonb) from public, anon;
grant execute on function wh.procesar_eliminacion_mermas(jsonb) to authenticated, service_role;
