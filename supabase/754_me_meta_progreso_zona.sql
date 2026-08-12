-- 754 · Meta del salvapantallas de ME conectada a la política REAL de la zona (12-ago-2026)
-- El salvapantallas leía la clave global muerta `evalMetaCajero` (mos.config) con default
-- 1000 hardcodeado en el front — la meta que el dueño edita vive en
-- mos.zonas.politica_json.metaDiaria con vigencia por día (729/730) y ME nunca la miraba.
-- Esta RPC da el progreso de meta POR ZONA (todas las cajas de la zona, hoy Lima):
--   · CAJERO/ADMIN ven barra + montos · VENDEDOR solo la barra (privacidad: el front
--     oculta montos, y de todas formas esta RPC solo devuelve agregados del día).
-- Cobrado = misma regla del salvapantallas y de datos_turno: excluye ANULADO / POR_COBRAR
-- / CREDITO (crédito no es dinero en mano hasta que se cobra).
create or replace function me.meta_progreso_zona(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_dia   date := (now() at time zone 'America/Lima')::date;
  v_meta  numeric;
  v_total numeric := 0;
begin
  if v_zona = '' then
    return jsonb_build_object('ok', false, 'error', 'Requiere zona');
  end if;

  -- [729/730] meta de la política de la zona, vigencia por día, SIN default global.
  v_meta := mos._meta_zona(v_zona, v_dia);

  select coalesce(sum(v.total), 0) into v_total
    from me.ventas v
   where upper(coalesce(v.zona_id, '')) = v_zona
     and (v.fecha at time zone 'America/Lima')::date = v_dia
     and upper(coalesce(v.forma_pago, '')) not in ('ANULADO','POR_COBRAR','CREDITO');

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'zona',       v_zona,
    'dia',        to_char(v_dia, 'YYYY-MM-DD'),
    'tieneMeta',  coalesce(v_meta, 0) > 0,
    'metaDiaria', round(coalesce(v_meta, 0) * 100) / 100,
    'lleva',      round(v_total * 100) / 100,
    'faltan',     case when coalesce(v_meta,0) > 0 then greatest(0, round((v_meta - v_total)*100)/100) else 0 end,
    'pct',        case when coalesce(v_meta,0) > 0 then round(v_total / v_meta * 1000) / 10 else 0 end
  ));
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM);
end;
$function$;

revoke all on function me.meta_progreso_zona(jsonb) from public;
grant execute on function me.meta_progreso_zona(jsonb) to authenticated, service_role;
