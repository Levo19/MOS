-- 131_riz_lotes_zona.sql — [RIZ · CAPA 3 · MAQUINARIA DE LOTES DE ZONA (FIFO, perecibles) — INERTE]
-- Módulo de Reposición Inteligente por Zona (RIZ). Diseño: DISENO_modulo_reposicion_zona.md
-- (DECISIÓN RONDA 2 #11 "lotización/FIFO en zona", tabla [E] me.zona_lotes 1.4, card lote 3.3-bis).
--
-- ⚠️⚠️ INERTE — NADIE LLAMA ESTO TODAVÍA ⚠️⚠️
--   · me.zona_recibir_lote   → la llamará el DESPACHO WH→zona en el futuro (ver TODO documentado al final). HOY
--                              no la invoca cerrar_guia ni nada → CERO efecto en producción.
--   · me.zona_consumir_fifo  → la llamará la VENTA en zona en el futuro. HOY nadie la llama → CERO efecto.
--   · me.zona_lotes_historial→ lectura para el card 3.3-bis. No la cablea el frontend aún.
--   NO se toca wh.cerrar_guia (RPC de DINERO en prod, 35_wh_cerrar_guia.sql). NO se toca api.js/sw.js/version.json/
--   GAS/flags/sync. Pura definición SQL sobre la tabla [E] (creada inerte en 127_riz_tablas.sql).
--
-- ── MODELO (tabla [E] me.zona_lotes) ────────────────────────────────────────────────────────────────────────
--   "Libro de lotes" de la zona. PK (zona_id, sku_base, id_lote). Cada ingreso desde almacén hereda
--   id_lote + fecha_vencimiento de wh.guia_detalle. cant_restante baja con la venta FIFO (vto más próximo primero).
--   me.stock_zonas sigue siendo el TOTAL por barra; me.zona_lotes es el DESGLOSE por lote. La suma de cant_restante
--   de un sku debería cuadrar con su stock_zona (el card 3.3-bis lo muestra). Esta capa solo mantiene el libro de
--   lotes; NO escribe me.stock_zonas (eso lo hace zona_ajustar_stock / el sync). Así no hay doble verdad de stock.
--
-- ── PATRÓN: security definer · search_path='' · gate mos._claim_ok() · shape {ok:true,data:...} camelCase. ─────
--   recibir/consumir son idempotentes/atómicas (UPDATE atómico de cant_restante, nunca read-modify-write — misma
--   lección que wh.cerrar_guia §95: evitar lost-update concurrente).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) me.zona_recibir_lote(p jsonb { zona (req), skuBase|codBarra (req uno), idLote (req), fechaVencimiento?,
--                                   cantidad (req >0), idGuiaOrigen? })
--    Inserta/acumula un ingreso de lote en me.zona_lotes (hereda lote + vencimiento). INERTE (la llamará el
--    despacho WH→zona — ver TODO al final).
--    IDEMPOTENCIA por (zona, idLote, idGuiaOrigen): si el MISMO lote del MISMO origen ya ingresó → NO re-acumula
--    (devuelve dedup). Si el lote re-ingresa con OTRO id_guia_origen (reposición distinta) → ACUMULA cant_ingresada
--    y cant_restante sobre la fila existente (PK = zona+sku+lote). El control de no-duplicar el mismo despacho lo
--    da la combinación (id_lote, id_guia_origen) guardada en la fila.
--    skuBase: si viene codBarra y no skuBase, se resuelve el skuBase del catálogo (canónico/equivalente).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_recibir_lote(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona  text    := upper(btrim(coalesce(p->>'zona','')));
  v_sku   text    := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_cb    text    := nullif(upper(btrim(coalesce(p->>'codBarra',''))), '');
  v_lote  text    := nullif(btrim(coalesce(p->>'idLote','')), '');
  v_fvenc text    := nullif(btrim(coalesce(p->>'fechaVencimiento','')), '');
  v_cant  numeric := nullif(btrim(coalesce(p->>'cantidad','')), '')::numeric;
  v_guia  text    := nullif(btrim(coalesce(p->>'idGuiaOrigen','')), '');
  v_venc  timestamptz;
  v_guia_existente text;
  v_restante numeric;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_lote is null or v_cant is null or v_cant <= 0 then
    return jsonb_build_object('ok',false,'error','Requiere zona, idLote y cantidad (>0)');
  end if;
  if v_sku is null and v_cb is null then
    return jsonb_build_object('ok',false,'error','Requiere skuBase o codBarra');
  end if;

  -- resolver skuBase desde codBarra si hace falta (catálogo: presentación propia o equivalente).
  if v_sku is null then
    select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) into v_sku
      from mos.productos pr where upper(btrim(pr.codigo_barra)) = v_cb limit 1;
    if v_sku is null then
      select e.sku_base into v_sku from mos.equivalencias e
        where upper(btrim(e.codigo_barra)) = v_cb and coalesce(e.activo,true) limit 1;
    end if;
    if v_sku is null then
      return jsonb_build_object('ok',false,'error','codBarra '||v_cb||' no resuelve a un skuBase');
    end if;
  end if;

  -- vencimiento. null → sin vencimiento. Una fecha pura ('yyyy-MM-dd') se ancla a MEDIANOCHE LIMA (no UTC) para
  -- que el round-trip `(fecha at time zone 'America/Lima')::date` devuelva la MISMA fecha (evita off-by-one de TZ).
  -- Si viene un timestamp completo, se respeta tal cual.
  if v_fvenc is not null then
    if left(btrim(v_fvenc),10) = btrim(v_fvenc) and btrim(v_fvenc) ~ '^\d{4}-\d{2}-\d{2}$' then
      v_venc := (btrim(v_fvenc)::date::timestamp) at time zone 'America/Lima';   -- medianoche Lima
    else
      begin v_venc := v_fvenc::timestamptz; exception when others then
        v_venc := (nullif(left(v_fvenc,10),'')::date::timestamp) at time zone 'America/Lima'; end;
    end if;
  end if;

  -- IDEMPOTENCIA: ¿esta fila (zona+sku+lote) ya registró ESTE id_guia_origen? → dedup (no re-acumular el mismo despacho).
  select id_guia_origen, cant_restante into v_guia_existente, v_restante
    from me.zona_lotes
   where zona_id = v_zona and sku_base = v_sku and id_lote = v_lote
   for update;

  if found and v_guia is not null and v_guia_existente = v_guia then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object(
      'zona',v_zona,'skuBase',v_sku,'idLote',v_lote,'cantRestante',v_restante));
  end if;

  -- insertar o acumular (PK zona+sku+lote). UPDATE atómico de cantidades (suma), reactivar si estaba AGOTADO.
  insert into me.zona_lotes as zl
    (zona_id, sku_base, id_lote, cod_barras, fecha_vencimiento, cant_ingresada, cant_restante, fecha_ingreso, id_guia_origen, estado)
  values
    (v_zona, v_sku, v_lote, v_cb, v_venc, v_cant, v_cant, now(), v_guia, 'ACTIVO')
  on conflict (zona_id, sku_base, id_lote) do update set
    cant_ingresada    = zl.cant_ingresada + excluded.cant_ingresada,
    cant_restante     = zl.cant_restante  + excluded.cant_ingresada,   -- acumula sobre lo restante
    fecha_vencimiento = coalesce(excluded.fecha_vencimiento, zl.fecha_vencimiento),
    cod_barras        = coalesce(excluded.cod_barras, zl.cod_barras),
    id_guia_origen    = coalesce(excluded.id_guia_origen, zl.id_guia_origen),
    estado            = 'ACTIVO'
  returning cant_restante into v_restante;

  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object(
    'zona',v_zona,'skuBase',v_sku,'idLote',v_lote,'cantIngresada',v_cant,'cantRestante',v_restante,
    'fechaVencimiento', case when v_venc is null then null else to_char((v_venc at time zone 'America/Lima')::date,'YYYY-MM-DD') end));
end;
$fn$;
revoke all on function me.zona_recibir_lote(jsonb) from public;
grant execute on function me.zona_recibir_lote(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) me.zona_consumir_fifo(p jsonb { zona (req), skuBase (req), cantidad (req >0) })
--    Descuenta cant_restante de me.zona_lotes en orden FIFO (fecha_vencimiento más próxima primero; null al final).
--    INERTE (la venta en zona la llamará después). Atómico por fila (UPDATE ... set cant_restante = cant_restante -
--    consumir; no read-modify-write). Si la cantidad pedida excede el total restante, consume lo que hay y reporta
--    'sobrante' (lo no cubierto por lotes) — NO bloquea (paridad con wh.cerrar_guia §162: huérfano se ignora).
--    Marca AGOTADO el lote cuyo restante llega a 0.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_consumir_fifo(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona     text    := upper(btrim(coalesce(p->>'zona','')));
  v_sku      text    := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_cant     numeric := nullif(btrim(coalesce(p->>'cantidad','')), '')::numeric;
  v_restante numeric;
  v_consumir numeric;
  v_consumido numeric := 0;
  v_aplicados jsonb := '[]'::jsonb;
  r_lote     record;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_sku is null or v_cant is null or v_cant <= 0 then
    return jsonb_build_object('ok',false,'error','Requiere zona, skuBase y cantidad (>0)');
  end if;

  v_restante := v_cant;
  -- FIFO: vence primero → sale primero. nulls last (sin vencimiento al final). for update → serializa ventas concurrentes.
  for r_lote in
    select id_lote, cant_restante from me.zona_lotes
     where zona_id = v_zona and sku_base = v_sku and coalesce(cant_restante,0) > 0
     order by fecha_vencimiento asc nulls last, fecha_ingreso asc, id_lote asc
     for update
  loop
    exit when v_restante <= 0;
    v_consumir := least(r_lote.cant_restante, v_restante);
    update me.zona_lotes
       set cant_restante = cant_restante - v_consumir,
           estado = case when (cant_restante - v_consumir) <= 0 then 'AGOTADO' else 'ACTIVO' end
     where zona_id = v_zona and sku_base = v_sku and id_lote = r_lote.id_lote;
    v_restante  := v_restante - v_consumir;
    v_consumido := v_consumido + v_consumir;
    v_aplicados := v_aplicados || jsonb_build_object('idLote', r_lote.id_lote, 'consumido', v_consumir);
  end loop;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'zona',v_zona,'skuBase',v_sku,'pedido',v_cant,'consumido',v_consumido,
    'sobrante', greatest(v_restante,0),                       -- pedido no cubierto por lotes (huérfano informativo)
    'lotesAfectados', v_aplicados));
end;
$fn$;
revoke all on function me.zona_consumir_fifo(jsonb) from public;
grant execute on function me.zona_consumir_fifo(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) me.zona_lotes_historial(p jsonb { zona (req), skuBase (req) })  — lectura para el card 3.3-bis.
--    Lista de ingresos FIFO (el de arriba se vende primero) + vencimientoProximo + díasRestantes.
--    items: [{ idLote, fechaIngreso, fechaVencimiento, cantIngresada, cantRestante, idGuiaOrigen, estado, diasRestantes }]
--    ordenados FIFO. totalRestante (debería cuadrar con stock_zona del sku). Gate _fresh (|| mos._frescura_sombra()).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_lotes_historial(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona text := upper(btrim(coalesce(p->>'zona','')));
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_hoy  date := (now() at time zone 'America/Lima')::date;
  v_data jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_sku is null then
    return jsonb_build_object('ok',false,'error','Requiere zona y skuBase');
  end if;

  with l as (
    select * from me.zona_lotes
     where zona_id = v_zona and sku_base = v_sku
     order by fecha_vencimiento asc nulls last, fecha_ingreso asc, id_lote asc
  ),
  -- vencimiento más próximo entre lotes que aún tienen stock (lo que alerta el card).
  prox as (
    select min(fecha_vencimiento) as venc from l where coalesce(cant_restante,0) > 0 and fecha_vencimiento is not null
  )
  select jsonb_build_object(
    'zona', v_zona, 'skuBase', v_sku,
    'totalRestante', coalesce((select sum(coalesce(cant_restante,0)) from l), 0),
    'vencimientoProximo', case when (select venc from prox) is null then null else jsonb_build_object(
        'fecha', to_char(((select venc from prox) at time zone 'America/Lima')::date,'YYYY-MM-DD'),
        'dias', (((select venc from prox) at time zone 'America/Lima')::date - v_hoy)) end,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'idLote', l.id_lote,
        'fechaIngreso', to_char((l.fecha_ingreso at time zone 'America/Lima')::date,'YYYY-MM-DD'),
        'fechaVencimiento', case when l.fecha_vencimiento is null then null
          else to_char((l.fecha_vencimiento at time zone 'America/Lima')::date,'YYYY-MM-DD') end,
        'diasRestantes', case when l.fecha_vencimiento is null then null
          else ((l.fecha_vencimiento at time zone 'America/Lima')::date - v_hoy) end,
        'cantIngresada', l.cant_ingresada,
        'cantRestante', l.cant_restante,
        'idGuiaOrigen', l.id_guia_origen,
        'estado', l.estado
      )) from l), '[]'::jsonb)
  ) into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_lotes_historial(jsonb) from public;
grant execute on function me.zona_lotes_historial(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- ╔═══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║  TODO DOCUMENTADO (NO IMPLEMENTADO) — cómo conectar wh.cerrar_guia → me.zona_recibir_lote en el FUTURO.    ║
-- ║  ⚠️ NO TOCAR wh.cerrar_guia aquí. Esto es solo el mapa para que el dueño lo revise y active aparte.        ║
-- ╚═══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
--
-- CONTEXTO. wh.cerrar_guia (supabase/35_wh_cerrar_guia.sql) es la RPC de DINERO/INVENTARIO que cierra una guía:
--   aplica el delta de stock de WH y sincroniza/consume lotes de wh.lotes_vencimiento. Recorre los detalles en el
--   bucle `for v_d in select jsonb_array_elements(p->'detalles') loop` (35_wh_cerrar_guia.sql:84), donde por cada
--   línea ya tiene a mano EXACTAMENTE lo que me.zona_recibir_lote necesita:
--       v_cod   (codigo_producto)          ← 35:85
--       v_cant  (cantidad_recibida)        ← 35:86
--       v_idlote / v_idlotenew (id_lote)   ← 35:88 / 35:92
--       v_fvenc (fecha_vencimiento yyyy-MM-dd) ← 35:89-90
--   y la cabecera tiene v_id (id_guia) y wh.guias.id_zona (la zona DESTINO del despacho; columna confirmada en el
--   schema vivo de wh.guias).
--
-- DÓNDE / QUÉ AGREGAR (en el FUTURO, dentro de wh.cerrar_guia — NO ahora):
--   Justo DESPUÉS de aplicar el lote de WH dentro de ese bucle — es decir, tras el bloque de "lotes" que termina
--   en la línea 35_wh_cerrar_guia.sql:163 (`end if;` del `if v_ingreso and v_fvenc ... elsif ... elsif not v_ingreso`)
--   y ANTES del `end loop;` de la línea 164 — insertar una llamada CONDICIONAL al destino-zona. Pseudocódigo:
--
--     -- [FUTURO RIZ] propagar el lote a la ZONA destino (solo INGRESO a una zona, con lote+vencimiento).
--     if v_ingreso and v_zona_destino is not null then            -- v_zona_destino := nullif(btrim((select id_zona from wh.guias where id_guia=v_id)),'')
--       perform me.zona_recibir_lote(jsonb_build_object(
--         'zona',             v_zona_destino,
--         'codBarra',         v_cod,                                -- me.zona_recibir_lote resuelve el skuBase
--         'idLote',           coalesce(nullif(v_idlote,''), v_idlotenew),
--         'fechaVencimiento', v_fvenc,                              -- ya viene 'yyyy-MM-dd' (35:90)
--         'cantidad',         v_cant,                               -- cantidad_recibida que entra a la zona
--         'idGuiaOrigen',     v_id));
--     end if;
--
-- POR QUÉ ES SEGURO ACTIVARLO ASÍ (cuando se decida):
--   · me.zona_recibir_lote es IDEMPOTENTE por (zona, idLote, idGuiaOrigen) → re-cerrar/reintentar la MISMA guía NO
--     duplica el lote en zona (igual candado que el early-return idempotente de cerrar_guia, 35:66-69).
--   · NO escribe me.stock_zonas (solo el libro de lotes [E]) → no entra en conflicto con el sync ME ni con
--     zona_ajustar_stock. La regla "una sola verdad de stock" se mantiene; los lotes son el desglose informativo.
--   · `perform` (no asignación) → su retorno se ignora; si fallara, conviene envolverlo en un sub-bloque
--     begin/exception/null para que un problema del libro de lotes NUNCA tumbe el cierre de guía (que es dinero).
--
-- PRECONDICIONES / DECISIONES PENDIENTES (para el dueño, antes de activar):
--   1. ¿wh.guias.id_zona se POBLA hoy con la zona destino en los despachos WH→zona? Verificar en datos reales antes
--      de cablear (si está vacío en la mayoría de guías de despacho, definir de dónde sale la zona destino).
--   2. ¿El despacho WH→zona pasa por wh.cerrar_guia (tipo INGRESO con id_zona), o por otra ruta (pickup atendido /
--      Envasados)? Si va por otra ruta, el punto de inserción cambia (ej. el endpoint que marca el pickup ATENDIDO).
--   3. Factor/unidades: zona vende en unidades base; confirmar que v_cant del despacho ya está en la unidad que la
--      zona maneja (o normalizar por factor al recibir, como hace me._riz_ventas_base).
--   → Dejar este cableo para una sesión dedicada de cutover (revisión 40x sobre una RPC de dinero).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
