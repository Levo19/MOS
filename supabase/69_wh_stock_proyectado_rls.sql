-- 69_wh_stock_proyectado_rls.sql — [PASO 5 · B3 backend] Stock PROYECTADO/teórico etiquetado.
-- ============================================================
-- El stock REAL (wh.stock.cantidad_disponible) se aplica solo al CERRAR la guía (NO se toca acá).
-- Esta RPC devuelve, ADEMÁS del real, el TEÓRICO/proyectado DERIVADO al vuelo (NO persistido):
--
--   proyectado = real + Σ(cant de líneas de guías ABIERTAS de INGRESO)
--                     − Σ(cant de líneas de guías ABIERTAS de SALIDA)
--
-- Regla de fusión decidida por el usuario: ver lo que va a entrar/salir SIN descuadrar el real.
--
-- Detalles incluidos: solo guías estado='ABIERTA'. Cantidad de la línea = cant_recibida (lo que el
-- operador lleva escaneado/cargado; cae a cant_esperada si recibida es 0, para mostrar la intención del pedido).
-- EXCLUYE ENVASADO (INGRESO_ENVASADO/SALIDA_ENVASADO): ese stock lo aplica Envasados aparte y no debe
-- contarse como por-recibir/por-salir genérico (paridad con cerrar_guia, que tampoco mueve stock en envasado).
-- INGRESO%  → suma (por_recibir);  resto (SALIDA%) → resta (por_salir).
--
-- Devuelve por producto: codigoProducto, cantidadDisponible (real), porRecibir, porSalir, proyectado,
-- + enriquecimiento idéntico a stock_enriquecido (descripcion/min/max/unidad/alertaMinimo) para que el front
-- lo use con el mismo shape. Solo aparecen los productos que TIENEN movimiento pendiente (por_recibir+por_salir>0):
-- el front ya tiene el real de stock_enriquecido; esto es el OVERLAY de proyección, no reemplaza la lista.
-- security definer + search_path='' + gate wh._claim_ok() + grant authenticated (patrón B3).
-- ============================================================

create or replace function wh.stock_proyectado_rls()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select case when not wh._claim_ok()
    then jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA')
    else (
      with pend as (
        -- líneas de guías ABIERTAS, no-envasado, con cantidad = recibida (o esperada si recibida 0)
        select
          d.cod_producto                                                         as cod,
          case when upper(coalesce(g.tipo,'')) like 'INGRESO%'
               then coalesce(nullif(d.cant_recibida,0), d.cant_esperada, 0) else 0 end as in_q,
          case when upper(coalesce(g.tipo,'')) like 'INGRESO%'
               then 0 else coalesce(nullif(d.cant_recibida,0), d.cant_esperada, 0) end as out_q
        from wh.guia_detalle d
        join wh.guias g on g.id_guia = d.id_guia
        where upper(coalesce(g.estado,'')) = 'ABIERTA'
          and upper(coalesce(g.tipo,'')) not in ('INGRESO_ENVASADO','SALIDA_ENVASADO')
          and d.cod_producto is not null and btrim(d.cod_producto) <> ''
      ),
      agg as (
        select cod, sum(in_q) as por_recibir, sum(out_q) as por_salir
        from pend group by cod
        having sum(in_q) <> 0 or sum(out_q) <> 0
      ),
      enr as (
        select
          a.cod,
          coalesce(s.cantidad_disponible, 0)                          as real_q,
          a.por_recibir, a.por_salir,
          coalesce(s.cantidad_disponible, 0) + a.por_recibir - a.por_salir as proyectado,
          coalesce(nullif(p.descripcion,''), a.cod)                   as descripcion,
          coalesce(p.stock_minimo,0)                                  as stock_minimo,
          coalesce(p.stock_maximo,0)                                  as stock_maximo,
          coalesce(p.unidad,'')                                       as unidad,
          (s.cantidad_disponible is not null and s.cantidad_disponible < coalesce(p.stock_minimo,0)) as alerta_minimo
        from agg a
        left join lateral (
          select cantidad_disponible from wh.stock s where s.cod_producto = a.cod order by s.id_stock limit 1
        ) s on true
        left join lateral (
          select descripcion, unidad, stock_minimo, stock_maximo
          from mos.productos p where p.codigo_barra = a.cod
          order by p.created_at desc nulls last, p.id_producto desc
          limit 1
        ) p on true
      )
      select jsonb_build_object('ok', true, 'data', coalesce((
        select jsonb_agg(jsonb_build_object(
          'codigoProducto',     cod,
          'cantidadDisponible', real_q,
          'porRecibir',         por_recibir,
          'porSalir',           por_salir,
          'proyectado',         proyectado,
          'descripcion',        descripcion,
          'stockMinimo',        stock_minimo,
          'stockMaximo',        stock_maximo,
          'unidad',             unidad,
          'alertaMinimo',       alerta_minimo
        ) order by cod)
        from enr
      ), '[]'::jsonb))
    ) end;
$fn$;

revoke all on function wh.stock_proyectado_rls() from public;
grant execute on function wh.stock_proyectado_rls() to service_role, authenticated;
