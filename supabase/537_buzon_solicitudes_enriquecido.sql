-- 537: (a) FIX 401 — la pantalla de bloqueo pollea verificar_horario_dispositivo SIN token
--      minted (rol anon) → grant anon (lee solo estado + vencimientos de horario del UUID).
--      (b) Buzón MOS: el card de solicitudes mostraba el UUID crudo (inútil para el admin).
--      El lister ahora adjunta por item el contexto del DISPOSITIVO: app, tipo de equipo
--      (user_agent), última sesión (quién), última conexión y estado — para que el card
--      diga "quién estuvo/está en ese equipo y de qué app" o "nunca se inició sesión".

begin;

grant execute on function mos.verificar_horario_dispositivo(jsonb) to anon;

create or replace function mos.seguridad_alertas(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security definer set search_path to ''
as $function$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_tipo  text := nullif(btrim(coalesce(p->>'tipo','')), '');
  v_limit int  := nullif(btrim(coalesce(p->>'limit','')),'')::int;
  v_count int;
  v_portipo jsonb;
  v_items jsonb;
begin
  if v_claim not in ('mosExpress','MOS','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  select coalesce(sum(n),0)::int,
         coalesce(jsonb_object_agg(tipo, n) filter (where tipo is not null), '{}'::jsonb)
    into v_count, v_portipo
  from (
    select coalesce(tipo,'OTRO') tipo, count(*) n
    from mos.seguridad_alertas
    where upper(coalesce(estado,'')) = 'PENDIENTE'
      and (v_tipo is null or tipo = v_tipo)
    group by coalesce(tipo,'OTRO')
  ) t;

  select coalesce(jsonb_agg(row order by (row->>'fecha') desc), '[]'::jsonb) into v_items
  from (
    select jsonb_build_object(
      'idAlerta', a.id_alerta, 'tipo', a.tipo, 'idDispositivo', a.id_dispositivo,
      'idPersonal', a.id_personal,
      'fecha', case when a.fecha is null then '' else to_char(a.fecha at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
      'descripcion', a.descripcion, 'prioridad', a.prioridad, 'estado', a.estado,
      'revisada_por', a.revisada_por,
      'revisada_en', case when a.revisada_en is null then '' else to_char(a.revisada_en at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
      'datos_extra_json', coalesce(a.datos_extra_json,'{}'::jsonb),
      -- [537] contexto del dispositivo para el card del buzón
      'device', case when d.id_dispositivo is null then null else jsonb_build_object(
        'app',            coalesce(d.app,''),
        'estado',         coalesce(d.estado,''),
        'nombreEquipo',   coalesce(d.nombre_equipo,''),
        'userAgent',      coalesce(d.user_agent,''),
        'ultimaSesion',   coalesce(d.ultima_sesion,''),
        'ultimaConexion', case when d.ultima_conexion is null then '' else to_char(d.ultima_conexion at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
        'ultimaZona',     coalesce(d.ultima_zona,'')
      ) end
    ) as row
    from mos.seguridad_alertas a
    left join mos.dispositivos d on d.id_dispositivo = a.id_dispositivo
    where upper(coalesce(a.estado,'')) = 'PENDIENTE'
      and (v_tipo is null or a.tipo = v_tipo)
    order by a.fecha desc
    limit case when v_limit is not null and v_limit > 0 then v_limit else null end
  ) s;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'items', v_items, 'count', coalesce(v_count,0), 'porTipo', coalesce(v_portipo,'{}'::jsonb)));
end $function$;

commit;
