-- 140_me_kardex_zona.sql — KARDEX CENTRALIZADO · FUNDACIÓN de ZONA (esquema me) — ADITIVO / INERTE
-- Diseño: supabase/DISENO_kardex_centralizado.md
--
-- ── QUÉ HACE ───────────────────────────────────────────────────────────────────────────────────────────────
--   1) Re-alinea me.stock_movimientos a la PLANTILLA única (zona+almacén) — la tabla está VACÍA (0 filas),
--      así que se DROPEA y RECREA con el esquema nuevo (cod_barra/saldo_antes/saldo_despues/ref_*/local_id/...).
--   2) Agrega me.guias_detalle.cantidad_aplicada (default 0) — soporte anti-duplicado por cierre de guía.
--   3) RPC me.zona_kardex_registrar(p)  — escritura idempotente de un movimiento (INERTE: nadie la llama aún).
--   4) RPC me.zona_kardex_historial(p)  — lectura, shape paritario con getHistorialStock de WH; RECONSTRUYE
--      el historial desde guias/ventas/auditorias cuando el kardex aún no tiene movimientos materializados.
--   5) Wrappers mos.zona_kardex_historial / mos.zona_kardex_registrar — para que el frontend (profile 'mos')
--      las alcance (patrón 132_riz_wrappers_mos).
--
-- ── POR QUÉ ES SEGURO (INERTE) ─────────────────────────────────────────────────────────────────────────────
--   · me.stock_movimientos está VACÍA y nunca se activó (kardex de zona jamás encendido) → recrearla no pierde
--     datos ni rompe lecturas (nadie la lee hoy). El backfill de Fase 1 nunca la llenó.
--   · cantidad_aplicada es columna nueva con default 0 → el cierre de guía actual (que NO la usa) sigue igual.
--   · La RPC de registro NO se cablea a ningún flujo en esta entrega.
--   · La RPC de historial es SOLO LECTURA (reconstruye, no escribe).
--   · No toca WH (ni tabla ni RPC ni flujo). No toca flags/sync/cerrar_guia/dinero.
--
-- ── GATES ──────────────────────────────────────────────────────────────────────────────────────────────────
--   mos._claim_ok() (app='MOS' o service_role/GAS) en wrappers + RPCs me.*; _frescura_sombra() en lecturas.
--   security definer + search_path='' + revoke public + grants service_role/authenticated (patrón del proyecto).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create schema if not exists mos;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) PLANTILLA — me.stock_movimientos (recrear; estaba vacía). Esquema único zona+almacén.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
drop table if exists me.stock_movimientos cascade;
create table me.stock_movimientos (
  id            bigserial primary key,
  ambito        text        not null default 'ZONA',     -- ZONA | ALMACEN (en este esquema siempre ZONA)
  zona_id       text,                                      -- NOT NULL en la práctica para zona; check abajo
  cod_barra     text        not null,
  id_lote       text,                                      -- trazabilidad FIFO (nullable)
  tipo          text        not null,                      -- catálogo: INGRESO_GUIA/SALIDA_VENTA/SALIDA_JEFA/
                                                           --   TRASLADO_IN/TRASLADO_OUT/AJUSTE/AUDITORIA/ENVASADO/INICIAL
  delta         numeric(20,3) not null,                    -- + entra / − sale
  saldo_antes   numeric(20,3),
  saldo_despues numeric(20,3),
  ref_tipo      text,                                      -- GUIA | VENTA | AJUSTE | AUDITORIA | ENVASADO | TRASLADO
  ref_id        text,                                      -- GUIA:<id>:<linea>:v<n> | VENTA:<id>:<linea> | AJUSTE:<id> | AUDITORIA:<id>:<cod>
  usuario       text,
  fecha         timestamptz not null default now(),        -- fecha de NEGOCIO
  origen        text,                                       -- ME-PWA | GAS | etc.
  local_id      text,                                       -- idempotencia de reintentos offline
  created_at    timestamptz not null default now()
);

-- Índices de lectura (historial por código+zona, orden fecha) + reconciliación.
create index ix_me_kardex_cb_zona_fecha on me.stock_movimientos (cod_barra, zona_id, fecha desc, id desc);
create index ix_me_kardex_zona_fecha    on me.stock_movimientos (zona_id, fecha desc);
create index ix_me_kardex_ref           on me.stock_movimientos (ref_id);

-- Idempotencia (anti-duplicado):
--   (a) por evento de negocio: un ref_id no se aplica dos veces dentro del mismo (ambito, zona_id).
--   (b) por reintento offline: un local_id no se inserta dos veces.
create unique index uq_me_kardex_ref      on me.stock_movimientos (ambito, coalesce(zona_id,''), ref_id)
  where ref_id is not null;
create unique index uq_me_kardex_localid  on me.stock_movimientos (local_id)
  where local_id is not null;

-- RLS como el resto de me.* (service_role bypassa; anon/authenticated sin grant a tabla = bloqueado).
alter table me.stock_movimientos enable row level security;

grant usage on schema me to service_role, anon, authenticated;
grant all on me.stock_movimientos        to service_role;
grant all on sequence me.stock_movimientos_id_seq to service_role;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2) ANTI-DUPLICADO — me.guias_detalle.cantidad_aplicada (default 0).
--    Soporte para "delta = cantidad_nueva − cantidad_aplicada" al (re)cerrar. Aditivo: el flujo actual lo ignora.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
alter table me.guias_detalle
  add column if not exists cantidad_aplicada numeric(20,3) not null default 0;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 3) me.zona_kardex_registrar(p) — escritura idempotente de un movimiento. INERTE (sin cableo en esta entrega).
--    p = { zona, codBarra, tipo, delta?, nuevoAbsoluto?, refTipo?, refId?, idLote?, usuario?, origen?, localId? }
--    · delta directo  → delta = p.delta  (INGRESO_GUIA/SALIDA_*/TRASLADO_*/ENVASADO).
--    · set absoluto   → si viene nuevoAbsoluto (AJUSTE/AUDITORIA): delta = nuevoAbsoluto − saldo_actual_kardex.
--    Calcula saldo_antes (último saldo_despues del (ambito,zona,cod) o 0) y saldo_despues = saldo_antes + delta.
--    Dedup: on conflict (ref_id) o (local_id) → devuelve {ok:true, dedup:true, data:<fila existente>}.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_kardex_registrar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_cod    text := btrim(coalesce(p->>'codBarra',''));
  v_tipo   text := upper(btrim(coalesce(p->>'tipo','')));
  v_reft   text := nullif(upper(btrim(coalesce(p->>'refTipo',''))),'');
  v_refid  text := nullif(btrim(coalesce(p->>'refId','')),'');
  v_lote   text := nullif(btrim(coalesce(p->>'idLote','')),'');
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_local  text := nullif(btrim(coalesce(p->>'localId','')),'');
  v_has_abs boolean := (p ? 'nuevoAbsoluto') and (p->>'nuevoAbsoluto') is not null;
  v_abs    numeric(20,3);
  v_delta  numeric(20,3);
  v_antes  numeric(20,3);
  v_desp   numeric(20,3);
  v_row    me.stock_movimientos%rowtype;
  v_exist  me.stock_movimientos%rowtype;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_cod = '' or v_tipo = '' then
    return jsonb_build_object('ok',false,'error','Requiere zona, codBarra y tipo');
  end if;

  -- Dedup temprana por clave de negocio o local_id (idempotente sin tocar nada).
  if v_refid is not null then
    select * into v_exist from me.stock_movimientos
      where ambito='ZONA' and coalesce(zona_id,'')=v_zona and ref_id=v_refid limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_exist)); end if;
  end if;
  if v_local is not null then
    select * into v_exist from me.stock_movimientos where local_id=v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_exist)); end if;
  end if;

  -- saldo actual del kardex = saldo_despues del último movimiento (o 0).
  select coalesce(saldo_despues,0) into v_antes
    from me.stock_movimientos
   where ambito='ZONA' and coalesce(zona_id,'')=v_zona and cod_barra=v_cod
   order by fecha desc, id desc limit 1;
  v_antes := coalesce(v_antes,0);

  -- delta: directo o derivado de set absoluto (AJUSTE/AUDITORIA).
  if v_has_abs then
    v_abs   := (p->>'nuevoAbsoluto')::numeric;
    v_delta := v_abs - v_antes;        -- §3: delta = nuevo_absoluto − saldo_actual
    if v_reft is null then v_reft := case when v_tipo='AUDITORIA' then 'AUDITORIA' else 'AJUSTE' end; end if;
  else
    if (p->>'delta') is null then
      return jsonb_build_object('ok',false,'error','Requiere delta o nuevoAbsoluto');
    end if;
    v_delta := (p->>'delta')::numeric;
  end if;
  v_desp := v_antes + v_delta;

  -- ref_tipo por defecto a partir del tipo si no vino.
  if v_reft is null then
    v_reft := case
      when v_tipo like 'INGRESO%' then 'GUIA'
      when v_tipo = 'SALIDA_VENTA' then 'VENTA'
      when v_tipo = 'SALIDA_JEFA' then 'GUIA'
      when v_tipo like 'TRASLADO%' then 'TRASLADO'
      when v_tipo = 'ENVASADO' then 'ENVASADO'
      else v_tipo end;
  end if;

  insert into me.stock_movimientos
    (ambito, zona_id, cod_barra, id_lote, tipo, delta, saldo_antes, saldo_despues,
     ref_tipo, ref_id, usuario, fecha, origen, local_id)
  values
    ('ZONA', v_zona, v_cod, v_lote, v_tipo, v_delta, v_antes, v_desp,
     v_reft, v_refid, v_user, now(), v_origen, v_local)
  on conflict do nothing
  returning * into v_row;

  -- on conflict do nothing no devuelve fila → re-leer la existente (dedup ganada por carrera).
  if v_row.id is null then
    if v_refid is not null then
      select * into v_row from me.stock_movimientos
        where ambito='ZONA' and coalesce(zona_id,'')=v_zona and ref_id=v_refid limit 1;
    elsif v_local is not null then
      select * into v_row from me.stock_movimientos where local_id=v_local limit 1;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_row));
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'data',to_jsonb(v_row));
end;
$fn$;
revoke all on function me.zona_kardex_registrar(jsonb) from public;
grant execute on function me.zona_kardex_registrar(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 4) me.zona_kardex_historial(p) — LECTURA. Shape paritario con getHistorialStock de WH.
--    p = { zona, codBarra | skuBase, incluirGuiasVenta? }
--    · Si HAY movimientos materializados → los lee directo (saldo = dato).
--    · Si NO hay → RECONSTRUYE desde me.auditorias + me.guias_detalle⋈cabecera + me.ventas_detalle⋈ventas,
--      en orden fecha, calculando saldo corrido (ancla en la auditoría set-absoluto más reciente).
--    Anti-doble-conteo guía-vs-venta: por defecto las guías SALIDA_VENTAS son informativas (aplicado:false,
--    no suman al saldo); ventas_detalle es la fuente de SALIDA_VENTA. incluirGuiasVenta=true las muestra igual.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- Tipo de evento de la reconstrucción (orden de campos = orden del array_agg de la CTE 'eventos').
do $$ begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
                 where n.nspname='me' and t.typname='_kardex_evento') then
    create type me._kardex_evento as (
      fecha     timestamptz,
      tipo      text,
      delta     numeric,
      saldo_set numeric,
      es_set    boolean,
      aplicado  boolean,
      usuario   text,
      id_guia   text,
      fuente    text
    );
  end if;
end $$;

create or replace function me.zona_kardex_historial(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_cod    text := nullif(btrim(coalesce(p->>'codBarra','')),'');
  v_sku    text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_incg   boolean := coalesce((p->>'incluirGuiasVenta')::boolean, false);
  v_codes  text[];                 -- conjunto de códigos a consultar (1 por codBarra; N por skuBase)
  v_n_mat  int := 0;
  v_movs   jsonb := '[]'::jsonb;
  v_recon  boolean := false;
  -- reconstrucción procedural (saldo corrido con re-ancla en set-absoluto):
  v_ev     me._kardex_evento[];
  v_e      me._kardex_evento;
  v_run    numeric(20,3);
  v_antes  numeric(20,3);
  v_sal    numeric(20,3);
  v_acc    jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  -- Resolver el conjunto de cod_barra a consultar.
  -- ⚠ sku_base NO es único en mos.productos (canónico/presentación/derivado comparten sku_base),
  --   por eso un skuBase se expande a TODOS sus codigo_barra (igual que el grupo multi-barcode de WH).
  if v_cod is not null then
    v_codes := array[v_cod];
  elsif v_sku is not null then
    select coalesce(array_agg(distinct pr.codigo_barra), array[]::text[]) into v_codes
      from mos.productos pr where pr.sku_base = v_sku and pr.codigo_barra is not null;
    if coalesce(array_length(v_codes,1),0) = 0 then
      return jsonb_build_object('ok',false,'error','skuBase sin codigo_barra en catálogo');
    end if;
    v_cod := v_codes[1];   -- representativo para el shape de respuesta
  else
    return jsonb_build_object('ok',false,'error','Requiere codBarra o skuBase');
  end if;

  -- ── Rama 1: movimientos materializados ───────────────────────────────────────────────────────────────────
  select count(*) into v_n_mat from me.stock_movimientos
    where ambito='ZONA' and coalesce(zona_id,'')=v_zona and cod_barra = any(v_codes);

  if v_n_mat > 0 then
    select coalesce(jsonb_agg(jsonb_build_object(
        'idGuia',        case when m.ref_tipo='GUIA' then split_part(m.ref_id,':',2) else '' end,
        'fecha',         m.fecha,
        'tipo',          me._kardex_label(m.tipo, m.delta),
        'tipoOperacion', m.tipo,
        'esIngreso',     (m.delta > 0),
        'cantidad',      abs(m.delta),
        'saldo',         m.saldo_despues,
        'stockAntes',    m.saldo_antes,
        'usuario',       coalesce(m.usuario,'—'),
        'origen',        coalesce(m.origen,''),
        'estado',        'CERRADA',
        'fuente',        case when m.tipo in ('AJUSTE','AUDITORIA') then 'ajuste' else 'guia' end,
        'aplicado',      true,
        'idLote',        m.id_lote
      ) order by m.fecha desc, m.id desc), '[]'::jsonb) into v_movs
    from me.stock_movimientos m
    where m.ambito='ZONA' and coalesce(m.zona_id,'')=v_zona and m.cod_barra = any(v_codes);
  else
    -- ── Rama 2: RECONSTRUCCIÓN (kardex vacío) ────────────────────────────────────────────────────────────
    v_recon := true;
    with eventos as (
      -- AUDITORIA (set absoluto → saldo se clava a cant_real; delta = diferencia firmada)
      select a.fecha,
             'AUDITORIA'::text          as tipo,
             (a.cant_real - a.cant_sistema) as delta,
             a.cant_real                as saldo_set,   -- ancla de saldo
             true                       as es_set,
             true                       as aplicado,
             coalesce(a.vendedor,'—')   as usuario,
             ''                         as id_guia,
             'auditoria'                as fuente
        from me.auditorias a
       where a.zona_id = v_zona and a.cod_barras = any(v_codes)
      union all
      -- GUÍAS: SALIDA_* = −cantidad, entradas = +cantidad. SALIDA_VENTAS → informativa por defecto.
      select gc.fecha,
             case
               when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%' then 'TRASLADO_IN'
               when gc.tipo = 'SALIDA_JEFA' then 'SALIDA_JEFA'
               when gc.tipo like '%MOVIMIENTO%' or gc.tipo like 'TRASLADO%' then 'TRASLADO_OUT'
               when gc.tipo = 'SALIDA_VENTAS' then 'SALIDA_VENTA'
               else 'SALIDA_JEFA'
             end as tipo,
             case when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%'
                  then gd.cantidad else -gd.cantidad end as delta,
             null::numeric as saldo_set,
             false as es_set,
             -- SALIDA_VENTAS informativa (no suma) salvo incluirGuiasVenta=true
             case when gc.tipo = 'SALIDA_VENTAS' and not v_incg then false else true end as aplicado,
             coalesce(gc.vendedor,'—') as usuario,
             gc.id_guia as id_guia,
             'guia' as fuente
        from me.guias_detalle gd
        join me.guias_cabecera gc on gc.id_guia = gd.id_guia
       where gc.zona_id = v_zona and gd.cod_barras = any(v_codes)
      union all
      -- VENTAS (no anuladas) = SALIDA_VENTA −cantidad
      select v.fecha,
             'SALIDA_VENTA'::text as tipo,
             -vd.cantidad         as delta,
             null::numeric        as saldo_set,
             false                as es_set,
             true                 as aplicado,
             coalesce(v.vendedor,'—') as usuario,
             v.id_venta           as id_guia,
             'venta'              as fuente
        from me.ventas_detalle vd
        join me.ventas v on v.id_venta = vd.id_venta
       where v.zona_id = v_zona and vd.cod_barras = any(v_codes)
         and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
    )
    -- ordenar cronológicamente: dentro de un mismo instante, el set-absoluto (auditoría) va al FINAL
    -- (clava el saldo tras los movimientos de ese momento). Cast a tipo nombrado para el FOREACH.
    select array_agg(
             row((e).fecha,(e).tipo,(e).delta,(e).saldo_set,(e).es_set,(e).aplicado,(e).usuario,(e).id_guia,(e).fuente)::me._kardex_evento
             order by (e).fecha asc, case when (e).es_set then 1 else 0 end, (e).tipo)
           into v_ev
      from eventos e;

    -- ── Saldo corrido PROCEDURAL con RE-ANCLA en cada set-absoluto ────────────────────────────────────────
    --   · evento aplicado normal: saldo += delta.
    --   · set-absoluto (AUDITORIA/AJUSTE): saldo := cant_real (re-ancla la base; ignora la suma previa).
    --   · evento informativo (aplicado=false, p.ej. guía SALIDA_VENTAS duplicada): NO mueve el saldo;
    --     se muestra con stockAntes=saldo y saldo=saldo (sin efecto), para auditar sin descuadrar.
    v_run := 0;
    if v_ev is not null then
      foreach v_e in array v_ev loop
        v_antes := v_run;
        if (v_e).es_set then
          v_run := (v_e).saldo_set;                 -- re-ancla
          v_sal := v_run;
        elsif (v_e).aplicado then
          v_run := v_run + (v_e).delta;             -- acumula
          v_sal := v_run;
        else
          v_sal := v_run;                            -- informativo: saldo sin cambio
        end if;
        v_acc := v_acc || jsonb_build_object(
          'idGuia',        (v_e).id_guia,
          'fecha',         (v_e).fecha,
          'tipo',          me._kardex_label((v_e).tipo, (v_e).delta),
          'tipoOperacion', (v_e).tipo,
          'esIngreso',     ((v_e).delta > 0),
          'cantidad',      abs((v_e).delta),
          'saldo',         v_sal,
          'stockAntes',    v_antes,
          'usuario',       (v_e).usuario,
          'origen',        '',
          'estado',        'CERRADA',
          'fuente',        case when (v_e).tipo in ('AJUSTE','AUDITORIA') then 'ajuste' else (v_e).fuente end,
          'aplicado',      (v_e).aplicado,
          'idLote',        null);
      end loop;
    end if;
    -- v_acc está en orden cronológico asc; el shape WH es fecha DESC → invertir.
    select coalesce(jsonb_agg(elem order by ord desc), '[]'::jsonb) into v_movs
      from jsonb_array_elements(v_acc) with ordinality as t(elem, ord);
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cod, 'codBarras', to_jsonb(v_codes), 'skuBase', v_sku,
      'reconstruido', v_recon, 'totalMovimientos', jsonb_array_length(v_movs),
      'movimientos', v_movs)) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_kardex_historial(jsonb) from public;
grant execute on function me.zona_kardex_historial(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 4b) me._kardex_label(tipo, delta) — clasificador de UI compartido (espeja _clasificar de getHistorialStock).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me._kardex_label(p_tipo text, p_delta numeric)
returns text
language sql
immutable
as $fn$
  select case
    when p_tipo = 'AUDITORIA'                  then 'Auditoría ' || case when p_delta >= 0 then 'INC' else 'DEC' end
    when p_tipo = 'AJUSTE'                      then 'Ajuste '    || case when p_delta >= 0 then 'INC' else 'DEC' end
    when p_tipo = 'INICIAL'                     then 'INICIAL'
    when p_tipo = 'ENVASADO'                    then case when p_delta >= 0 then 'INGRESO ENVASADO' else 'SALIDA ENVASADO' end
    when p_tipo = 'SALIDA_VENTA'                then 'SALIDA (venta)'
    when p_tipo = 'SALIDA_JEFA'                 then 'SALIDA (jefa)'
    when p_tipo = 'TRASLADO_IN'                 then 'INGRESO (traslado)'
    when p_tipo = 'TRASLADO_OUT'                then 'SALIDA (traslado)'
    when p_tipo like 'INGRESO%'                 then 'INGRESO'
    else case when p_delta >= 0 then 'INGRESO' else 'SALIDA' end
  end;
$fn$;
revoke all on function me._kardex_label(text, numeric) from public;
grant execute on function me._kardex_label(text, numeric) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 5) WRAPPERS mos.* (profile 'mos' del frontend) — pass-through con gate, patrón 132.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.zona_kardex_historial(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_kardex_historial(p);
end;
$fn$;
revoke all on function mos.zona_kardex_historial(jsonb) from public;
grant execute on function mos.zona_kardex_historial(jsonb) to service_role, authenticated;

create or replace function mos.zona_kardex_registrar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_kardex_registrar(p);
end;
$fn$;
revoke all on function mos.zona_kardex_registrar(jsonb) from public;
grant execute on function mos.zona_kardex_registrar(jsonb) to service_role, authenticated;
