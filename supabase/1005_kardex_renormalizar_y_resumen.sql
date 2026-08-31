-- [1005] A) RENORMALIZAR EL LIBRO MAYOR del almacen (saldo corrido stock_antes/stock_despues) para los
--  productos con "eslabon roto" (stock_antes != stock_despues del movimiento anterior). Es EXACTAMENTE lo que
--  recomienda el propio detector tipo-2 ("Kardex inconsistente ... Renormalizar el libro mayor"). 270 productos
--  con eslabones rotos historicos (migracion GAS, RECON de 972 datado al inicio con saldos sin recomputar, etc.).
--  DISPLAY-ONLY: no toca wh.stock ni los delta; solo recalcula el saldo corrido para que cada kardex se lea como
--  un libro limpio que termina EXACTO en wh.stock (garantizado: descuadre global Sum(delta)=stock es 0 tras 1004).
--  Guardas: aborta si el checksum de wh.stock cambia o si quedan eslabones rotos.
--  >>> Ejecutar via supabase/_run1005_renorm.cjs (tx + verificacion + re-corre el detector).
do $$
declare
  v_chk_before numeric; v_chk_after numeric; v_rotos int; v_desc int;
begin
  select coalesce(sum(cantidad_disponible),0) into v_chk_before from wh.stock;

  with rotos as (
    select distinct cod_producto from (
      select cod_producto, stock_antes, lag(stock_despues) over (partition by cod_producto order by fecha, id_mov) prev
        from wh.stock_movimientos) x
     where prev is not null and round(stock_antes-prev,3) <> 0),
  ord as (
    select id_mov, sum(delta) over (partition by cod_producto
      order by (case when id_mov like 'RECON\_%' then 0 else 1 end), fecha, id_mov
      rows between unbounded preceding and current row) as run
    from wh.stock_movimientos where cod_producto in (select cod_producto from rotos))
  update wh.stock_movimientos m set stock_despues = ord.run, stock_antes = ord.run - m.delta
    from ord where m.id_mov = ord.id_mov;

  select coalesce(sum(cantidad_disponible),0) into v_chk_after from wh.stock;
  if round(v_chk_before,3) <> round(v_chk_after,3) then
    raise exception 'ABORT: wh.stock cambio (% -> %)', v_chk_before, v_chk_after;
  end if;
  select count(distinct cod_producto) into v_rotos from (
    select cod_producto, stock_antes, lag(stock_despues) over (partition by cod_producto order by fecha, id_mov) prev
      from wh.stock_movimientos) x where prev is not null and round(stock_antes-prev,3) <> 0;
  if v_rotos > 0 then raise exception 'ABORT: quedan % productos con eslabon roto', v_rotos; end if;
  select count(*) into v_desc from (
    select s.cod_producto, s.cantidad_disponible cd,
           coalesce((select sum(delta) from wh.stock_movimientos m where m.cod_producto=s.cod_producto),0) sm
      from wh.stock s) t where round(cd-sm,3) <> 0;
  if v_desc > 0 then raise exception 'ABORT: % productos descuadrados', v_desc; end if;
  raise notice 'OK 1005: libro renormalizado, stock intacto (%)', v_chk_after;
end $$;

-- B) RESUMEN barato para el AVISADOR (badge rojo del boton "Log de errores"):
--  cuenta diferencias ABIERTAS vigentes (ultima por ambito+zona+codigo, misma semantica que _listar)
--  agrupadas por categoria: SIS (tipos 1/2/3 = sistemico, lo persigue el master), OPE, CFG.
create or replace function mos.stock_diferencias_resumen(p jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_sis int; v_ope int; v_cfg int; v_tot int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  with vigentes as (
    select distinct on (d.ambito, d.zona_id, d.cod_barra) d.*
      from mos.stock_diferencias d
     where d.estado = 'ABIERTA'
     order by d.ambito, d.zona_id, d.cod_barra, d.dia desc, d.id desc)
  select count(*) filter (where coalesce(tipo_error,0) in (1,2,3)),
         count(*) filter (where coalesce(tipo_error,0) in (0,4)),
         count(*) filter (where coalesce(tipo_error,0) = 5),
         count(*)
    into v_sis, v_ope, v_cfg, v_tot
    from vigentes;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'sis', v_sis, 'ope', v_ope, 'cfg', v_cfg, 'total', v_tot));
end;
$function$;

select '1005 renormalizar libro + resumen avisador listo' as ok;
