-- 374 · NIVEL 4 corte-GAS (ME). (a) mos.config_me: lee CONFIG_MOS (mos.config) como
-- objeto {clave:valor} sin claves sensibles → reemplaza getConfig. (b)
-- mos.crear_devolucion_zona: inserta la devolución en wh.devoluciones_zona (156) →
-- reemplaza el bridge wh_crearDevolucionZona (ME→WH). security definer escribe la
-- sombra wh.* sin exigir token WH; gate = me._claim_zona_ok (acepta mosExpress).

create or replace function mos.config_me()
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_obj jsonb;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb) into v_obj
  from mos.config
  where upper(clave) not like 'ADMIN_GLOBAL_PIN%' and upper(clave) not like '%TOKEN%' and upper(clave) not like '%SECRET%';
  return jsonb_build_object('ok',true,'data', v_obj);
end; $fn$;
revoke all on function mos.config_me() from public, anon;
grant execute on function mos.config_me() to authenticated, service_role;

create or replace function mos.crear_devolucion_zona(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_id text; v_pl jsonb;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok',false,'error','Devolución sin items');
  end if;
  v_id := 'DV' || (extract(epoch from clock_timestamp())*1000)::bigint || substr(md5(random()::text),1,4);
  v_pl := jsonb_build_object('items', v_items, 'notaGeneral', coalesce(p->>'notaGeneral',''));
  insert into wh.devoluciones_zona (id_devolucion, fecha_inicio, zona_origen, vendedor,
    id_dispositivo_origen, estado, payload_zona, foto_zona)
  values (v_id, now(), coalesce(p->>'zonaOrigen',''), coalesce(p->>'vendedor',''),
    coalesce(p->>'idDispositivoOrigen',''), 'EN_TRANSITO', v_pl, coalesce(p->>'fotoZona',''));
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idDevolucion', v_id, 'estado','EN_TRANSITO'));
end; $fn$;
revoke all on function mos.crear_devolucion_zona(jsonb) from public, anon;
grant execute on function mos.crear_devolucion_zona(jsonb) to authenticated, service_role;
