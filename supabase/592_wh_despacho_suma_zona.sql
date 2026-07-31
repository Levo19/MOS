-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 592_wh_despacho_suma_zona.sql — DESPACHO-DRIVEN: el despacho de almacén suma a me.stock_zonas
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- MODELO NUEVO (pedido del dueño): cuando ALMACÉN despacha a una zona (cierra un SALIDA_ZONA), el
-- stock debe SUMAR A LA ZONA de una (`me.stock_zonas`), con etiqueta "despachado". La RECEPCIÓN del
-- vendedor pasa a ser SOLO verificación (2ª capa administrativa) y ya NO suma stock.
--
-- HOY (recepción-driven, ACTIVO): `me.recibir_guia_wh_cerrar` (175) suma a me.stock_zonas lo ESCANEADO.
-- El despacho (`wh.crear_despacho_rapido` 528, + cerrar_guia_idempotente, + el pickup vía GPCK) baja
-- `wh.stock` y escribe `wh.stock_movimientos` (CIERRE_GUIA) pero NO toca me.stock_zonas.
--
-- ⚠️ RIESGO DE DOBLE-CONTEO: si el despacho suma Y la recepción sigue sumando, cada guía DUPLICA el
-- stock de zona. Por eso TODO se controla con UN SOLO flag `WH_DESPACHO_SUMA_ZONA` que flipea ambos
-- atómicamente: ON ⇒ despacho suma + recepción NO suma. DEFAULT '0' (OFF) = comportamiento actual
-- IDÉNTICO (cero regresión). El cutover es cambiar el flag a '1' (ver runbook al pie).
--
-- SEGURO: (1) el despacho suma vía TRIGGER en wh.stock_movimientos (no se redefinen los RPC gigantes
-- money-critical); (2) idempotente: el trigger AFTER INSERT dispara UNA vez por movimiento único
-- (id_mov `MOVID_<guia>#<linea>`, on conflict do nothing) → suma exactamente 1 vez por línea;
-- (3) best-effort: un fallo en la suma de zona NUNCA rompe el despacho (se reconcilia); (4) cubre los
-- 3 caminos de cierre (crear_despacho_rapido, cerrar_guia_idempotente, cerrar_guia) porque los 3
-- escriben CIERRE_GUIA en wh.stock_movimientos.
-- ════════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0) Flag (default OFF = comportamiento actual) ──────────────────────────────────────────────────
insert into mos.config (clave, valor)
values ('WH_DESPACHO_SUMA_ZONA', '0')
on conflict (clave) do nothing;

-- ── 1) Trigger: CIERRE_GUIA de SALIDA_ZONA (salida) → +cantidad a me.stock_zonas de esa zona ───────
create or replace function wh._trg_cierre_suma_zona() returns trigger
language plpgsql security definer set search_path = '' as $trg$
declare
  v_zona text;
  v_tipo text;
  v_qty  numeric;
begin
  -- Filtros baratos primero (sin query): solo salidas de cierre de guía.
  if NEW.tipo_operacion <> 'CIERRE_GUIA' or coalesce(NEW.delta,0) >= 0 then
    return NEW;
  end if;
  -- Flag maestro (OFF por default → no hace nada, comportamiento actual).
  if coalesce((select valor from mos.config where clave = 'WH_DESPACHO_SUMA_ZONA' limit 1), '0') <> '1' then
    return NEW;
  end if;
  -- La guía asociada (origen = id_guia) debe ser SALIDA_ZONA con zona.
  select upper(btrim(coalesce(g.id_zona, ''))), upper(coalesce(g.tipo, ''))
    into v_zona, v_tipo
    from wh.guias g where g.id_guia = NEW.origen;
  if v_tipo is null or v_tipo <> 'SALIDA_ZONA' or coalesce(v_zona, '') = '' or upper(v_zona) = 'ALMACEN' then
    return NEW;
  end if;
  v_qty := -NEW.delta;   -- salida = delta negativo → cantidad POSITIVA que entra a la zona
  if v_qty <= 0 then return NEW; end if;

  -- Suma al saldo operativo de zona (UPSERT atómico; nunca RMW). Idempotente por unicidad del movimiento.
  insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
    values (NEW.cod_producto, v_zona, v_qty, coalesce(nullif(NEW.usuario, ''), 'despacho-almacen'), now())
  on conflict (cod_barras, zona_id) do update
    set cantidad = coalesce(me.stock_zonas.cantidad, 0) + excluded.cantidad,
        usuario = excluded.usuario, fecha_ultimo_registro = now();

  return NEW;
exception when others then
  -- Un fallo acá JAMÁS debe tumbar el despacho (que ya bajó wh.stock). Best-effort; se reconcilia.
  return NEW;
end;
$trg$;

drop trigger if exists trg_cierre_suma_zona on wh.stock_movimientos;
create trigger trg_cierre_suma_zona
  after insert on wh.stock_movimientos
  for each row execute function wh._trg_cierre_suma_zona();

-- ── 2) Recepción: cuando el flag está ON, deja de sumar stock (solo verifica). Copia fiel de 175 con
--       v_aplicar_stock atado al flag. Cuando OFF ⇒ v_aplicar_stock=true (comportamiento actual). ────
create or replace function me.recibir_guia_wh_cerrar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := btrim(coalesce(p->>'idGuiaWH', p->>'idGuia', ''));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'MOS-PWA-ME');
  v_g      wh.guias%rowtype;
  v_ref    text;
  v_exist  me.zona_traslado_verificacion%rowtype;
  v_esc    jsonb := coalesce(p->'escaneados', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_linea  int;
  v_enviado_tot   numeric(20,3) := 0;
  v_escaneado_tot numeric(20,3) := 0;
  v_dif_tot       numeric(20,3) := 0;
  v_ok_n   int := 0;
  v_dif_n  int := 0;
  v_estado text;
  v_detalle jsonb := '[]'::jsonb;
  -- [592] GATE-STOCK invertido por flag: si WH_DESPACHO_SUMA_ZONA='1' (despacho-driven), la recepción
  -- NO suma stock (solo verifica). Si '0' (OFF, default) suma como hoy (recepción-driven). Evita doble-conteo.
  v_aplicar_stock boolean := (coalesce((select valor from mos.config where clave='WH_DESPACHO_SUMA_ZONA' limit 1),'0') <> '1');
  v_row     me.zona_traslado_verificacion%rowtype;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuiaWH'); end if;

  v_ref := 'WH:'||v_id;

  select * into v_exist from me.zona_traslado_verificacion where id_guia = v_ref;
  if found then return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_exist)); end if;

  select * into v_g from wh.guias where id_guia = v_id;
  if not found then return jsonb_build_object('ok',false,'error','Guía WH no encontrada: '||v_id); end if;

  if v_zona = '' then v_zona := upper(btrim(coalesce(v_g.id_zona,''))); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Falta zona (ni en el request ni en la guía WH)'); end if;

  create temp table if not exists _esc_agg (cod_barra text primary key, cant numeric) on commit drop;
  truncate _esc_agg;
  for v_e in select * from jsonb_array_elements(v_esc) loop
    v_cb   := btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barra', ''));
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;
    insert into _esc_agg(cod_barra, cant) values (v_cb, v_cant)
      on conflict (cod_barra) do update set cant = _esc_agg.cant + excluded.cant;
  end loop;

  with envi as (
      select d.cod_producto as cod_barra, min(d.linea) as linea, sum(d.cant_recibida) as enviado,
             nullif(string_agg(distinct nullif(btrim(coalesce(d.id_lote,'')),''), '/'), '') as lote,
             min(d.fecha_vencimiento) as venc
        from wh.guia_detalle d
       where d.id_guia = v_id
         and nullif(btrim(coalesce(d.cod_producto,'')),'') is not null
         and upper(coalesce(d.observacion,'')) <> 'ANULADO'
       group by d.cod_producto
  ),
  uni as (
      select coalesce(en.cod_barra, es.cod_barra) as cod_barra, en.linea as linea,
             coalesce(en.enviado, 0) as enviado, coalesce(es.cant, 0) as escaneado,
             en.lote as lote, en.venc as venc
        from envi en full join _esc_agg es on es.cod_barra = en.cod_barra
  )
  select
      coalesce(sum(enviado),0), coalesce(sum(escaneado),0), coalesce(sum(enviado - escaneado),0),
      coalesce(sum(case when enviado = escaneado then 1 else 0 end),0),
      coalesce(sum(case when enviado <> escaneado then 1 else 0 end),0),
      coalesce(jsonb_agg(jsonb_build_object(
          'codBarra', u.cod_barra, 'descripcion', coalesce(pr.descripcion, u.cod_barra),
          'enviado', u.enviado, 'escaneado', u.escaneado, 'dif', (u.enviado - u.escaneado),
          'lote', u.lote, 'venc', u.venc,
          'estado', case when u.enviado = u.escaneado then 'OK' when u.escaneado < u.enviado then 'FALTA' else 'SOBRA' end
        ) order by (u.enviado - u.escaneado) desc, u.cod_barra), '[]'::jsonb)
  into v_enviado_tot, v_escaneado_tot, v_dif_tot, v_ok_n, v_dif_n, v_detalle
  from uni u
  left join lateral (select descripcion from mos.productos pr where pr.codigo_barra = u.cod_barra limit 1) pr on true;

  v_estado := case when v_dif_n = 0 then 'COMPLETO' else 'INCOMPLETO' end;

  -- KARDEX de zona: se registra SIEMPRE lo escaneado (auditoría de la recepción), independientemente de si
  -- suma o no al saldo (idempotente por ref de línea). Esto NO mueve me.stock_zonas.
  for v_cb, v_cant in select cod_barra, cant from _esc_agg loop
    select min(d.linea) into v_linea from wh.guia_detalle d where d.id_guia = v_id and d.cod_producto = v_cb;
    perform me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN', 'delta', v_cant,
      'refTipo', 'TRASLADO', 'refId', 'TRASLADO-WH:'||v_id||':'||coalesce(v_linea::text, 'X-'||v_cb),
      'usuario', v_user, 'origen', v_origen));
  end loop;

  -- Saldo operativo: SOLO si v_aplicar_stock (flag OFF = recepción suma, como hoy).
  if v_aplicar_stock then
    for v_cb, v_cant in select cod_barra, cant from _esc_agg loop
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_cb, v_zona, v_cant, v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) + excluded.cantidad,
            usuario = excluded.usuario, fecha_ultimo_registro = now();
    end loop;
  end if;

  insert into me.zona_traslado_verificacion
    (id_guia, zona_id, tipo_guia, estado, total_enviado, total_escaneado, total_dif,
     lineas_ok, lineas_dif, detalle, stock_aplicado, usuario, verificado_ts, fecha_guia)
  values
    (v_ref, v_zona, coalesce(v_g.tipo,'SALIDA_ZONA_WH'), v_estado, v_enviado_tot, v_escaneado_tot, v_dif_tot,
     v_ok_n, v_dif_n, v_detalle, v_aplicar_stock, v_user, now(), v_g.fecha)
  on conflict (id_guia) do nothing
  returning * into v_row;

  if v_row.id_guia is null then
    select * into v_row from me.zona_traslado_verificacion where id_guia = v_ref;
    return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_row));
  end if;

  return jsonb_build_object('ok', true, 'dedup', false,
      'stockAplicado', v_aplicar_stock, 'data', to_jsonb(v_row));
end;
$fn$;
revoke all on function me.recibir_guia_wh_cerrar(jsonb) from public;
grant execute on function me.recibir_guia_wh_cerrar(jsonb) to service_role, authenticated;
