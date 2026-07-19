-- 523_mermas_wh_7dias.sql — Dueño: "en WH mostrar los NO solucionados + los solucionados por
-- 7 DÍAS a partir del día que se solucionó (la idea es ver CÓMO fue solucionado)".
-- Cambia la ventana del alcance 'wh' de 15 → 7 días (MOS sigue viendo todo).
create or replace function wh.mermas_lista(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select case when wh._claim_ok() or mos._claim_ok()
    then jsonb_build_object('ok', true, 'data', coalesce((
      select jsonb_agg(jsonb_build_object(
        'idMerma', m.id_merma, 'fechaIngreso', m.fecha_ingreso, 'origen', m.origen,
        'codProducto', m.cod_producto, 'cantidadOriginal', m.cantidad_original,
        'cantidadPendiente', m.cantidad_pendiente, 'cantidadReparada', m.cantidad_reparada,
        'cantidadDesechada', m.cantidad_desechada, 'motivo', m.motivo, 'usuario', m.usuario,
        'idGuia', m.id_guia, 'estado', m.estado, 'culpa', coalesce(m.culpa, m.responsable),
        'foto', m.foto, 'fechaResolucion', m.fecha_resolucion,
        'observacionResolucion', m.observacion_resolucion,
        'idGuiaSalida', m.id_guia_salida, 'idGuiaTransformacion', m.id_guia_transformacion,
        'costoUnitario', coalesce(m.costo_unitario,0), 'stockDescontado', coalesce(m.stock_descontado,false),
        'diasPendiente', case when coalesce(m.cantidad_pendiente,0) > 0
                              then extract(day from now() - m.fecha_ingreso)::int else null end,
        'vencida', coalesce(m.cantidad_pendiente,0) > 0 and m.fecha_ingreso < now() - interval '3 days')
        order by (coalesce(m.cantidad_pendiente,0) > 0) desc, m.fecha_ingreso desc)
      from wh.mermas m
      where case when lower(coalesce(p->>'alcance','wh')) = 'mos'
              then m.fecha_ingreso >= now() - make_interval(days => least(greatest(coalesce((p->>'dias')::int, 365),1),1095))
              else (coalesce(m.cantidad_pendiente,0) > 0 or m.fecha_resolucion >= now() - interval '7 days') end
    ), '[]'::jsonb))
    else jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA') end;
$fn$;
