-- 864_yapes_recientes_rio.sql — el "río" de Yapes del Modo Cajero.
--
-- yape_pendientes_anuncio entrega SOLO lo que todavía no se cantó y lo marca como anunciado:
-- sirve para la voz, pero NO para pintar una lista, porque a la segunda lectura ya viene vacía.
-- El río necesita otra cosa: los Yapes de los últimos minutos SIEMPRE, con su estado, para que el
-- cajero vea de un vistazo cuáles están libres y cuáles ya verificaron un ticket.
--
-- Devuelve también los tickets de la caja cobrados por medio virtual que TODAVÍA no tienen Yape:
-- es la franja "esperando su Yape", y tiene que salir del servidor para que sobreviva a un
-- refresco de la pantalla — si viviera solo en memoria, recargar borraría lo que falta cuadrar.

begin;

create or replace function mos.yapes_rio(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_zona  text := nullif(btrim(coalesce(p->>'zona','')),'');
  v_caja  text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_min   int  := greatest(5, least(720, coalesce((p->>'min')::int, 90)));
  v_yapes jsonb; v_esperando jsonb;
begin
  if coalesce(me.jwt_app(),'') not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', y.id, 'monto', y.monto, 'pagador', coalesce(y.pagador,''),
      'hora', to_char(y.ts_notificacion at time zone 'America/Lima','HH24:MI'),
      'min', greatest(0, round(extract(epoch from (now() - y.ts_notificacion))/60)::int),
      'estado', y.estado, 'idVenta', coalesce(y.id_venta,''),
      'ilegible', (y.monto is null)
    ) order by y.ts_notificacion desc), '[]'::jsonb) into v_yapes
    from mos.yapes_entrantes y
   where y.ts_notificacion > now() - make_interval(mins => v_min)
     and (v_zona is null or coalesce(y.zona,'') = '' or upper(btrim(y.zona)) = upper(v_zona));

  -- tickets de ESTA caja cobrados por medio virtual y sin Yape: lo que falta cuadrar
  select coalesce(jsonb_agg(jsonb_build_object(
      'idVenta', v.id_venta, 'correlativo', coalesce(v.correlativo,''),
      'monto', me._monto_virtual(v.forma_pago, v.total),
      'hora', to_char(v.fecha at time zone 'America/Lima','HH24:MI')
    ) order by v.fecha desc), '[]'::jsonb) into v_esperando
    from me.ventas v
   where v_caja is not null and v.id_caja = v_caja
     and me._monto_virtual(v.forma_pago, v.total) is not null
     and not exists (select 1 from mos.yapes_entrantes y where y.id_venta = v.id_venta);

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'yapes', v_yapes, 'esperando', v_esperando));
end $fn$;

grant execute on function mos.yapes_rio(jsonb) to anon, authenticated, service_role;

create or replace function me.yapes_rio(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select mos.yapes_rio(p);
$fn$;
grant execute on function me.yapes_rio(jsonb) to anon, authenticated, service_role;

commit;
