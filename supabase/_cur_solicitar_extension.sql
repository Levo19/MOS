CREATE OR REPLACE FUNCTION mos.solicitar_extension_horario(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_id   text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_dev  text := nullif(btrim(coalesce(p->>'deviceId', p->>'device_id','')),'');
  v_app  text := nullif(btrim(coalesce(p->>'app','')),'');
  v_min  int  := 60;                         -- [511] 1 HORA fija (ignora el minutos del cliente)
  v_mot  text := left(btrim(coalesce(p->>'motivo','Sin motivo')), 200);
  v_alerta text;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null and v_dev is not null then
    -- [533] resolver desde la caja ABIERTA del dispositivo (la sesión existe aunque esté bloqueada por horario)
    select p2.id_personal into v_id
      from me.cajas c
      join mos.personal p2 on lower(btrim(p2.nombre || ' ' || coalesce(p2.apellido,''))) = lower(btrim(c.vendedor))
                           or lower(btrim(p2.nombre)) = lower(btrim(c.vendedor))
     where c.dispositivo_id = v_dev and upper(coalesce(c.estado,'')) = 'ABIERTA'
     order by c.fecha_apertura desc limit 1;
    if v_id is null then v_id := 'DEV:' || v_dev; end if;   -- trazable por UUID (la aprobación es por device)
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  -- Dedup: si ya hay una solicitud PENDIENTE de esta persona (o de este UUID), no duplicar.
  if exists (select 1 from mos.seguridad_alertas
             where tipo='EXTENSION_HORARIO_PENDIENTE' and upper(coalesce(estado,''))='PENDIENTE'
               and (id_personal = v_id or (v_dev is not null and id_dispositivo = v_dev))) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('yaExistia',true));
  end if;
  v_alerta := 'SEG' || (extract(epoch from clock_timestamp())*1000)::bigint::text || upper(substr(md5(random()::text),1,4));
  insert into mos.seguridad_alertas(id_alerta, tipo, id_dispositivo, id_personal, fecha, descripcion, prioridad, estado, datos_extra_json)
  values (v_alerta, 'EXTENSION_HORARIO_PENDIENTE', v_dev, v_id, now(),
          'Solicita extensión 1h · ' || v_mot, 'MEDIA', 'PENDIENTE',
          jsonb_build_object('minutos', v_min, 'motivo', v_mot, 'deviceId', coalesce(v_dev,''),
                             'app', coalesce(v_app,''), 'solicitadoEn', to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idAlerta', v_alerta, 'pendiente', true, 'minutos', v_min));
end; $function$
