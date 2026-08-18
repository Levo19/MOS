-- 855c: el POS llama con su propio perfil (Content-Profile: me), así que necesita el espejo.
-- Y la guarda de app: mos._claim_ok() solo acepta 'MOS' y el token de MosExpress dice
-- 'mosExpress' — la misma trampa que ya costó una vez con los turnos (848d).
create or replace function mos.yape_pendientes_anuncio(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_zona text := nullif(btrim(coalesce(p->>'zona','')),''); v_out jsonb;
begin
  if coalesce(me.jwt_app(),'') not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  with pend as (
    select id, monto, pagador, estado, id_venta, raw,
           to_char(ts_notificacion at time zone 'America/Lima','HH24:MI') hora
      from mos.yapes_entrantes
     where not anunciado
       and ts_notificacion > now() - interval '30 minutes'
       and (v_zona is null or coalesce(zona,'') = '' or upper(btrim(zona)) = upper(v_zona))
     order by ts_notificacion
     limit 20
  ), marca as (
    update mos.yapes_entrantes set anunciado = true where id in (select id from pend) returning id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'monto', monto, 'pagador', coalesce(pagador,''), 'hora', hora,
           'estado', estado, 'idVenta', coalesce(id_venta,''),
           'frase', case when monto is null then 'Llegó un Yape que no pude leer'
                         else trim(to_char(trunc(monto),'FM999999990')) || ' soles' ||
                              case when monto <> trunc(monto)
                                   then ' con ' || to_char(round((monto - trunc(monto)) * 100), 'FM90') else '' end ||
                              case when coalesce(pagador,'') <> '' then ' de ' || pagador else '' end end
         ) order by id), '[]'::jsonb) into v_out
    from pend, (select count(*) from marca) _;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('yapes', v_out));
end $fn$;

create or replace function me.yape_pendientes_anuncio(p jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path to '' as $fn$
  select mos.yape_pendientes_anuncio(p);
$fn$;
grant execute on function me.yape_pendientes_anuncio(jsonb) to anon, authenticated, service_role;
