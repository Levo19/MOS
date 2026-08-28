-- [963] Cerrar dos huecos que abrió el Yape global (money-safe):
--  (1) yape_matchear (auto-cron) NO debía auto-atar un ticket ya cubierto por una combinación global.
--  (2) el trigger de liberación debía soltar el Yape global ENTERO si uno de sus tickets deja de ser virtual.

-- (1) auto-matcher: excluir tickets cubiertos por un enlace global
create or replace function mos.yape_matchear(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
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
    select count(*), min(v.id_venta) into v_cands, v_venta
      from me.ventas v
      left join me.cajas k on k.id_caja = v.id_caja
     where me._monto_virtual(v.forma_pago, v.total) is not null
       and round(me._monto_virtual(v.forma_pago, v.total), 1) = round(y.monto, 1)
       and v.fecha between y.ts_notificacion - make_interval(mins => v_min)
                       and y.ts_notificacion + make_interval(mins => v_min)
       and (coalesce(y.zona,'') = '' or upper(btrim(coalesce(k.zona_id,''))) = upper(btrim(y.zona)))
       and not exists (select 1 from mos.yapes_entrantes y2
                        where y2.id_venta = v.id_venta and y2.id <> y.id)
       -- [963] no candidatear un ticket que ya integra una combinación global
       and not exists (select 1 from mos.yape_ventas yv where yv.id_venta = v.id_venta);

    if v_cands = 1 then
      update mos.yapes_entrantes
         set estado='MATCHEADO', id_venta=v_venta, match_ts=now(), match_por='AUTO'
       where id = y.id;
      v_match := v_match + 1;
    elsif v_cands > 1 then
      update mos.yapes_entrantes set estado='AMBIGUO',
             meta = meta || jsonb_build_object('candidatos', v_cands)
       where id = y.id and estado <> 'AMBIGUO';
      v_amb := v_amb + 1;
    end if;
  end loop;

  return jsonb_build_object('ok',true,'matcheados',v_match,'ambiguos',v_amb);
end $function$;

-- (2) trigger de liberación: soltar también el Yape GLOBAL entero si un ticket suyo deja de ser virtual
do $mig$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('mos._tg_yape_liberar()'::regprocedure);
  if position('yape_ventas' in v_def) > 0 then raise notice '963: trigger ya parchado'; return; end if;
  v_new := replace(v_def,
    $a$   where id_venta = new.id_venta;
  return new;$a$,
    $b$   where id_venta = new.id_venta;

  -- [963] si el ticket integraba un Yape GLOBAL, soltar ese Yape ENTERO (la suma ya no cuadra) + limpiar enlaces
  update mos.yapes_entrantes ye
     set estado='NUEVO', id_venta=null, match_ts=null, match_por=null, anunciado=true,
         meta = ((coalesce(ye.meta,'{}'::jsonb) - 'global') - 'ventas')
                || jsonb_build_object('liberado', jsonb_build_object('ts', to_jsonb(now()),
                     'motivo','un ticket de la combinación global dejó de estar pagado por medio virtual'))
   where ye.id in (select yv.id_yape from mos.yape_ventas yv where yv.id_venta = new.id_venta);
  delete from mos.yape_ventas where id_yape in (select yv.id_yape from mos.yape_ventas yv where yv.id_venta = new.id_venta);
  return new;$b$);
  if v_new = v_def then raise exception '963: no encontré el cierre del trigger'; end if;
  execute v_new;
  raise notice '963: trigger de liberación cubre global';
end $mig$;

select '963 matcher+liberar global listo' as ok;
