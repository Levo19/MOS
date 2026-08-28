-- [960] Integrar el Yape global: combos con ranking por cercanía + candidatos/sin-verificar que
-- excluyen lo ya cubierto por un global + sugerencias en el modal de caja + soltar un global.

-- ── combos v2: cota de dispersión (poda el ruido de combinaciones casuales lejanas) + ranking por
-- cuán cerca está el Yape del ÚLTIMO ticket (se paga después de comprar) ── top 3.
create or replace function mos.yape_combos(p_caja text, p_monto numeric, p_ts timestamptz, p_max int default 3)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v_out jsonb; v_spread_cap int := 180;  -- minutos: tolera "se olvidó y volvió", corta el ruido
begin
  if p_caja is null or p_monto is null or p_monto <= 0 then return '[]'::jsonb; end if;
  with cand as (
    select v.id_venta, coalesce(v.correlativo,'') as correlativo, v.fecha,
           round(me._monto_virtual(v.forma_pago, v.total), 1) as v,
           row_number() over (order by v.fecha) as rn
      from me.ventas v
     where v.id_caja = p_caja
       and me._monto_virtual(v.forma_pago, v.total) is not null
       and not mos._venta_cubierta(v.id_venta)
     order by v.fecha
     limit 40
  ),
  pares as (
    select 2 as n,
           jsonb_build_array(
             jsonb_build_object('idVenta',a.id_venta,'correlativo',a.correlativo,'virtual',a.v,'hora',to_char(a.fecha at time zone 'America/Lima','HH24:MI')),
             jsonb_build_object('idVenta',b.id_venta,'correlativo',b.correlativo,'virtual',b.v,'hora',to_char(b.fecha at time zone 'America/Lima','HH24:MI'))
           ) as ventas,
           round(a.v+b.v,1) as suma,
           round(extract(epoch from (b.fecha-a.fecha))/60)::int as spread,
           abs(extract(epoch from (p_ts-b.fecha))/60) as cerca
      from cand a join cand b on b.rn > a.rn
     where round(a.v+b.v,1) = round(p_monto,1)
       and extract(epoch from (b.fecha-a.fecha))/60 <= v_spread_cap
  ),
  triples as (
    select 3 as n,
           jsonb_build_array(
             jsonb_build_object('idVenta',a.id_venta,'correlativo',a.correlativo,'virtual',a.v,'hora',to_char(a.fecha at time zone 'America/Lima','HH24:MI')),
             jsonb_build_object('idVenta',b.id_venta,'correlativo',b.correlativo,'virtual',b.v,'hora',to_char(b.fecha at time zone 'America/Lima','HH24:MI')),
             jsonb_build_object('idVenta',c.id_venta,'correlativo',c.correlativo,'virtual',c.v,'hora',to_char(c.fecha at time zone 'America/Lima','HH24:MI'))
           ) as ventas,
           round(a.v+b.v+c.v,1) as suma,
           round(extract(epoch from (c.fecha-a.fecha))/60)::int as spread,
           abs(extract(epoch from (p_ts-c.fecha))/60) as cerca
      from cand a join cand b on b.rn > a.rn join cand c on c.rn > b.rn
     where round(a.v+b.v+c.v,1) = round(p_monto,1)
       and extract(epoch from (c.fecha-a.fecha))/60 <= v_spread_cap
  ),
  todos as (select * from pares union all select * from triples)
  select coalesce(jsonb_agg(jsonb_build_object('n',n,'suma',suma,'spreadMin',spread,'ventas',ventas)
                   order by cerca, n, spread), '[]'::jsonb)
    into v_out
    from (select * from todos order by cerca, n, spread limit p_max) z;
  return coalesce(v_out,'[]'::jsonb);
end $function$;

-- ── yape_resolver: soltar un global (borra los enlaces); atar 1:1 respeta la cobertura global ──
create or replace function mos.yape_resolver(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
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

  if v_vta is null then   -- soltar (desverificar): tanto 1:1 como global
    delete from mos.yape_ventas where id_yape = v_id;
    update mos.yapes_entrantes
       set estado='NUEVO', id_venta=null, match_ts=null, match_por=null,
           meta = (coalesce(meta,'{}'::jsonb) - 'global') - 'ventas'
     where id=v_id;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('id',v_id,'estado','NUEVO'));
  end if;

  if not exists (select 1 from me.ventas where id_venta = v_vta) then
    return jsonb_build_object('ok',false,'error','Ese ticket no existe');
  end if;
  -- un ticket, un solo Yape: si ya está cubierto (1:1 o global), no se pisa
  if mos._venta_cubierta(v_vta) then
    return jsonb_build_object('ok',false,'error','Ese ticket ya está verificado por otro Yape');
  end if;

  update mos.yapes_entrantes
     set estado='MATCHEADO', id_venta=v_vta, match_ts=now(), match_por=v_por,
         meta = coalesce(meta,'{}'::jsonb) || jsonb_build_object('resueltoAMano', true)
   where id = v_id;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('id',v_id,'idVenta',v_vta,'por',v_por));
end $function$;

select '960 integrar listo' as ok;
