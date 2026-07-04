-- 336_mos_seguridad_alertas.sql
-- [CERO-GAS] Reemplaza gas/SeguridadAlerts.gs::getSeguridadAlertas. Lee la sombra mos.seguridad_alertas
-- (fresca, dual-write de los writers GAS). Filtra estado='PENDIENTE', orden fecha desc, limit/tipo opcionales.
-- Shape EXACTO al GAS: {ok:true, data:{items:[...], count, porTipo}}. Keys camelCase idAlerta/idDispositivo/
-- idPersonal (paridad con SEGURIDAD_ALERTAS_HEADERS). count = total PENDIENTE antes del slice (badge correcto).
create or replace function mos.seguridad_alertas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_tipo  text := nullif(btrim(coalesce(p->>'tipo','')), '');
  v_limit int  := nullif(btrim(coalesce(p->>'limit','')),'')::int;
  v_count int;
  v_portipo jsonb;
  v_items jsonb;
begin
  if v_claim not in ('mosExpress','MOS','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- Universo: PENDIENTE (+ filtro tipo opcional). count/porTipo se calculan sobre TODO el universo (antes del limit).
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
      'datos_extra_json', coalesce(a.datos_extra_json,'{}'::jsonb)
    ) as row
    from mos.seguridad_alertas a
    where upper(coalesce(a.estado,'')) = 'PENDIENTE'
      and (v_tipo is null or a.tipo = v_tipo)
    order by a.fecha desc
    limit case when v_limit is not null and v_limit > 0 then v_limit else null end
  ) s;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'items', v_items, 'count', coalesce(v_count,0), 'porTipo', coalesce(v_portipo,'{}'::jsonb)));
end;
$fn$;
revoke all on function mos.seguridad_alertas(jsonb) from public;
grant execute on function mos.seguridad_alertas(jsonb) to anon, authenticated, service_role;
