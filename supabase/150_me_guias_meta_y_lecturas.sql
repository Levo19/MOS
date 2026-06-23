-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 150_me_guias_meta_y_lecturas.sql
-- GUÍAS de MosExpress 100% Supabase: METADATA de guías escrita en Supabase + LECTURAS desde Supabase.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- CONTEXTO (cutover): el dueño activó ME_ESCRITURA_STOCK_DIRECTA=1 y ME_SYNC_OFF_TABLAS=stock_zonas,
--   guias_cabecera,guias_detalle (el sync Hoja→Supabase está APAGADO para esas tablas). El STOCK ya va directo
--   (me.zona_descontar_venta / me.zona_registrar_guia escriben me.stock_zonas + kardex). PERO la METADATA de la
--   guía (cabecera/detalle) ya NO llega a Supabase (la escribían solo a la Hoja + el sync ahora apagado).
--   Este archivo cierra ese hueco con:
--     1) me.zona_guia_registrar_meta(p) — graba SOLO metadata cabecera+detalle. NUNCA toca me.stock_zonas ni kardex.
--        (el stock lo aplican las RPCs de stock ya cableadas → grabar meta NO re-aplica saldo = SIN doble conteo).
--     2) 3 RPCs de LECTURA con el SHAPE EXACTO que el frontend ya consume (listarGuias/detalleGuia/trasladosEntrantes).
--
-- INVARIANTE MONEY-SAFETY: me.zona_guia_registrar_meta SOLO hace INSERT/UPSERT en me.guias_cabecera y
--   me.guias_detalle. No referencia me.stock_zonas ni me.zona_kardex en ningún punto. Verificable por grep.
-- IDEMPOTENCIA: reaplicar el MISMO idGuia (reintento de cola) no duplica:
--   · cabecera → on conflict (id_guia) do update SOLO de estado/observacion/ultima_actividad (no re-inserta fila).
--   · detalle  → delete de las líneas de ese id_guia + re-insert con linea = row_number → mismo conjunto, sin duplicar.
--
-- Idempotente (create or replace · if not exists), security definer, search_path='', revoke public, grant
-- service_role + authenticated. Gate me._claim_zona_ok() (acepta '' GAS/service_role · 'MOS' · 'mosExpress').
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

-- me.guias_cabecera ya tiene la columna ultima_actividad en algunas instancias; garantizamos su existencia
-- (el cutover MOS/lecturas la usa para ordenar/auditar). Si ya existe, no-op.
alter table me.guias_cabecera add column if not exists ultima_actividad timestamptz;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) me.zona_guia_registrar_meta(p) — METADATA ONLY (cabecera + detalle). NO stock, NO kardex.
--    Params: idGuia (req), zona (req), tipo (req), fecha?, vendedor?, observacion?, zonaDestino?,
--            estado? (default 'CONFIRMADO'), items:[{codBarra,cantidad}] (opcional; si vacío solo cabecera).
--    Devuelve {ok, idGuia, lineas}.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_guia_registrar_meta(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text        := btrim(coalesce(p->>'idGuia',''));
  v_zona   text        := upper(btrim(coalesce(p->>'zona','')));
  v_tipo   text        := upper(btrim(coalesce(p->>'tipo','')));
  v_user   text        := nullif(btrim(coalesce(p->>'vendedor', p->>'usuario','')),'');
  v_obs    text        := nullif(coalesce(p->>'observacion',''),'');
  v_zdest  text        := upper(nullif(btrim(coalesce(p->>'zonaDestino', p->>'zona_destino','')),''));
  v_estado text        := upper(coalesce(nullif(btrim(coalesce(p->>'estado','')),''),'CONFIRMADO'));
  v_fecha  timestamptz;
  v_items  jsonb       := coalesce(p->'items', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_lin    int := 0;
  v_n      int := 0;
  v_valid  int := 0;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' or v_zona = '' or v_tipo = '' then
    return jsonb_build_object('ok',false,'error','Requiere idGuia, zona y tipo');
  end if;

  -- fecha: usar la enviada (epoch ms o ISO) o now() si no vino / no parsea.
  begin
    if (p->>'fecha') is not null and btrim(p->>'fecha') <> '' then
      if (p->>'fecha') ~ '^[0-9]+$' then
        v_fecha := to_timestamp((p->>'fecha')::bigint / 1000.0);
      else
        v_fecha := (p->>'fecha')::timestamptz;
      end if;
    else
      v_fecha := now();
    end if;
  exception when others then
    v_fecha := now();
  end;

  -- CABECERA idempotente: insertar si nueva; si ya existe NO pisar fecha/vendedor/zona/tipo (la primera escritura
  -- es la fuente de verdad de esos campos) — solo refrescar estado/observacion/ultima_actividad (reintentos/cierres).
  insert into me.guias_cabecera (id_guia, fecha, vendedor, zona_id, tipo, observacion, zona_destino, estado, ultima_actividad)
    values (v_id, v_fecha, v_user, v_zona, v_tipo, v_obs, v_zdest, v_estado, now())
  on conflict (id_guia) do update
    set estado           = excluded.estado,
        observacion      = coalesce(excluded.observacion, me.guias_cabecera.observacion),
        ultima_actividad = now();

  -- DETALLE idempotente. DOS blindajes money/data-safety (revisión 40x):
  --   🔴-2: solo borrar+reinsertar si hay AL MENOS UNA línea válida. Un items vacío/inválido NO debe borrar el
  --         detalle bueno (pérdida de datos en un reintento con payload corrupto). Si no hay líneas válidas →
  --         solo se actualizó la cabecera, el detalle existente queda intacto.
  --   🔴-1: cantidad_aplicada = cantidad. El saldo ya lo aplicó zona_registrar_guia/zona_descontar_venta al crear
  --         la guía; marcar aplicada=cantidad hace que cerrar_guia_zona_idempotente calcule delta 0 → SKIP → NO
  --         re-aplica stock (anti-doble-conteo si la guía se reabre y el autocierre la cierra). Espeja el sync viejo.
  select count(*) into v_valid
    from jsonb_array_elements(v_items) e
   where upper(btrim(coalesce(e->>'codBarra', e->>'cod_barras', e->>'cod_barra',''))) <> ''
     and coalesce((e->>'cantidad')::numeric, 0) > 0;

  if v_valid > 0 then
    delete from me.guias_detalle where id_guia = v_id;
    for v_e in select * from jsonb_array_elements(v_items) loop
      v_cb   := upper(btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barras', v_e->>'cod_barra', '')));
      v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
      if v_cb = '' or v_cant <= 0 then continue; end if;
      v_lin := v_lin + 1;
      insert into me.guias_detalle (id_guia, linea, cod_barras, cantidad, cantidad_aplicada)
        values (v_id, v_lin, v_cb, v_cant, v_cant)
      on conflict (id_guia, linea) do update
        set cod_barras = excluded.cod_barras, cantidad = excluded.cantidad,
            cantidad_aplicada = excluded.cantidad_aplicada;
      v_n := v_n + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'idGuia', v_id, 'lineas', v_n);
end;
$fn$;
revoke all on function me.zona_guia_registrar_meta(jsonb) from public;
grant execute on function me.zona_guia_registrar_meta(jsonb) to service_role, authenticated;

-- wrapper mos.* (profile 'mos') — pass-through con gate (consistente con las otras zona_*).
create or replace function mos.zona_guia_registrar_meta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_guia_registrar_meta(p);
end; $fn$;
revoke all on function mos.zona_guia_registrar_meta(jsonb) from public;
grant execute on function mos.zona_guia_registrar_meta(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2a) me.zona_guias_listar(p {zona}) — LECTURA. where zona_id=zona OR zona_destino=zona, orden fecha desc.
--     SHAPE por fila idéntico a listarGuias (gas/Guias.gs ~1078): id_guia, fecha, vendedor, zona, tipo,
--     observacion, zona_destino, estado. Devuelve {ok, guias:[...]}.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_guias_listar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona text := upper(btrim(coalesce(p->>'zona','')));  -- 🟠-4: normalizar a MAYÚSCULAS (zona_id/destino se guardan upper)
  v_out  jsonb;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id_guia',      gc.id_guia,
      'fecha',        gc.fecha,
      'vendedor',     coalesce(gc.vendedor,''),
      'zona',         coalesce(gc.zona_id,''),
      'tipo',         coalesce(gc.tipo,''),
      'observacion',  coalesce(gc.observacion,''),
      'zona_destino', coalesce(gc.zona_destino,''),
      'estado',       coalesce(gc.estado,'')
    ) order by gc.fecha desc nulls last), '[]'::jsonb)
  into v_out
  from me.guias_cabecera gc
  where gc.zona_id = v_zona or gc.zona_destino = v_zona;

  return jsonb_build_object('ok', true, 'guias', v_out);
end;
$fn$;
revoke all on function me.zona_guias_listar(jsonb) from public;
grant execute on function me.zona_guias_listar(jsonb) to service_role, authenticated;

create or replace function mos.zona_guias_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_guias_listar(p);
end; $fn$;
revoke all on function mos.zona_guias_listar(jsonb) from public;
grant execute on function mos.zona_guias_listar(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2b) me.zona_guia_detalle(p {idGuia}) — LECTURA. items [{cod_barras, cantidad}] (SHAPE de detalleGuia ~1104).
--     Devuelve {ok, items:[...]}.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_guia_detalle(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_id  text := btrim(coalesce(p->>'idGuia', p->>'id_guia',''));
  v_out jsonb;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'cod_barras', coalesce(gd.cod_barras,''),
      'cantidad',   coalesce(gd.cantidad, 0)
    ) order by gd.linea), '[]'::jsonb)
  into v_out
  from me.guias_detalle gd
  where gd.id_guia = v_id;

  return jsonb_build_object('ok', true, 'items', v_out);
end;
$fn$;
revoke all on function me.zona_guia_detalle(jsonb) from public;
grant execute on function me.zona_guia_detalle(jsonb) to service_role, authenticated;

create or replace function mos.zona_guia_detalle(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_guia_detalle(p);
end; $fn$;
revoke all on function mos.zona_guia_detalle(jsonb) from public;
grant execute on function mos.zona_guia_detalle(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2c) me.zona_traslados_entrantes(p {zona, desde}) — LECTURA. tipo='ENTRADA_TRASLADO' & zona_id=zona &
--     fecha > desde (epoch ms; default ahora-24h, igual que el GAS). SHAPE de trasladosEntrantes (~1126):
--     id_guia, fecha, origen (= zona_destino, que en la entrada-espejo guarda la zona ORIGEN), observacion.
--     Devuelve {ok, traslados:[...]}.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_traslados_entrantes(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona  text := btrim(coalesce(p->>'zona',''));
  v_desde timestamptz;
  v_raw   text := btrim(coalesce(p->>'desde',''));
  v_out   jsonb;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  -- desde: epoch ms (como lo manda el GAS); fallback ahora-24h (idéntico a trasladosEntrantes).
  begin
    if v_raw <> '' and v_raw ~ '^[0-9]+$' then
      v_desde := to_timestamp(v_raw::bigint / 1000.0);
    elsif v_raw <> '' then
      v_desde := v_raw::timestamptz;
    else
      v_desde := now() - interval '24 hours';
    end if;
  exception when others then
    v_desde := now() - interval '24 hours';
  end;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id_guia',     gc.id_guia,
      'fecha',       gc.fecha,
      'origen',      coalesce(gc.zona_destino,''),
      'observacion', coalesce(gc.observacion,'')
    ) order by gc.fecha desc nulls last), '[]'::jsonb)
  into v_out
  from me.guias_cabecera gc
  where gc.tipo = 'ENTRADA_TRASLADO'
    and gc.zona_id = v_zona
    and gc.fecha > v_desde;

  return jsonb_build_object('ok', true, 'traslados', v_out);
end;
$fn$;
revoke all on function me.zona_traslados_entrantes(jsonb) from public;
grant execute on function me.zona_traslados_entrantes(jsonb) to service_role, authenticated;

create or replace function mos.zona_traslados_entrantes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_traslados_entrantes(p);
end; $fn$;
revoke all on function mos.zona_traslados_entrantes(jsonb) from public;
grant execute on function mos.zona_traslados_entrantes(jsonb) to service_role, authenticated;
