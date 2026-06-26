-- ════════════════════════════════════════════════════════════════════════════
-- 250 · REPARACIÓN #3 — Guías·Zona: separar despacho-de-almacén vs guías internas
-- ════════════════════════════════════════════════════════════════════════════
-- SÍNTOMA: el modal "Guías · Zona" muestra una guía INTERNA (ej. `G-1782479398702...` ENTRADA_LIBRE,
-- el "ajo") como PENDIENTE con regla de sobró/faltó — pero esa regla SOLO debe aplicar a los despachos
-- que llegan de ALMACÉN (wh.guias SALIDA_ZONA, pickup/rápido). Además se muestra el id crudo (confuso).
--
-- CAUSA: me.zona_traslados_pendientes leía `me.guias_cabecera WHERE tipo like 'ENTRADA%'` (universo
-- equivocado) → surfaceaba guías internas como pendientes; y el despacho real de almacén que aún NO se
-- recibió (wh.guias SALIDA_ZONA sin fila 'WH:' en zona_traslado_verificacion) era INVISIBLE.
--
-- FIX (decisión del usuario: NO borrar nada, mostrar todo, pero estados+diff SOLO para almacén):
--   1) me.zona_traslados_pendientes REESCRITO → fuente = wh.guias SALIDA_ZONA del id_zona, CERRADA/
--      AUTOCERRADA, con líneas despachadas, SIN verificación 'WH:' aún. origen='WAREHOUSE', detalle inline.
--      Esto arregla el bug (las internas ya no salen como pendientes) Y destapa los despachos invisibles.
--   2) NUEVA me.zona_guias_internas → me.guias_cabecera (TODOS los tipos) como INFORMATIVAS (origen=
--      'INTERNAL'), con detalle inline. SIN estado pendiente/diff (el front las pinta informativas).
-- El front (app.js) pone etiquetas amigables (no el id) y aplica sobró/faltó SOLO a origen=WAREHOUSE.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) PENDIENTES = despachos de almacén (wh.guias SALIDA_ZONA) aún sin recibir ─────────────────────────────
create or replace function me.zona_traslados_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  -- [Rep#3] ventana corta (7d) para PENDIENTES de almacén: la recepción por escaneo en ME casi no se usa,
  -- así que un default de 30d inundaría con ~180 despachos perpetuamente "pendientes". 7d = lo reciente/accionable.
  v_dias  int  := greatest(1, coalesce((p->>'dias')::int, 7));
  v_items jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  select coalesce(jsonb_agg(t order by t->>'fecha' desc), '[]'::jsonb) into v_items
  from (
    select jsonb_build_object(
        'idGuia',       g.id_guia,
        'refVerif',     'WH:' || g.id_guia,
        'origen',       'WAREHOUSE',
        'tipoGuia',     g.tipo,
        'fecha',        g.fecha,
        'vendedor',     coalesce(nullif(btrim(g.usuario),''),'—'),
        'observacion',  coalesce(g.comentario,''),
        'lineas',       (select count(*) from wh.guia_detalle d where d.id_guia = g.id_guia and coalesce(d.cant_recibida,0) > 0),
        'totalEnviado', (select coalesce(sum(d.cant_recibida),0) from wh.guia_detalle d where d.id_guia = g.id_guia),
        'edadSeg',      floor(extract(epoch from (now() - g.fecha)))::bigint,
        'edadLbl',      me._edad_lbl(now() - g.fecha),
        -- detalle inline (lo despachado) → el front lo usa sin segunda RPC. enviado = cant_recibida.
        'detalle', (
          select coalesce(jsonb_agg(jsonb_build_object(
              'linea',       d.linea,
              'codBarra',    d.cod_producto,
              'descripcion', coalesce(pr.descripcion, d.cod_producto),
              'enviado',     coalesce(d.cant_recibida,0),
              'escaneado',   0,
              'dif',         coalesce(d.cant_recibida,0),
              'estado',      'PENDIENTE',
              'lote',        d.id_lote,
              'venc',        d.fecha_vencimiento
            ) order by d.linea), '[]'::jsonb)
          from wh.guia_detalle d
          left join mos.productos pr on pr.codigo_barra = d.cod_producto
          where d.id_guia = g.id_guia and coalesce(d.cant_recibida,0) > 0
        )
      ) as t
    from wh.guias g
    where upper(btrim(coalesce(g.id_zona,''))) = v_zona
      and g.tipo in ('SALIDA_ZONA','SALIDA_JEFATURA')
      and g.estado in ('CERRADA','AUTOCERRADA')
      and g.fecha >= now() - make_interval(days => v_dias)
      and exists (select 1 from wh.guia_detalle d where d.id_guia = g.id_guia and coalesce(d.cant_recibida,0) > 0)
      and not exists (select 1 from me.zona_traslado_verificacion v where v.id_guia = 'WH:' || g.id_guia)
  ) s;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'zona', v_zona, 'dias', v_dias,
      'total', jsonb_array_length(v_items),
      'items', v_items)) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_traslados_pendientes(jsonb) from public;
grant execute on function me.zona_traslados_pendientes(jsonb) to service_role, authenticated;

-- ── 2) INTERNAS = guías de la zona (me.guias_cabecera) — informativas, sin diff ─────────────────────────────
create or replace function me.zona_guias_internas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_dias  int  := greatest(1, coalesce((p->>'dias')::int, 30));
  v_items jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  select coalesce(jsonb_agg(t order by t->>'fecha' desc), '[]'::jsonb) into v_items
  from (
    select jsonb_build_object(
        'idGuia',       g.id_guia,
        'origen',       'INTERNAL',
        'tipoGuia',     g.tipo,
        'estadoGuia',   coalesce(g.estado,''),
        'fecha',        g.fecha,
        'vendedor',     coalesce(nullif(btrim(g.vendedor),''),'—'),
        'observacion',  coalesce(g.observacion,''),
        'zonaDestino',  coalesce(g.zona_destino,''),
        'lineas',       (select count(*) from me.guias_detalle d where d.id_guia = g.id_guia),
        'totalEnviado', (select coalesce(sum(d.cantidad),0) from me.guias_detalle d where d.id_guia = g.id_guia),
        'edadSeg',      floor(extract(epoch from (now() - g.fecha)))::bigint,
        'edadLbl',      me._edad_lbl(now() - g.fecha),
        'detalle', (
          select coalesce(jsonb_agg(jsonb_build_object(
              'linea',       d.linea,
              'codBarra',    d.cod_barras,
              'descripcion', coalesce(pr.descripcion, d.cod_barras),
              'enviado',     coalesce(d.cantidad,0),
              'escaneado',   0,
              'dif',         coalesce(d.cantidad,0),
              'estado',      'INFO'
            ) order by d.linea), '[]'::jsonb)
          from me.guias_detalle d
          left join mos.productos pr on pr.codigo_barra = d.cod_barras
          where d.id_guia = g.id_guia
        )
      ) as t
    -- [Rep#3] cap de 150 guías más recientes: SALIDA_VENTAS (1 por cierre de caja) infla el total a 260+;
    -- 150 es suficiente para la vista informativa sin sobrecargar el render del modal.
    from (
      select * from me.guias_cabecera
      where zona_id = v_zona and fecha >= now() - make_interval(days => v_dias)
      order by fecha desc nulls last
      limit 150
    ) g
  ) s;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'zona', v_zona, 'dias', v_dias,
      'total', jsonb_array_length(v_items),
      'items', v_items)) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_guias_internas(jsonb) from public;
grant execute on function me.zona_guias_internas(jsonb) to service_role, authenticated;

-- ── 3) WRAPPER mos.* (profile 'mos' del frontend) para la nueva interna ──────────────────────────────────────
create or replace function mos.zona_guias_internas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_guias_internas(p);
end; $fn$;
revoke all on function mos.zona_guias_internas(jsonb) from public;
grant execute on function mos.zona_guias_internas(jsonb) to service_role, authenticated;

notify pgrst, 'reload schema';
