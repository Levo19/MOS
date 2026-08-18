-- 854b: la zona de una venta NO está en me.ventas (no existe esa columna): sale de su caja
-- (me.cajas.zona_id). Sin este arreglo el matcheo reventaba en tiempo de ejecución — plpgsql no
-- valida los nombres de columna al crear la función, solo al ejecutarla.
create or replace function mos.yape_matchear(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_uno   bigint := nullif(p->>'id','')::bigint;
  v_min   int    := greatest(2, least(180, coalesce((p->>'ventanaMin')::int, 25)));
  y       record; v_cands int; v_venta text;
  v_match int := 0; v_amb int := 0;
begin
  for y in
    select * from mos.yapes_entrantes
     where estado in ('NUEVO','AMBIGUO')
       and monto is not null and monto > 0
       and (v_uno is null or id = v_uno)
       and ts_notificacion > now() - interval '2 days'
     order by ts_notificacion
  loop
    -- candidatos: ticket VIRTUAL vivo, mismo monto exacto, dentro de la ventana de tiempo,
    -- de la zona del celular (la zona sale de la CAJA de la venta) y sin Yape ya asignado.
    select count(*), min(v.id_venta) into v_cands, v_venta
      from me.ventas v
      left join me.cajas k on k.id_caja = v.id_caja
     where upper(coalesce(v.forma_pago,'')) = 'VIRTUAL'
       and abs(coalesce(v.total,0) - y.monto) < 0.005
       and v.fecha between y.ts_notificacion - make_interval(mins => v_min)
                       and y.ts_notificacion + make_interval(mins => v_min)
       and (coalesce(y.zona,'') = '' or upper(btrim(coalesce(k.zona_id,''))) = upper(btrim(y.zona)))
       and not exists (select 1 from mos.yapes_entrantes y2
                        where y2.id_venta = v.id_venta and y2.id <> y.id);

    if v_cands = 1 then
      update mos.yapes_entrantes
         set estado='MATCHEADO', id_venta=v_venta, match_ts=now(), match_por='AUTO'
       where id = y.id;
      v_match := v_match + 1;
    elsif v_cands > 1 then
      -- DOS tickets iguales y un solo Yape: no se adivina. Queda para que alguien resuelva.
      update mos.yapes_entrantes set estado='AMBIGUO',
             meta = meta || jsonb_build_object('candidatos', v_cands)
       where id = y.id and estado <> 'AMBIGUO';
      v_amb := v_amb + 1;
    end if;
  end loop;

  return jsonb_build_object('ok',true,'matcheados',v_match,'ambiguos',v_amb);
end $fn$;
