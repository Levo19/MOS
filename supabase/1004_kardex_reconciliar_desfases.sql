-- [1004] RECONCILIA el kardex WH: "la guía declara X pero el kardex quedó en Y" (SABINA y sus 48 hermanos).
--  Contexto: wh.cerrar_guia_idempotente cerraba con placeholder (o con cant_recibida corrupta por scan-bleed) y,
--  al editar+re-cerrar, aplicaba el delta al STOCK pero (antes de 1001) NO reflejaba el nuevo total en el
--  movimiento MOVID_<guia>#<linea>. La reconciliacion 972 tapo cada hueco con un SALDO_INICIAL, de modo que el
--  stock siempre estuvo bien pero el kardex por-linea quedo desfasado y con "saldos" inflados (ej. +48018 para
--  cancelar un -48100 basura).
--  REGLA (verificada caso por caso): cantidad_aplicada es la verdad ("lo que la guia declara"). Se corrige cada
--  MOVID desfasado a +/-aplicada (signo por tipo de guia), se RECALCULA el RECON del producto (= wh.stock - Sum movs)
--  como ajuste-bot de cuadre, y se RECOMPONE el saldo corrido (stock_antes/stock_despues) para que el kardex se
--  lea como un libro limpio que termina EXACTO en wh.stock. NUNCA toca wh.stock (autoritativo). Reversible.
do $$
declare
  v_chk_before numeric;
  v_chk_after  numeric;
  v_desc       int;
begin
  select coalesce(sum(cantidad_disponible),0) into v_chk_before from wh.stock;

  create temp table _afect on commit drop as
  select distinct m.cod_producto
    from wh.guia_detalle gd
    join wh.guias g on g.id_guia = gd.id_guia
    join wh.stock_movimientos m on m.id_mov = 'MOVID_'||gd.id_guia||'#'||gd.linea
   where coalesce(gd.cantidad_aplicada,0) <> 0 and abs(m.delta) <> gd.cantidad_aplicada;

  -- 1) corregir cada MOVID desfasado -> +/-aplicada (INGRESO/ENTRADA=+, resto=-)
  update wh.stock_movimientos m
     set delta = case when upper(g.tipo) like 'INGRESO%' or upper(g.tipo) like 'ENTRADA%'
                      then gd.cantidad_aplicada else -gd.cantidad_aplicada end
    from wh.guia_detalle gd
    join wh.guias g on g.id_guia = gd.id_guia
   where m.id_mov = 'MOVID_'||gd.id_guia||'#'||gd.linea
     and coalesce(gd.cantidad_aplicada,0) <> 0 and abs(m.delta) <> gd.cantidad_aplicada;

  -- 2) AJUSTE-BOT: recalcular RECON existente del producto = wh.stock - Sum(movs no-RECON).
  update wh.stock_movimientos m
     set delta = tgt.recon
    from (
      select a.cod_producto,
             coalesce((select cantidad_disponible from wh.stock w where w.cod_producto = a.cod_producto order by id_stock limit 1),0)
               - coalesce((select sum(mm.delta) from wh.stock_movimientos mm
                            where mm.cod_producto = a.cod_producto and mm.id_mov not like 'RECON\_%'),0) as recon
        from _afect a
    ) tgt
   where m.id_mov = 'RECON_'||tgt.cod_producto;

  -- insertar RECON para afectados que aun no tienen (quedaban cuadrados antes de esta correccion)
  insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
  select 'RECON_'||a.cod_producto,
         coalesce((select min(fecha) from wh.stock_movimientos z where z.cod_producto = a.cod_producto),now()) - interval '1 second',
         a.cod_producto,
         coalesce((select cantidad_disponible from wh.stock w where w.cod_producto = a.cod_producto order by id_stock limit 1),0)
           - coalesce((select sum(mm.delta) from wh.stock_movimientos mm where mm.cod_producto = a.cod_producto and mm.id_mov not like 'RECON\_%'),0),
         0,0,'SALDO_INICIAL','reconciliacion-kardex-1004','reconciliacion-migracion'
    from _afect a
   where not exists (select 1 from wh.stock_movimientos r where r.id_mov = 'RECON_'||a.cod_producto)
     and abs(coalesce((select cantidad_disponible from wh.stock w where w.cod_producto = a.cod_producto order by id_stock limit 1),0)
           - coalesce((select sum(mm.delta) from wh.stock_movimientos mm where mm.cod_producto = a.cod_producto and mm.id_mov not like 'RECON\_%'),0)) > 0.001;

  -- 3) recomponer saldo corrido (RECON primero, luego por fecha) -> kardex limpio que termina en wh.stock
  with ord as (
    select id_mov,
           sum(delta) over (partition by cod_producto
             order by (case when id_mov like 'RECON\_%' then 0 else 1 end), fecha, id_mov
             rows between unbounded preceding and current row) as run
      from wh.stock_movimientos
     where cod_producto in (select cod_producto from _afect)
  )
  update wh.stock_movimientos m
     set stock_despues = ord.run, stock_antes = ord.run - m.delta
    from ord where m.id_mov = ord.id_mov;

  -- VERIFICACIONES
  select coalesce(sum(cantidad_disponible),0) into v_chk_after from wh.stock;
  if round(v_chk_before,3) <> round(v_chk_after,3) then
    raise exception 'ABORT: wh.stock cambio (% -> %)', v_chk_before, v_chk_after;
  end if;

  select count(*) into v_desc from (
    select a.cod_producto,
           (select cantidad_disponible from wh.stock w where w.cod_producto=a.cod_producto order by id_stock limit 1) st,
           (select sum(delta) from wh.stock_movimientos mm where mm.cod_producto=a.cod_producto) sm
      from _afect a) t
   where round(coalesce(st,0)-coalesce(sm,0),3) <> 0;
  if v_desc > 0 then
    raise exception 'ABORT: % productos afectados quedaron descuadrados', v_desc;
  end if;

  raise notice 'OK 1004: stock intacto (%), afectados cuadrados', v_chk_after;
end $$;

select '1004 kardex reconciliar desfases listo' as ok;
