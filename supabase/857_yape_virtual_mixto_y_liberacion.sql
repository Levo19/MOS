-- 857_yape_virtual_mixto_y_liberacion.sql
--
-- [DUEÑO] "para verificar un Yape el ticket debe estar PAGADO con método VIRTUAL o MIXTO, recién
--  después puede estar verificado. Y si desde MOS o ME el ticket se cambia de pago de VIRTUAL a
--  EFECTIVO, ese verificado se LIBERA para después ver de quién puede ser."
--
-- Las dos observaciones corrigen errores reales de mi diseño:
--
-- 1. MIXTO quedaba fuera. Y peor: si lo hubiera metido comparando contra el TOTAL habría estado
--    mal igual — en "MIXTO (VIR:20.00/EFE:35.50)" el cliente yapeó 20, no 55.50. Lo que tiene que
--    coincidir con el Yape es la PARTE VIRTUAL, no el total del ticket.
--
-- 2. Un ticket que deja de ser virtual no puede seguir verificado. Si el cajero se equivocó y lo
--    corrige a EFECTIVO, ese Yape es de OTRA venta: hay que soltarlo para que vuelva a la bolsa de
--    libres y encuentre a su dueño. Sin esto el Yape queda pegado a un ticket en efectivo y el
--    verdadero nunca se verifica.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) Cuánto de este ticket se pagó POR MEDIO VIRTUAL. Null = no aplica.
--    Es lo único que un Yape puede verificar.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function me._monto_virtual(p_forma text, p_total numeric)
returns numeric language plpgsql immutable set search_path to '' as $fn$
declare f text := upper(btrim(coalesce(p_forma,''))); m text[];
begin
  if f = 'VIRTUAL' then return coalesce(p_total,0); end if;
  if f like 'MIXTO%' then
    -- "MIXTO (VIR:20.00/EFE:35.50)" -> 20.00 (lo que entró por billetera, no el total)
    m := regexp_match(f, 'VIR:[[:space:]]*([0-9]+(?:[.,][0-9]{1,2})?)');
    if m is not null then
      begin return replace(m[1], ',', '.')::numeric; exception when others then return null; end;
    end if;
    return null;
  end if;
  return null;   -- EFECTIVO, CREDITO, POR_COBRAR, ANULADO, PLANILLA: nada que verificar
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) El matcheo compara contra la PARTE VIRTUAL y exige ticket pagado por ese medio.
-- ─────────────────────────────────────────────────────────────────────────────
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
    -- por el mismo monto que el Yape, dentro de la ventana y de la zona del celular, y sin otro
    -- Yape ya asignado. Un ticket anulado, a crédito o por cobrar NUNCA es candidato.
    select count(*), min(v.id_venta) into v_cands, v_venta
      from me.ventas v
      left join me.cajas k on k.id_caja = v.id_caja
     where me._monto_virtual(v.forma_pago, v.total) is not null
       and abs(me._monto_virtual(v.forma_pago, v.total) - y.monto) < 0.005
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) LA LIBERACIÓN. Si el ticket deja de estar pagado por medio virtual —lo pasan a
--    efectivo, lo anulan, lo mandan a crédito— su Yape se suelta AUTOMÁTICAMENTE y
--    vuelve a la bolsa de libres. Es un trigger y no una tarea programada porque el
--    momento del cambio es el momento de soltarlo: mientras tanto, el Yape verdadero
--    estaría bloqueado por un ticket que ya no le corresponde.
--    Si cambia el monto virtual (un MIXTO reeditado) también se suelta: ya no cuadra.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos._tg_yape_liberar()
returns trigger language plpgsql security definer set search_path to '' as $fn$
declare v_ant numeric; v_new numeric;
begin
  v_ant := me._monto_virtual(old.forma_pago, old.total);
  v_new := me._monto_virtual(new.forma_pago, new.total);
  if v_ant is not distinct from v_new then return new; end if;

  update mos.yapes_entrantes
     set estado = 'NUEVO', id_venta = null, match_ts = null, match_por = null,
         anunciado = true,   -- ya se cantó cuando entró; no repetir la voz al soltarlo
         meta = meta || jsonb_build_object(
           'liberado', jsonb_build_object(
             'ts', to_jsonb(now()), 'idVenta', new.id_venta,
             'de', coalesce(old.forma_pago,''), 'a', coalesce(new.forma_pago,''),
             'motivo', 'el ticket dejó de estar pagado por medio virtual'))
   where id_venta = new.id_venta;
  return new;
end $fn$;

drop trigger if exists tg_yape_liberar on me.ventas;
create trigger tg_yape_liberar
  after update of forma_pago, total on me.ventas
  for each row
  when (old.forma_pago is distinct from new.forma_pago or old.total is distinct from new.total)
  execute function mos._tg_yape_liberar();

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) Los candidatos del panel usan la misma regla.
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='mos' and p.proname='yapes_del_dia';
  v_new := replace(v_def,
    $old$           where upper(coalesce(v.forma_pago,'')) = 'VIRTUAL'
             and abs(coalesce(v.total,0) - y.monto) < 0.005$old$,
    $old$           where me._monto_virtual(v.forma_pago, v.total) is not null
             and abs(me._monto_virtual(v.forma_pago, v.total) - y.monto) < 0.005$old$);
  if v_new = v_def then raise exception '857: no se encontró el filtro de candidatos'; end if;
  execute v_new;
end $mig$;

-- 5) y el resumen del cierre también cuenta los MIXTO
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='me' and p.proname='datos_turno';
  v_new := replace(v_def,
    $old$         where v.id_caja = p_id_caja
           and upper(coalesce(v.forma_pago,'')) = 'VIRTUAL'),$old$,
    $old$         where v.id_caja = p_id_caja
           and me._monto_virtual(v.forma_pago, v.total) is not null),$old$);
  if v_new = v_def then raise exception '857: no se encontró el filtro del cierre'; end if;
  execute v_new;
end $mig$;

commit;
