-- ============================================================================
-- 293_mos_vetar_fallback_nombre.sql — vetar/desvetar LIMPIO (una sola fuente)
-- ----------------------------------------------------------------------------
-- El bug "NO_ENCONTRADA" al vetar desde Personal del Día NO se arregla con un
-- fallback por nombre (sería leer de otro lugar). Se arregla EN EL FRONT: ambos
-- botones (Personal del Día y Liquidación) mandan el id_personal de la MEGA TABLA
-- (mos.liquidaciones_dia). Aquí restauramos vetar/desvetar a su forma LIMPIA:
-- id_personal + fecha → id_dia, UPDATE atómico condicional. Sin fallback, sin GAS.
-- ============================================================================

create or replace function mos.vetar_liquidacion_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_id_dia  text;
  v_now     timestamptz := clock_timestamp();
  v_n int;
begin
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null or v_fecha_s is null then
    return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos');
  end if;
  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
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
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_id_dia  text;
  v_now     timestamptz := clock_timestamp();
  v_estado  text;
  v_n int;
begin
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null or v_fecha_s is null then
    return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos');
  end if;
  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
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
