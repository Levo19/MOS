-- ============================================================
-- 160_me_cierre_lectura.sql
-- LECTURA del cierre de caja desde Supabase (para que GAS NO dependa del Sheet).
-- ------------------------------------------------------------
-- Objetivo: que `_cerrarCajaAtomicoCore` (Caja.gs) y `generarGuiaSalidaVentas`
-- (Guias.gs) puedan leer TODO lo que hoy leen del Sheet (VENTAS_CABECERA,
-- VENTAS_DETALLE, MOVIMIENTOS_EXTRA, CAJAS, GUIAS_CABECERA) desde me.* en
-- UNA sola llamada. Con esto, borrar el Sheet NO rompe el cierre ni la guía.
--
-- Money-safety:
--   * Es 100% LECTURA (STABLE, sin efectos). NO descuenta stock, NO cierra caja.
--     El descuento sigue gobernado por me.zona_descontar_venta (idempotente por
--     id_caja en el kardex) y el cierre por me.cerrar_caja / el RMW del Sheet.
--   * `totales_por_cod` agrega cantidad por cod_barras SOLO de ventas VIVAS
--     (forma_pago que NO empieza con 'ANULADO' → excluye 'ANULADO' y
--     'ANULADO_CONVERSION'), idéntico al criterio de generarGuiaSalidaVentas.
--   * `efectivo_ventas` replica exactamente el cálculo de Caja.gs/cerrar_caja:
--     EFECTIVO completo + la porción EFE:NN de los MIXTO.
--   * `ids_por_cobrar` = ventas de la caja con forma_pago POR_COBRAR (las que el
--     cierre anula). `guia_salida_existe` detecta una guía SALIDA_VENTAS cuya
--     observación contiene el id_caja (mismo criterio anti-duplicado del Sheet).
--
-- Reutiliza me.guias_cabecera (observacion ILIKE %id_caja%) para la detección
-- de guía existente, igual que el Sheet (Tipo='SALIDA_VENTAS' + Obs contiene id).
-- ============================================================

create or replace function me.cierre_datos_caja(p_id_caja text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p_id_caja,'')),'');
  v_caja  me.cajas%rowtype;
  v_efe   numeric := 0;
  v_ing   numeric := 0;
  v_egr   numeric := 0;
  v_porc  text[];
  v_tot   jsonb;
  v_guia  boolean := false;
begin
  -- Gate de app: solo mosExpress (igual que cerrar_caja / crear_venta_directa).
  -- Vía service_role (GAS) jwt_app() devuelve '' → permitimos (backend de confianza).
  if v_app <> '' and v_app <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'ID_CAJA_REQUERIDO');
  end if;

  select * into v_caja from me.cajas where id_caja = v_id limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'CAJA_NO_ENCONTRADA', 'id_caja', v_id);
  end if;

  -- Efectivo de ventas NO anuladas de la caja (EFECTIVO + parte EFE de MIXTO).
  -- (idéntico a me.cerrar_caja / _cerrarCajaAtomicoCore)
  select coalesce(sum(
    case
      when upper(forma_pago) = 'EFECTIVO' then total
      when upper(forma_pago) like 'MIXTO%' then coalesce((regexp_match(forma_pago,'EFE:([0-9.]+)'))[1]::numeric, 0)
      else 0
    end), 0)
  into v_efe
  from me.ventas
  where id_caja = v_id
    and upper(coalesce(forma_pago,'')) not like 'ANULADO%';

  -- Ingresos / egresos efectivo de la caja
  select coalesce(sum(case when tipo='INGRESO' then monto else 0 end),0),
         coalesce(sum(case when tipo='EGRESO'  then monto else 0 end),0)
  into v_ing, v_egr
  from me.movimientos_extra where id_caja = v_id;

  -- IDs POR_COBRAR de la caja (las que el cierre anula)
  select array_agg(id_venta)
  into v_porc
  from me.ventas
  where id_caja = v_id and upper(coalesce(forma_pago,'')) = 'POR_COBRAR';
  v_porc := coalesce(v_porc, array[]::text[]);

  -- Totales por cod_barras de las ventas VIVAS de la caja (para descuento/guía).
  -- VIVAS = forma_pago NO empieza con 'ANULADO' (excluye ANULADO + ANULADO_CONVERSION).
  -- Resuelve cod_barras desde ventas_detalle; si la línea no trae cod_barras,
  -- cae al sku (mismo fallback que el Sheet: detalle[6] || detalle[1]).
  select coalesce(jsonb_object_agg(cb, cant), '{}'::jsonb)
  into v_tot
  from (
    select upper(btrim(coalesce(nullif(d.cod_barras,''), d.sku))) as cb,
           sum(coalesce(d.cantidad,0)) as cant
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
    where v.id_caja = v_id
      and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
      and coalesce(nullif(d.cod_barras,''), d.sku) is not null
      and btrim(coalesce(nullif(d.cod_barras,''), d.sku)) <> ''
    group by 1
    having sum(coalesce(d.cantidad,0)) > 0
  ) t;

  -- ¿Ya existe guía SALIDA_VENTAS para esta caja? (anti-duplicado)
  -- Mismo criterio del Sheet: Tipo='SALIDA_VENTAS' + observacion contiene el id_caja.
  select exists(
    select 1 from me.guias_cabecera
    where tipo = 'SALIDA_VENTAS'
      and coalesce(observacion,'') ilike '%'||v_id||'%'
  ) into v_guia;

  return jsonb_build_object(
    'ok', true,
    'id_caja', v_id,
    'vendedor', coalesce(v_caja.vendedor,''),
    'estacion', coalesce(v_caja.estacion,''),
    'zona', coalesce(v_caja.zona_id,''),
    'estado', coalesce(v_caja.estado,''),
    'monto_inicial', coalesce(v_caja.monto_inicial,0),
    'monto_final', v_caja.monto_final,
    'printnode_id', coalesce(v_caja.printnode_id,''),
    'fecha_apertura', v_caja.fecha_apertura,
    'fecha_cierre', v_caja.fecha_cierre,
    'efectivo_ventas', round(v_efe,2),
    'ingresos_efe', round(v_ing,2),
    'egresos_efe', round(v_egr,2),
    'ids_por_cobrar', to_jsonb(v_porc),
    'totales_por_cod', v_tot,
    'guia_salida_existe', v_guia
  );
end;
$function$;

revoke all on function me.cierre_datos_caja(text) from public, anon;
grant execute on function me.cierre_datos_caja(text) to authenticated, service_role;
