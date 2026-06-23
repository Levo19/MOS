-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 175_me_recibir_guia_wh_cerrar_temp_reentrante.sql — HARDENING (revisión 100x, 2026-06-18)
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 🟡 Mismo patrón que el FIX de 148 sobre me.zona_descontar_venta: la temp table `_esc_agg` se creaba con nombre
--    fijo y SIN `if not exists` (+ `on commit drop`). En el path vivo (PostgREST = 1 RPC por transacción) es
--    seguro, PERO si un orquestador llamara me.recibir_guia_wh_cerrar DOS veces dentro de la MISMA transacción,
--    la 2da iteración falla con "relation _esc_agg already exists" (la temp aún no se dropeó — el drop es on commit).
--    FIX simétrico a 148: `create temp table if not exists ... on commit drop` + `truncate` al entrar.
--    Comportamiento del cierre/verificación/stock/kardex IDÉNTICO (sin cambios de negocio). Solo robustez.
--
-- Idempotente (create or replace). NO cambia firma. NO toca otras RPC, flags, sync ni dinero.
-- v_aplicar_stock se conserva en true (go-live 2026-06-17), tal como estaba en la DB.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

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
  v_aplicar_stock boolean := true;    -- ✅ [GATE-STOCK] ACTIVO (2026-06-17 go-live, sync OFF): aplica lo ESCANEADO a me.stock_zonas (UPDATE atómico).
  v_row     me.zona_traslado_verificacion%rowtype;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuiaWH'); end if;

  v_ref := 'WH:'||v_id;

  -- Dedup por guía (idempotente): si ya está verificada, no re-escribe.
  select * into v_exist from me.zona_traslado_verificacion where id_guia = v_ref;
  if found then return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_exist)); end if;

  select * into v_g from wh.guias where id_guia = v_id;
  if not found then return jsonb_build_object('ok',false,'error','Guía WH no encontrada: '||v_id); end if;

  -- zona de la verificación: la declarada por la PWA ME; si no vino, la que WH grabó en la guía.
  if v_zona = '' then v_zona := upper(btrim(coalesce(v_g.id_zona,''))); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Falta zona (ni en el request ni en la guía WH)'); end if;

  -- ── A) Agregar los escaneados por código (sumar). Negativos/0 se ignoran defensivamente. ──────────────────
  -- [175] `if not exists` + `truncate` (espejo de 148): robusto a múltiples llamadas en la MISMA transacción.
  create temp table if not exists _esc_agg (cod_barra text primary key, cant numeric) on commit drop;
  truncate _esc_agg;
  for v_e in select * from jsonb_array_elements(v_esc) loop
    v_cb   := btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barra', ''));
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;
    insert into _esc_agg(cod_barra, cant) values (v_cb, v_cant)
      on conflict (cod_barra) do update set cant = _esc_agg.cant + excluded.cant;
  end loop;

  -- ── B) ENVIADO (wh.guia_detalle.cant_recibida) vs ESCANEADO (real). FULL JOIN capta sobrantes no enviados. ──
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

  -- ── C) KARDEX: cada ESCANEADO como TRASLADO_IN (idempotente por ref de línea WH / código suelto). ──────────
  for v_cb, v_cant in select cod_barra, cant from _esc_agg loop
    select min(d.linea) into v_linea from wh.guia_detalle d where d.id_guia = v_id and d.cod_producto = v_cb;
    perform me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN', 'delta', v_cant,
      'refTipo', 'TRASLADO', 'refId', 'TRASLADO-WH:'||v_id||':'||coalesce(v_linea::text, 'X-'||v_cb),
      'usuario', v_user, 'origen', v_origen));
  end loop;

  -- ┌─ [GATE-STOCK] ─ saldo operativo me.stock_zonas. UPDATE ATÓMICO (suma delta), nunca RMW. ────────────────┐
  if v_aplicar_stock then
    for v_cb, v_cant in select cod_barra, cant from _esc_agg loop
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_cb, v_zona, v_cant, v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) + excluded.cantidad,
            usuario = excluded.usuario, fecha_ultimo_registro = now();
    end loop;
  end if;
  -- └─ /GATE-STOCK ─────────────────────────────────────────────────────────────────────────────────────────┘

  -- ── D) Persistir la verificación (idempotente por id sintético 'WH:<idGuiaWH>'). ──────────────────────────
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
