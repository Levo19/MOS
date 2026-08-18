-- 859_yape_un_decimal.sql
--
-- [DUEÑO] "toma en cuenta que todo Yape funciona a 1 DECIMAL, no dos decimales."
--
-- Dato de la realidad que cambia la comparación. Yape solo mueve montos con un decimal (S/ 5.5),
-- mientras que un ticket puede terminar en dos (S/ 5.54). Comparar exacto, como estaba, dejaría
-- SIN VERIFICAR para siempre a todo ticket con dos decimales: el Yape nunca podría traer 5.54.
--
-- La comparación pasa a hacerse redondeando AMBOS lados a un decimal, que es exactamente lo que
-- significa "el cliente yapeó el monto del ticket": 5.54 → 5.5 y 5.55 → 5.6, igual que lo que la
-- app le ofrece pagar.
--
-- Efecto secundario buscado: si dos tickets distintos caen en el mismo decimal (5.54 y 5.50 son
-- ambos 5.5), los DOS son candidatos y el Yape queda AMBIGUO. Eso es correcto — el sistema dice
-- "no puedo distinguirlos" en vez de elegir uno al azar, que es justo lo que no queremos.

begin;

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
    -- El ticket tiene que estar PAGADO por medio virtual (VIRTUAL, o la parte VIR de un MIXTO),
    -- por el mismo monto que el Yape A UN DECIMAL, dentro de la ventana y de la zona del celular,
    -- y sin otro Yape ya asignado. Un ticket anulado, a crédito o por cobrar NUNCA es candidato.
    select count(*), min(v.id_venta) into v_cands, v_venta
      from me.ventas v
      left join me.cajas k on k.id_caja = v.id_caja
     where me._monto_virtual(v.forma_pago, v.total) is not null
       and round(me._monto_virtual(v.forma_pago, v.total), 1) = round(y.monto, 1)
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
      update mos.yapes_entrantes set estado='AMBIGUO',
             meta = meta || jsonb_build_object('candidatos', v_cands)
       where id = y.id and estado <> 'AMBIGUO';
      v_amb := v_amb + 1;
    end if;
  end loop;

  return jsonb_build_object('ok',true,'matcheados',v_match,'ambiguos',v_amb);
end $fn$;

-- los candidatos del panel usan la MISMA regla, si no el admin vería una lista distinta
-- de la que usó el matcheo automático
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='mos' and p.proname='yapes_del_dia';
  v_new := replace(v_def,
    $old$             and abs(me._monto_virtual(v.forma_pago, v.total) - y.monto) < 0.005$old$,
    $old$             and round(me._monto_virtual(v.forma_pago, v.total), 1) = round(y.monto, 1)$old$);
  if v_new = v_def then raise exception '859: no se encontró el filtro de candidatos'; end if;
  execute v_new;
end $mig$;

commit;
