-- [959] Yape GLOBAL: 1 Yape puede cubrir la SUMA de 2+ tickets (cliente que compra varias veces y
-- paga un solo Yape). Aditivo y money-safe: el 1:1 existente (yapes_entrantes.id_venta + ux_yapes_venta)
-- NO se toca. Los enlaces N-tickets viven en una tabla aparte; "ticket cubierto" = 1:1 O enlace global.
-- La combinación NUNCA se auto-aplica: se SUGIERE (yape_combos) y el admin confirma (yape_atar_global).

-- ── tabla de enlace (un ticket ↔ máx un enlace global) ──
create table if not exists mos.yape_ventas (
  id_yape  bigint not null references mos.yapes_entrantes(id) on delete cascade,
  id_venta text   not null,
  creado   timestamptz not null default now(),
  por      text,
  primary key (id_venta)
);
create index if not exists ix_yape_ventas_yape on mos.yape_ventas(id_yape);

-- ── ¿un ticket ya está cubierto por ALGÚN Yape (1:1 o global)? ──
create or replace function mos._venta_cubierta(p_id_venta text)
returns boolean language sql stable security definer set search_path to '' as $$
  select exists(select 1 from mos.yapes_entrantes where id_venta = p_id_venta and estado = 'MATCHEADO')
      or exists(select 1 from mos.yape_ventas where id_venta = p_id_venta);
$$;

-- ── SUGERENCIA de combinaciones: subconjuntos (2 y 3 tickets) cuya suma virtual = monto del Yape ──
-- Solo tickets virtuales de la caja NO cubiertos. Ranking: menos tickets, más juntos en el tiempo,
-- y más cerca de la hora del Yape. Devuelve hasta 6 combos. READ-ONLY (no escribe nada).
create or replace function mos.yape_combos(p_caja text, p_monto numeric, p_ts timestamptz, p_max int default 6)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v_out jsonb;
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
     limit 40   -- cota de seguridad: no explota aunque la caja tenga muchos tickets
  ),
  pares as (
    select 2 as n, jsonb_build_array(
             jsonb_build_object('idVenta',a.id_venta,'correlativo',a.correlativo,'virtual',a.v,'hora',to_char(a.fecha at time zone 'America/Lima','HH24:MI')),
             jsonb_build_object('idVenta',b.id_venta,'correlativo',b.correlativo,'virtual',b.v,'hora',to_char(b.fecha at time zone 'America/Lima','HH24:MI'))
           ) as ventas,
           round(a.v+b.v,1) as suma,
           extract(epoch from (b.fecha-a.fecha))/60 as spread,
           least(abs(extract(epoch from (a.fecha-p_ts))),abs(extract(epoch from (b.fecha-p_ts))))/60 as cerca
      from cand a join cand b on b.rn > a.rn
     where round(a.v+b.v,1) = round(p_monto,1)
  ),
  triples as (
    select 3 as n, jsonb_build_array(
             jsonb_build_object('idVenta',a.id_venta,'correlativo',a.correlativo,'virtual',a.v,'hora',to_char(a.fecha at time zone 'America/Lima','HH24:MI')),
             jsonb_build_object('idVenta',b.id_venta,'correlativo',b.correlativo,'virtual',b.v,'hora',to_char(b.fecha at time zone 'America/Lima','HH24:MI')),
             jsonb_build_object('idVenta',c.id_venta,'correlativo',c.correlativo,'virtual',c.v,'hora',to_char(c.fecha at time zone 'America/Lima','HH24:MI'))
           ) as ventas,
           round(a.v+b.v+c.v,1) as suma,
           extract(epoch from (c.fecha-a.fecha))/60 as spread,
           least(abs(extract(epoch from (a.fecha-p_ts))),abs(extract(epoch from (c.fecha-p_ts))))/60 as cerca
      from cand a join cand b on b.rn > a.rn join cand c on c.rn > b.rn
     where round(a.v+b.v+c.v,1) = round(p_monto,1)
  ),
  todos as (select * from pares union all select * from triples)
  select coalesce(jsonb_agg(jsonb_build_object('n',n,'suma',suma,'spreadMin',round(spread)::int,'ventas',ventas)
                   order by n, spread, cerca), '[]'::jsonb)
    into v_out
    from (select * from todos order by n, spread, cerca limit p_max) z;
  return coalesce(v_out,'[]'::jsonb);
end $function$;

-- ── CONFIRMAR una combinación: ata N tickets a un Yape (money-safe, validado, transaccional) ──
create or replace function mos.yape_atar_global(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_id   bigint := nullif(p->>'id','')::bigint;
  v_por  text   := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'?');
  v_arr  jsonb  := p->'idVentas';
  v_est  text; v_monto numeric;
  v_ventas text[]; v_n int; v_suma numeric := 0; t text; v_vir numeric;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','id requerido'); end if;
  if v_arr is null or jsonb_typeof(v_arr) <> 'array' then return jsonb_build_object('ok',false,'error','idVentas requerido'); end if;

  select array(select jsonb_array_elements_text(v_arr)) into v_ventas;
  v_n := coalesce(array_length(v_ventas,1),0);
  if v_n < 2 then return jsonb_build_object('ok',false,'error','La combinación necesita 2+ tickets'); end if;
  if v_n <> (select count(distinct x) from unnest(v_ventas) x) then
    return jsonb_build_object('ok',false,'error','Hay tickets repetidos en la combinación'); end if;

  -- el Yape debe existir, tener monto, y NO estar ya cuadrado
  select estado, monto into v_est, v_monto from mos.yapes_entrantes where id = v_id for update;
  if v_est is null then return jsonb_build_object('ok',false,'error','Ese Yape no existe'); end if;
  if v_est = 'MATCHEADO' then return jsonb_build_object('ok',false,'error','Ese Yape ya está verificado'); end if;
  if v_monto is null then return jsonb_build_object('ok',false,'error','Ese Yape no tiene monto legible'); end if;

  -- cada ticket: existe, es virtual, y NO está cubierto por otro Yape (1:1 o global)
  foreach t in array v_ventas loop
    select me._monto_virtual(v.forma_pago, v.total) into v_vir from me.ventas v where v.id_venta = t;
    if not found then return jsonb_build_object('ok',false,'error','Ticket inexistente: '||t); end if;
    if v_vir is null then return jsonb_build_object('ok',false,'error','El ticket '||t||' no es pago por billetera'); end if;
    if mos._venta_cubierta(t) then return jsonb_build_object('ok',false,'error','El ticket '||t||' ya está verificado por otro Yape'); end if;
    v_suma := v_suma + round(v_vir,1);
  end loop;

  -- la suma tiene que dar el monto del Yape (a 1 decimal)
  if round(v_suma,1) <> round(v_monto,1) then
    return jsonb_build_object('ok',false,'error',
      'La suma de los tickets (S/ '||to_char(v_suma,'FM999990.00')||') no coincide con el Yape (S/ '||to_char(v_monto,'FM999990.00')||')');
  end if;

  -- atar: los N enlaces + marcar el Yape MATCHEADO global (id_venta queda null; la lista vive en meta y en yape_ventas)
  insert into mos.yape_ventas (id_yape, id_venta, por) select v_id, x, v_por from unnest(v_ventas) x;
  update mos.yapes_entrantes
     set estado='MATCHEADO', id_venta=null, match_ts=now(), match_por=v_por,
         meta = coalesce(meta,'{}'::jsonb) || jsonb_build_object('global',true,'ventas',to_jsonb(v_ventas),'resueltoAMano',true)
   where id = v_id;

  return jsonb_build_object('ok',true,'data',jsonb_build_object('id',v_id,'tickets',v_n,'suma',v_suma,'por',v_por));
exception when unique_violation then
  return jsonb_build_object('ok',false,'error','Uno de los tickets se acaba de verificar en otra caja/Yape');
end $function$;

grant execute on function mos.yape_combos(text,numeric,timestamptz,int) to authenticated, anon, service_role;
grant execute on function mos.yape_atar_global(jsonb) to authenticated, anon, service_role;
grant execute on function mos._venta_cubierta(text) to authenticated, anon, service_role;

select '959 yape global listo' as ok;
