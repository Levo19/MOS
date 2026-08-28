-- [972] Reconciliación de historial ↔ stock real (ADITIVA, firmada, reversible).
--  CAUSA confirmada de los descuadres: (1) STOCK INICIAL de la migración GAS→Supabase nunca registrado como
--  movimiento (no existe tipo INICIAL; hay productos con stock y 0 movimientos, y cadenas que arrancan en
--  stock_antes≠0); (2) reversas/anulaciones que no netean; (3) 12 ingresos sub-registrados (gap real).
--  NO toca wh.stock (autoritativo y correcto). Solo AGREGA un movimiento de reconciliación por producto
--  descuadrado = (stock_real − Σmovimientos), con firma en wh.ajustes. Idempotente (id determinista +
--  on conflict). Reversible: borrar los id_mov 'RECON_%' y ajustes 'AJRECON_%'.
do $$
declare v_stock_ck numeric; v_stock_ck2 numeric; v_desc_antes int; v_desc_despues int;
begin
  -- checksum de wh.stock (para probar que NO se toca)
  select coalesce(sum(cantidad_disponible),0) into v_stock_ck from wh.stock;
  select count(*) into v_desc_antes from wh.stock s
    where abs(s.cantidad_disponible - coalesce((select sum(delta) from wh.stock_movimientos m where m.cod_producto=s.cod_producto),0)) > 0.01;

  create temp table _rec on commit drop as
  with cand as (
    select d.cod_producto, (d.cantidad_aplicada - (
       coalesce((select m.delta from wh.stock_movimientos m where m.id_mov='MOVID_'||g.id_guia||'#'||d.linea),0)
       + coalesce((select sum(m.delta) from wh.stock_movimientos m where m.origen=d.id_detalle),0))) corr
    from wh.guias g join wh.guia_detalle d on d.id_guia=g.id_guia
    where g.estado='CERRADA' and g.tipo like 'INGRESO%' and g.tipo<>'INGRESO_ENVASADO'),
  agg as (select cod_producto, sum(corr) tot from cand where round(corr,3)>0 group by cod_producto),
  ok as (select a.cod_producto from agg a
          where round((select cantidad_disponible from wh.stock s where s.cod_producto=a.cod_producto)
                      - (select coalesce(sum(delta),0) from wh.stock_movimientos m where m.cod_producto=a.cod_producto),3)=round(a.tot,3)),
  d0 as (select s.cod_producto, s.cantidad_disponible real,
           coalesce((select sum(delta) from wh.stock_movimientos m where m.cod_producto=s.cod_producto),0) suma
         from wh.stock s)
  select d0.cod_producto,
         round(d0.real - d0.suma, 3) delta,
         (d0.cod_producto in (select cod_producto from ok)) es_ingreso,
         coalesce((select min(fecha) from wh.stock_movimientos m where m.cod_producto=d0.cod_producto) - interval '1 second',
                  timestamptz '2026-05-01 00:00:00-05') f
  from d0 where abs(d0.real - d0.suma) > 0.01;

  -- movimiento de reconciliación (opening) por producto descuadrado
  insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
  select 'RECON_'||r.cod_producto, r.f, r.cod_producto, r.delta, 0, r.delta,
         case when r.es_ingreso then 'CORRECCION_INGRESO' else 'SALDO_INICIAL' end,
         'reconciliacion-migracion',
         case when r.es_ingreso then 'correccion-ingreso-subregistrado' else 'saldo-inicial-migracion' end
  from _rec r
  on conflict (id_mov) do nothing;

  -- firma auditable en wh.ajustes
  insert into wh.ajustes (id_ajuste, cod_producto, tipo_ajuste, cantidad_ajuste, motivo, usuario, id_auditoria, fecha)
  select 'AJRECON_'||r.cod_producto, r.cod_producto,
         case when r.delta >= 0 then 'INC' else 'DEC' end, abs(r.delta),
         case when r.es_ingreso then 'Corrección: ingreso sub-registrado (faltaba en historial) · reconciliación con stock real'
              else 'Saldo inicial de migración (historial previo no cargado) · reconciliación con stock real' end,
         'reconciliacion-migracion', '', now()
  from _rec r
  on conflict (id_ajuste) do nothing;

  -- VERIFICACIONES
  select coalesce(sum(cantidad_disponible),0) into v_stock_ck2 from wh.stock;
  select count(*) into v_desc_despues from wh.stock s
    where abs(s.cantidad_disponible - coalesce((select sum(delta) from wh.stock_movimientos m where m.cod_producto=s.cod_producto),0)) > 0.01;

  if abs(v_stock_ck - v_stock_ck2) > 0.001 then
    raise exception 'ABORTA: wh.stock CAMBIÓ (%.3f → %.3f) — no debía tocarse', v_stock_ck, v_stock_ck2;
  end if;
  if v_desc_despues > 0 then
    raise exception 'ABORTA: quedaron % productos descuadrados (antes %) — algo no reconcilió', v_desc_despues, v_desc_antes;
  end if;
  raise notice 'OK 972: descuadres % → %, wh.stock intacto (checksum %)', v_desc_antes, v_desc_despues, v_stock_ck2;
end $$;

select '972 reconciliacion aplicada' as ok;
