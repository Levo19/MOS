create or replace function mos.registrar_jornada(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local  text    := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id     text    := nullif(btrim(coalesce(p->>'idJornada','')), '');
  v_nombre text    := nullif(btrim(coalesce(p->>'nombre','')), '');
  v_monto  numeric := mos._numn(p->>'montoJornal');
  v_fecha  timestamptz;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_JORNADAS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_JORNADAS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_nombre is null then return jsonb_build_object('ok',false,'error','Requiere nombre y montoJornal'); end if;
  if v_monto is null or v_monto <= 0 then return jsonb_build_object('ok',false,'error','Requiere nombre y montoJornal'); end if;

  if v_local is not null then
    select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
  end if;

  if v_id is not null and exists (select 1 from mos.jornadas where id_jornada = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_id));
  end if;

  begin
    v_fecha := nullif(btrim(coalesce(p->>'fecha','')),'')::timestamptz;
  exception when others then v_fecha := null;
  end;
  v_fecha := coalesce(v_fecha, now());

  v_id := coalesce(v_id, 'JOR'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.jornadas (
    id_jornada, fecha, id_personal, nombre, rol, app_origen, zona,
    monto_jornal, observacion, registrado_por, fuente, local_id
  ) values (
    v_id, v_fecha,
    coalesce(nullif(btrim(coalesce(p->>'idPersonal','')),''),''),
    v_nombre,
    coalesce(nullif(btrim(coalesce(p->>'rol','')),''),''),
    coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''),'MOS'),
    coalesce(nullif(btrim(coalesce(p->>'zona','')),''),''),
    v_monto,
    coalesce(nullif(btrim(coalesce(p->>'observacion','')),''),''),
    coalesce(nullif(btrim(coalesce(p->>'registradoPor','')),''),''),
    'MANUAL',
    v_local
  )
  on conflict (id_jornada) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    if v_local is not null then
      select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_id));
  end if;

  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idJornada', v_id));
exception
  when unique_violation then
    if v_local is not null then
      select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_id));
end;
$fn$;