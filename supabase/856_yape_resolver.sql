-- 856: la salida para el caso que motivó todo esto — dos clientes seguidos de S/5, uno pagó y
-- el otro no. El sistema NO adivina: deja el Yape en AMBIGUO y una persona decide cuál ticket
-- verificó. Esto es lo que hace posible esa decisión.

-- listado para el panel: los Yapes del día con su estado y, si están ambiguos, los tickets
-- candidatos entre los que hay que elegir.
create or replace function mos.yapes_del_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_d date; v_out jsonb; v_res jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  begin v_d := nullif(btrim(coalesce(p->>'fecha','')),'')::date; exception when others then v_d := null; end;
  v_d := coalesce(v_d, (now() at time zone 'America/Lima')::date);

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', y.id, 'hora', to_char(y.ts_notificacion at time zone 'America/Lima','HH24:MI'),
      'monto', y.monto, 'pagador', coalesce(y.pagador,''), 'estado', y.estado,
      'zona', coalesce(y.zona,''), 'dispositivo', coalesce(y.dispositivo,''),
      'idVenta', coalesce(y.id_venta,''), 'raw', y.raw,
      'correlativo', coalesce((select v.correlativo from me.ventas v where v.id_venta = y.id_venta),''),
      -- para los AMBIGUOS: los tickets entre los que hay que elegir
      'candidatos', case when y.estado = 'AMBIGUO' then coalesce((
          select jsonb_agg(jsonb_build_object(
                   'idVenta', v.id_venta, 'correlativo', coalesce(v.correlativo,''),
                   'hora', to_char(v.fecha at time zone 'America/Lima','HH24:MI'),
                   'total', v.total, 'vendedor', coalesce(v.vendedor,''),
                   'cliente', coalesce(nullif(btrim(v.cliente_nombre),''),'')) order by v.fecha)
            from me.ventas v
            left join me.cajas k on k.id_caja = v.id_caja
           where upper(coalesce(v.forma_pago,'')) = 'VIRTUAL'
             and abs(coalesce(v.total,0) - y.monto) < 0.005
             and v.fecha between y.ts_notificacion - interval '25 minutes'
                             and y.ts_notificacion + interval '25 minutes'
             and (coalesce(y.zona,'') = '' or upper(btrim(coalesce(k.zona_id,''))) = upper(btrim(y.zona)))
             and not exists (select 1 from mos.yapes_entrantes y2
                              where y2.id_venta = v.id_venta and y2.id <> y.id)), '[]'::jsonb)
        else '[]'::jsonb end
    ) order by y.ts_notificacion desc), '[]'::jsonb) into v_out
    from mos.yapes_entrantes y where y.dia = v_d;

  select jsonb_build_object(
      'total', count(*), 'matcheados', count(*) filter (where estado='MATCHEADO'),
      'ambiguos', count(*) filter (where estado='AMBIGUO'),
      'sinUsar', count(*) filter (where estado='NUEVO'),
      'ilegibles', count(*) filter (where monto is null),
      'monto', coalesce(sum(monto),0))
    into v_res from mos.yapes_entrantes where dia = v_d;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'fecha', to_char(v_d,'YYYY-MM-DD'), 'resumen', v_res, 'yapes', v_out));
end $fn$;
grant execute on function mos.yapes_del_dia(jsonb) to anon, authenticated, service_role;

-- resolver a mano: atar este Yape a ESE ticket (o soltarlo).
create or replace function mos.yape_resolver(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_id   bigint := nullif(p->>'id','')::bigint;
  v_vta  text   := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_por  text   := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'?');
  v_est  text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','id requerido'); end if;
  select estado into v_est from mos.yapes_entrantes where id = v_id for update;
  if v_est is null then return jsonb_build_object('ok',false,'error','Ese Yape no existe'); end if;

  if v_vta is null then   -- soltar
    update mos.yapes_entrantes set estado='NUEVO', id_venta=null, match_ts=null, match_por=null where id=v_id;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('id',v_id,'estado','NUEVO'));
  end if;

  if not exists (select 1 from me.ventas where id_venta = v_vta) then
    return jsonb_build_object('ok',false,'error','Ese ticket no existe');
  end if;
  -- un ticket, un solo Yape: si otro ya lo tomó, no se pisa
  if exists (select 1 from mos.yapes_entrantes where id_venta = v_vta and id <> v_id) then
    return jsonb_build_object('ok',false,'error','Ese ticket ya está verificado por otro Yape');
  end if;

  update mos.yapes_entrantes
     set estado='MATCHEADO', id_venta=v_vta, match_ts=now(), match_por=v_por,
         meta = meta || jsonb_build_object('resueltoAMano', true)
   where id = v_id;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('id',v_id,'idVenta',v_vta,'por',v_por));
end $fn$;
grant execute on function mos.yape_resolver(jsonb) to anon, authenticated, service_role;
