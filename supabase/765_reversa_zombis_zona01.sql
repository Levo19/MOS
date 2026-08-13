-- 765 · REVERSA de líneas zombis ZONA-01 (13-ago-2026). Ver 764 para la causa.
-- 5 líneas duplicadas (68 unidades) detectadas por censo: misma marca de escaneo
-- (created_at idéntico al milisegundo) facturada en DOS guías:
--   G-ayer-15:01  línea 43: 7758725000036A x5   (zombi del despacho 12:58)
--   G-hoy-08:21   línea 1:  WH-9S7XBPX     x1   (zombi del despacho ayer 15:01)
--   G-hoy-08:21   línea 5:  7750346000013  x60  (ídem)
--   G-hoy-08:21   línea 6:  WHPAARDA250GR  x1   (ídem)
--   G-hoy-08:21   línea 7:  WHQUNEUM500GR  x1   (ídem)
-- Reversa por línea: stock WH devuelto + kardex AJUSTE + línea retirada del documento
-- + lotes de la zona consumidos de vuelta (best-effort, patrón devolución).
-- Deuda del acumulado (reconstruida pedido-a-pedido de la semana):
--   quinua +1 · pasa +1 · nuez +1 · wantan +4 · spaghetti REAPARECE con 24
-- (la marca zombi consumió deuda real dos veces; spaghetti quedó saldado debiendo 24).

do $do$
declare
  z record;
  v_antes numeric; v_despues numeric;
  v_items jsonb;
  v_movfix jsonb;
  v_ts_lima text := to_char(now() at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI');
begin
  -- ═══ 1) por línea zombi: stock + kardex + retirar línea + lote zona ═══
  for z in
    select * from (values
      ('GPCK_PCK-ACU-ZONA-01-2026-08-09_20260812_150116_7510', 43, '7758725000036A', 5::numeric),
      ('GPCK_PCK-ACU-ZONA-01-2026-08-09_20260813_082149_a6eb',  1, 'WH-9S7XBPX',     1),
      ('GPCK_PCK-ACU-ZONA-01-2026-08-09_20260813_082149_a6eb',  5, '7750346000013', 60),
      ('GPCK_PCK-ACU-ZONA-01-2026-08-09_20260813_082149_a6eb',  6, 'WHPAARDA250GR',  1),
      ('GPCK_PCK-ACU-ZONA-01-2026-08-09_20260813_082149_a6eb',  7, 'WHQUNEUM500GR',  1)
    ) t(guia, linea, cod, cant)
  loop
    -- la línea debe existir aún (si ya se corrió esta reversa, abortar TODO)
    if not exists (select 1 from wh.guia_detalle where id_guia = z.guia and linea = z.linea
                     and cod_producto = z.cod and wh._num(cant_recibida::text) = z.cant) then
      raise exception 'REV765: línea % de % no coincide o ya fue revertida — no se aplica nada', z.linea, z.guia;
    end if;

    update wh.stock
       set cantidad_disponible = cantidad_disponible + z.cant, ultima_actualizacion = now()
     where id_stock = (select id_stock from wh.stock where cod_producto = z.cod order by id_stock limit 1)
     returning cantidad_disponible into v_despues;
    if not found then
      raise exception 'REV765: sin fila de stock para %', z.cod;
    end if;
    v_antes := v_despues - z.cant;

    insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
    values ('MOVID_REV765_' || z.guia || '#' || z.linea, now(), z.cod, z.cant, v_antes, v_despues,
            'AJUSTE_REVERSA_DUPLICADO', z.guia, 'reversa-765')
    on conflict (id_mov) do nothing;

    delete from wh.guia_detalle where id_guia = z.guia and linea = z.linea;

    update wh.guias
       set comentario = coalesce(comentario,'') || ' [REV765: retirada línea duplicada ' || z.cod
                        || ' x' || z.cant || ' — marca zombi de un despacho anterior; stock devuelto]'
     where id_guia = z.guia;

    -- lotes de la zona: consumir de vuelta lo heredado de más (blindado, patrón devolución)
    begin
      perform me.zona_consumir_fefo_cod('ZONA-01', z.cod, z.cant, 'reversa duplicado ' || z.guia);
    exception when others then
      raise notice 'REV765: lote zona no revertido para % (%): %', z.cod, z.cant, SQLERRM;
    end;

    raise notice 'REV765 stock: % +% → % (antes %)', z.cod, z.cant, v_despues, v_antes;
  end loop;

  -- ═══ 2) deuda del acumulado: devolver lo que la marca zombi consumió dos veces ═══
  select items into v_items from wh.pickups where id_pickup = 'PCK-ACU-ZONA-01-2026-08-09' for update;
  if v_items is null then raise exception 'REV765: acumulado no encontrado'; end if;

  v_movfix := jsonb_build_array(jsonb_build_object(
    'ts', v_ts_lima, 'ref', 'REV765', 'cant', 0, 'tipo', 'ajuste',
    'origen', 'reversa deuda consumida por marca zombi'));

  select coalesce(jsonb_agg(
    case
      when e.value->>'skuBase' = 'LEV1436'    -- quinua +1
        then jsonb_set(e.value, '{solicitado}', to_jsonb(wh._num(coalesce(e.value->>'solicitado','0')) + 1))
             || jsonb_build_object('mov', coalesce(e.value->'mov','[]'::jsonb)
                || jsonb_build_array(jsonb_build_object('ts',v_ts_lima,'ref','REV765','cant',1,'tipo','ajuste','origen','reversa marca zombi')))
      when e.value->>'skuBase' = 'LEV1427'    -- pasa +1
        then jsonb_set(e.value, '{solicitado}', to_jsonb(wh._num(coalesce(e.value->>'solicitado','0')) + 1))
             || jsonb_build_object('mov', coalesce(e.value->'mov','[]'::jsonb)
                || jsonb_build_array(jsonb_build_object('ts',v_ts_lima,'ref','REV765','cant',1,'tipo','ajuste','origen','reversa marca zombi')))
      when e.value->>'skuBase' = 'LEV0002398' -- nuez +1
        then jsonb_set(e.value, '{solicitado}', to_jsonb(wh._num(coalesce(e.value->>'solicitado','0')) + 1))
             || jsonb_build_object('mov', coalesce(e.value->'mov','[]'::jsonb)
                || jsonb_build_array(jsonb_build_object('ts',v_ts_lima,'ref','REV765','cant',1,'tipo','ajuste','origen','reversa marca zombi')))
      when e.value->>'skuBase' = 'LEV182'     -- wantan +4
        then jsonb_set(e.value, '{solicitado}', to_jsonb(wh._num(coalesce(e.value->>'solicitado','0')) + 4))
             || jsonb_build_object('mov', coalesce(e.value->'mov','[]'::jsonb)
                || jsonb_build_array(jsonb_build_object('ts',v_ts_lima,'ref','REV765','cant',4,'tipo','ajuste','origen','reversa marca zombi')))
      else e.value
    end), '[]'::jsonb)
    into v_items from jsonb_array_elements(v_items) e;

  -- spaghetti LEV153: quedó saldado de más — reaparece con la deuda real (24)
  if not exists (select 1 from jsonb_array_elements(v_items) e where e.value->>'skuBase' = 'LEV153') then
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'skuBase', 'LEV153',
      'nombre', 'MAXIMO FIDEO SPAGHETTI 500GR BOLSA',
      'solicitado', 24,
      'despachado', 0,
      'tsSolicitud', (select to_char(fecha_creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')
                        from wh.pickups where id_pickup = 'PK-VENTAS-CAJA-1786364632794'),
      'codigosOriginales', jsonb_build_array('7750346000013'),
      'mov', jsonb_build_array(jsonb_build_object(
        'ts', v_ts_lima, 'ref', 'REV765', 'cant', 24, 'tipo', 'ajuste',
        'origen', 'reversa marca zombi: pedido 84 − despacho real 60'))));
  else
    raise exception 'REV765: LEV153 ya existe en el acumulado — revisar antes de reaplicar';
  end if;

  update wh.pickups set items = v_items, ultima_actividad = now()
   where id_pickup = 'PCK-ACU-ZONA-01-2026-08-09';

  raise notice 'REV765 deuda: quinua +1, pasa +1, nuez +1, wantan +4, spaghetti reaparece x24';
end;
$do$;
