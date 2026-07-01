-- ============================================================================
-- 304_mos_vetar_clave_server.sql — vetar/desvetar validan CLAVE ADMIN server-side
-- ----------------------------------------------------------------------------
-- 500x R1 (seguridad M1): vetar/desvetar (retención de sueldo) validaban el PIN admin
-- SOLO en el navegador. Con API._sb se podía vetar sin PIN. FIX: mismo patrón que
-- anular_pago (227) — exigir claveAdmin y verificar server-side con mos.verificar_clave_admin.
-- El front (2.43.394) manda auth.clave de pedirAuth. Cero-GAS (RPC directo).
-- ============================================================================

create or replace function mos.vetar_liquidacion_dia(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_clave   text := nullif(btrim(coalesce(p->>'claveAdmin','')), '');
  v_id_dia  text; v_now timestamptz := clock_timestamp(); v_n int; v_auth jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null or v_fecha_s is null then return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos'); end if;
  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
  -- [500x M1] retención de sueldo = acción admin → clave server-side, no se confía en el front.
  if v_clave is null then return jsonb_build_object('ok',false,'error','Requiere claveAdmin'); end if;
  v_auth := mos.verificar_clave_admin(v_clave, 'VETAR_LIQUIDACION', v_id_dia, 'MOS', null, null, 2, null);
  if coalesce((v_auth->>'autorizado')::boolean,false) <> true then
    return jsonb_build_object('ok',false,'error', coalesce(nullif(v_auth->>'error',''),'Clave admin incorrecta'));
  end if;

  update mos.liquidaciones_dia set estado='VETADA', ts_actualizado=v_now
    where id_dia = v_id_dia and upper(coalesce(estado,'PENDIENTE')) <> 'PAGADA';
  get diagnostics v_n = row_count;
  if v_n = 1 then return jsonb_build_object('ok',true,'data',jsonb_build_object('idDia',v_id_dia,'estado','VETADA')); end if;
  if exists (select 1 from mos.liquidaciones_dia where id_dia = v_id_dia) then
    return jsonb_build_object('ok',false,'error','YA_PAGADA');
  end if;
  return jsonb_build_object('ok',false,'error','NO_ENCONTRADA');
end;
$fn$;
revoke all on function mos.vetar_liquidacion_dia(jsonb) from public;
grant execute on function mos.vetar_liquidacion_dia(jsonb) to service_role, authenticated;

create or replace function mos.desvetar_liquidacion_dia(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_clave   text := nullif(btrim(coalesce(p->>'claveAdmin','')), '');
  v_id_dia  text; v_now timestamptz := clock_timestamp(); v_estado text; v_n int; v_auth jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null or v_fecha_s is null then return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos'); end if;
  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
  if v_clave is null then return jsonb_build_object('ok',false,'error','Requiere claveAdmin'); end if;
  v_auth := mos.verificar_clave_admin(v_clave, 'DESVETAR_LIQUIDACION', v_id_dia, 'MOS', null, null, 2, null);
  if coalesce((v_auth->>'autorizado')::boolean,false) <> true then
    return jsonb_build_object('ok',false,'error', coalesce(nullif(v_auth->>'error',''),'Clave admin incorrecta'));
  end if;

  update mos.liquidaciones_dia set estado='PENDIENTE', ts_actualizado=v_now
    where id_dia = v_id_dia and upper(coalesce(estado,'')) = 'VETADA';
  get diagnostics v_n = row_count;
  if v_n = 1 then return jsonb_build_object('ok',true,'data',jsonb_build_object('idDia',v_id_dia,'estado','PENDIENTE')); end if;
  select upper(coalesce(estado,'')) into v_estado from mos.liquidaciones_dia where id_dia = v_id_dia;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok',false,'error','NO_VETADA','mensaje','Estado actual: '||v_estado);
end;
$fn$;
revoke all on function mos.desvetar_liquidacion_dia(jsonb) from public;
grant execute on function mos.desvetar_liquidacion_dia(jsonb) to service_role, authenticated;
