-- 146_me_recibir_guia_wh.sql — RECEPCIÓN WH→ME POR ESCANEO DE GUÍA (esquema me) — ADITIVO / INERTE-AL-STOCK
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- App de DINERO/inventario. Construye SOBRE 140 (kardex me.stock_movimientos) + 141 (me.zona_traslado_verificacion).
-- BUILD 1 del PLAN_zona_ME_supabase.md — "Recepción WH→ME por escaneo (el flujo del dueño)".
--
-- ── EL FLUJO (dueño) ─────────────────────────────────────────────────────────────────────────────────────────
--   1. El almacén central (WH) emite una guía SALIDA_ZONA hacia una zona ME e imprime un ticket con el idGuiaWH.
--   2. El operario ME (Tools → "Recibir guía de almacén") escanea/teclea ese idGuiaWH.
--   3. me.recibir_guia_wh(idGuiaWH) LEE wh.guias + wh.guia_detalle (los productos + cant_recibida DESPACHADA por
--      WH) y precarga el detalle para el escaneo. (≠ me.zona_traslado_guia, que lee guías ME ENTRADA_* del schema
--      me; ESTA lee guías WH del schema wh — el vínculo WH→ME que el plan dice "NO EXISTE hoy".)
--   4. El operario escanea PRODUCTO POR PRODUCTO (no ve la cantidad esperada, solo cuenta lo físico).
--   5. "Cerrar ingreso" → me.recibir_guia_wh_cerrar(idGuiaWH, escaneados[]) compara ENVIADO (la guía WH) vs
--      ESCANEADO (real), registra el kardex (TRASLADO_IN) + la verificación en me.zona_traslado_verificacion.
--      Las DISCREPANCIAS las verá el admin en MOS (esa UI ya existe; lee zona_traslado_verificacion).
--
-- ── POR QUÉ NUEVAS RPCs (y no reusar 141 directo) ────────────────────────────────────────────────────────────
--   · Origen de datos: el detalle ENVIADO vive en wh.guia_detalle (cant_recibida), NO en me.guias_detalle. La
--     guía WH no existe como fila en me.guias_cabecera → me.zona_traslado_cerrar (141) no la encuentra. Esta RPC
--     lee la guía WH y persiste la verificación bajo un id sintético 'WH:<idGuiaWH>' (no colisiona con ids ME).
--   · GATE de caller: las RPCs 141/144 (me.zona_traslado_*) gatean con mos._claim_ok() = claim app ∈ {'', 'MOS'}.
--     El token de la PWA ME mintea app='mosExpress' (Fase2Auth.gs:395) → mos._claim_ok()=FALSE para ME. Por eso
--     estas RPCs nuevas (las que llama la PWA ME) usan me._claim_zona_ok() = claim ∈ {'', 'MOS', 'mosExpress'}.
--     Las 141/144 NO se tocan (su gate y su comportamiento de stock quedan idénticos).
--
-- ── GATE / INERTE AL STOCK REAL (⚠ EL PUNTO CLAVE) ──────────────────────────────────────────────────────────
--   Igual que 141: lo ESCANEADO se registra en el KARDEX (trazabilidad, idempotente) + la VERIFICACIÓN, pero el
--   SALDO operativo me.stock_zonas NO se toca — bloque [GATE-STOCK · INERTE] con v_aplicar_stock := false. El
--   dueño lo desbloquea (=> true) DESPUÉS de validar el cierre de venta y de apagar el sync de stock_zonas. Hasta
--   entonces sirve de red de seguridad (registra discrepancias sin mover saldo). El UPDATE de saldo, cuando se
--   active, es ATÓMICO (suma delta), nunca read-modify-write (lección WH = lost-update).
--
-- ── POR QUÉ ES SEGURO ───────────────────────────────────────────────────────────────────────────────────────
--   · Solo LEE wh.guias/wh.guia_detalle (no escribe nada en wh). El kardex es la tabla 140 (vacía/inactiva) →
--     escribir TRASLADO_IN no descuadra ningún saldo vivo. me.stock_zonas NO se toca (gate INERTE).
--   · Idempotente por id_guia sintético 'WH:<idGuiaWH>' (PK de me.zona_traslado_verificacion) + por refId de
--     kardex (uq_me_kardex_ref). Recibir/recerrar la misma guía no duplica nada.
--   · No toca catálogo, flags MOS_*, sync, cerrar_guia, dinero. security definer + search_path='' + revoke public.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create schema if not exists mos;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 0) me._claim_zona_ok() — gate de las RPCs de ZONA que llama la PWA ME (claim app='mosExpress').
--    Superconjunto de mos._claim_ok(): acepta '' (GAS/service_role) · 'MOS' (PWA MOS) · 'mosExpress' (PWA ME).
--    Rechaza cualquier otro (p.ej. 'warehouseMos'). Mismo patrón que mos._claim_ok / wh._claim_ok.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me._claim_zona_ok()
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(me.jwt_app(), '') in ('', 'MOS', 'mosExpress');
$fn$;
revoke all on function me._claim_zona_ok() from public;
grant execute on function me._claim_zona_ok() to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) me.recibir_guia_wh(p {idGuiaWH}) — LECTURA: precarga el detalle de una guía SALIDA_ZONA de WH para escanear.
--    Lee wh.guias (cabecera) + wh.guia_detalle (líneas, cant_recibida = lo DESPACHADO). Enriquece cada línea con
--    la descripción del catálogo (mos.productos por codigo_barra). Devuelve también si ya fue verificada (idem).
--    NOTA: el front NO muestra 'enviado' al operario (solo cuenta), pero la RPC lo devuelve para la comparación.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.recibir_guia_wh(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_id   text := btrim(coalesce(p->>'idGuiaWH', p->>'idGuia', ''));
  v_g    wh.guias%rowtype;
  v_ref  text;
  v_ver  me.zona_traslado_verificacion%rowtype;
  v_zona text := upper(btrim(coalesce(p->>'zona','')));   -- opcional: zona ME que recibe (si el cliente la sabe)
  v_lineas jsonb;
  v_nlin int;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuiaWH'); end if;

  select * into v_g from wh.guias where id_guia = v_id;
  if not found then return jsonb_build_object('ok',false,'error','Guía WH no encontrada: '||v_id); end if;

  -- id sintético de la verificación ME para esta guía WH (no colisiona con ids de guías ME).
  v_ref := 'WH:'||v_id;
  select * into v_ver from me.zona_traslado_verificacion where id_guia = v_ref;

  -- líneas DESPACHADAS por WH (cant_recibida): el operario contará contra esto al cerrar. Excluye anuladas y 0.
  -- Incluye lote/vencimiento (control de inventario en recepción): id_lote + fecha_vencimiento de la línea WH.
  select coalesce(jsonb_agg(jsonb_build_object(
      'linea',       d.linea,
      'codBarra',    d.cod_producto,
      'descripcion', coalesce(pr.descripcion, d.cod_producto),
      'enviado',     coalesce(d.cant_recibida, 0),
      'lote',        nullif(btrim(coalesce(d.id_lote,'')), ''),
      'venc',        d.fecha_vencimiento
    ) order by d.linea), '[]'::jsonb), count(*)::int
  into v_lineas, v_nlin
  from wh.guia_detalle d
  left join lateral (select descripcion from mos.productos pr where pr.codigo_barra = d.cod_producto limit 1) pr on true
  where d.id_guia = v_id
    and nullif(btrim(coalesce(d.cod_producto,'')),'') is not null
    and coalesce(d.cant_recibida,0) <> 0
    and upper(coalesce(d.observacion,'')) <> 'ANULADO';

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'idGuiaWH',     v_g.id_guia,
      'refVerif',     v_ref,
      'tipoGuia',     v_g.tipo,
      'estadoWH',     v_g.estado,
      'zonaWH',       v_g.id_zona,          -- la zona destino que WH grabó (informativo)
      'zonaRecibe',   nullif(v_zona,''),    -- la zona ME que el cliente declara (puede diferir del label WH)
      'fecha',        v_g.fecha,
      'usuario',      coalesce(v_g.usuario,'—'),
      'comentario',   coalesce(v_g.comentario,''),
      'lineas',       v_nlin,
      'verificada',   (v_ver.id_guia is not null),
      'verificacion', case when v_ver.id_guia is not null then to_jsonb(v_ver) else null end,
      'detalle',      v_lineas)) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.recibir_guia_wh(jsonb) from public;
grant execute on function me.recibir_guia_wh(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2) me.recibir_guia_wh_cerrar(p {idGuiaWH, zona, escaneados:[{codBarra,cantidad}], usuario?, origen?}) — CIERRE.
--    Espeja me.zona_traslado_cerrar (141) pero con el ENVIADO leído de wh.guia_detalle y un id sintético 'WH:<id>'.
--    · Idempotente por id sintético: si ya hay verificación → {ok:true, dedup:true, data:<existente>}.
--    · Registra cada ESCANEADO en el kardex (TRASLADO_IN, ref por línea WH o por código suelto).
--    · Compara ENVIADO (guía WH) vs ESCANEADO (real) → COMPLETO/INCOMPLETO + detalle por producto.
--    · Persiste la verificación. ⚠ NO toca me.stock_zonas (GATE INERTE, v_aplicar_stock:=false).
--    · La zona de la verificación = p.zona (la zona ME que recibe). Si no vino, cae al id_zona de la guía WH.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
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
  --   (sin esto, re-aplicar 146 revertía el hardening de 175 → "relation _esc_agg already exists" si un
  --   orquestador llamara la RPC 2x en una transacción). Se mantiene aquí como fuente de verdad.
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
  -- Enriquecemos cada producto enviado con lote/vencimiento (control de inventario). Un producto puede venir en
  -- varios lotes dentro de la misma guía → agregamos: 'lote' = lotes distintos no-nulos unidos por '/'; 'venc' =
  -- el vencimiento MÁS PRÓXIMO (min) entre los lotes (lo más conservador para rotación/FEFO).
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

  -- ┌─ [GATE-STOCK · INERTE] ───────────────────────────────────────────────────────────────────────────────┐
  -- │ AQUÍ se aplicaría lo ESCANEADO al SALDO operativo (me.stock_zonas). HOY OFF (v_aplicar_stock=false).    │
  -- │ Para activar tras validación: v_aplicar_stock := true. UPDATE ATÓMICO (suma delta), nunca RMW.          │
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

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 3) WRAPPERS mos.* (profile 'mos' del frontend MOS) — pass-through con gate mos._claim_ok, patrón 132/140/141.
--    Así el ADMIN en MOS también puede precargar/cerrar una recepción WH→ME si hiciera falta.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.recibir_guia_wh(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.recibir_guia_wh(p);
end; $fn$;
revoke all on function mos.recibir_guia_wh(jsonb) from public;
grant execute on function mos.recibir_guia_wh(jsonb) to service_role, authenticated;

create or replace function mos.recibir_guia_wh_cerrar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.recibir_guia_wh_cerrar(p);
end; $fn$;
revoke all on function mos.recibir_guia_wh_cerrar(jsonb) from public;
grant execute on function mos.recibir_guia_wh_cerrar(jsonb) to service_role, authenticated;
