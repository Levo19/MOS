-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 204_me_cierre_guia_espejo_traslado_y_flag.sql — CUTOVER: guías manuales ME nacen ABIERTA, stock al CERRAR.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- App de DINERO/INVENTARIO. FUNDACIÓN del rediseño de guías ME al modelo de WH (nace ABIERTA, aplica stock UNA
-- SOLA VEZ al CERRAR). Money-safe, ADITIVO y REVERSIBLE por flag. Construye sobre 147 (cerrar_guia_zona_idempotente,
-- reabrir, autocierre) + 150 (metadata) + 202 (zona_registrar_guia con gate anti-doble-conteo, modelo VIEJO).
--
-- ── QUÉ HACE ESTE ARCHIVO (3 cosas) ──────────────────────────────────────────────────────────────────────────
--   (A) Flag de reversibilidad  mos.config.ME_GUIAS_CICLO_ABIERTA  (default '0' = modelo viejo).
--       El GAS lo lee; con '0' las guías nacen CONFIRMADO + aplican stock al crear (zona_registrar_guia, intacto).
--       Con '1' las guías manuales nacen ABIERTA (metadata, cantidad_aplicada=0) y NO aplican stock al crear;
--       el stock lo aplica cerrar_guia_zona_idempotente al cerrar. SALIDA_VENTAS NUNCA cambia (sigue CONFIRMADO,
--       descuenta por caja vía zona_descontar_venta).
--
--   (B) ESPEJO DE TRASLADO AL CIERRE — el fix money-crítico de esta tanda.
--       PROBLEMA: hoy zona_registrar_guia (create-time, modelo viejo) aplica un SALIDA_MOVIMIENTO como OUT en la
--       zona origen + IN espejo en la zona destino, EN UNA SOLA operación atómica. Pero cerrar_guia_zona_idempotente
--       (147) SOLO aplicaba el OUT del origen — NO tocaba el destino. Si moviéramos SALIDA_MOVIMIENTO a ABIERTA+cerrar
--       SIN este fix, el IN del destino se PERDERÍA (stock destino aplicado 0 veces = faltante fantasma permanente).
--       FIX: el cierre, al procesar una línea de un SALIDA_MOVIMIENTO con zona_destino, aplica AMBOS lados:
--            · OUT en zona_id        (kardex ref 'CIERRE-GUIA:<idGuia>:<linea>')
--            · IN  en zona_destino   (kardex ref 'CIERRE-GUIA-IN:<idGuia>:<linea>')   ← espejo
--       Cada lado gateado por el `dedup` de su propio kardex (mismo patrón que zona_registrar_guia / zona_descontar_venta):
--       reintento/doble-tap/recerrar → el kardex deduplica → el saldo NO se vuelve a sumar (anti doble-conteo).
--       El FOR UPDATE de la cabecera serializa cierres concurrentes (cron + manual). cantidad_aplicada=cantidad se
--       marca DESPUÉS de aplicar ambos lados → recerrar da delta 0 → SKIP total → ni OUT ni IN se re-aplican.
--
--   (C) Endurecer cerrar_guia_zona_idempotente para que NO mueva saldo en tipos que NO deben moverlo aquí:
--       SALIDA_VENTAS / SALIDA_VENTA (lo hace zona_descontar_venta por caja → evitar doble-conteo) y
--       ENTRADA_TRASLADO (es el ESPEJO metadata-only de un SALIDA_MOVIMIENTO; su IN ya lo aplica el cierre del
--       SALIDA_MOVIMIENTO origen → cerrar el espejo NO debe re-sumar). Ambos: solo marcan cantidad_aplicada + cierran.
--
-- ── INVARIANTES MONEY-SAFETY (verificadas en rollback, ver REPORTE) ──────────────────────────────────────────
--   1. Crear guía ABIERTA → stock NO se mueve (este archivo NO toca el create path; el GAS no llama zona_registrar_guia
--      cuando el flag está ON). 2. Cerrar → stock UNA vez (OUT + IN espejo si traslado). 3. Recerrar/retry/doble-tap
--      → delta 0 + kardex dedup → 0 aplicaciones extra. 4. Reabrir NO resetea cantidad_aplicada → reabrir+recerrar = 0.
--      5. Guías CONFIRMADO viejas → cantidad_aplicada=cantidad ya (verificado: 5617 detalle alineados) → delta 0, intactas.
--      6. SALIDA_VENTAS → no afectada (no la cierra este flujo; y si se cerrara, no mueve saldo aquí).
--
-- ── SEGURIDAD ────────────────────────────────────────────────────────────────────────────────────────────────
--   security definer · search_path='' · revoke public · grant service_role (+ authenticated en wrappers/cerrar).
--   Gate mos._claim_ok() en cerrar (GAS service_role / PWA-MOS). Idempotente (create or replace). NO toca datos
--   (solo redefine funciones + inserta el flag default). Re-correr = no-op seguro.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create schema if not exists mos;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- (A) FLAG de reversibilidad — default '0' (modelo viejo). El dueño lo pondrá '1' SOLO tras validar.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
insert into mos.config (clave, valor, descripcion) values
  ('ME_GUIAS_CICLO_ABIERTA','0',
   'ME guías manuales: 1=nacen ABIERTA y aplican stock al CERRAR (modelo WH); 0=nacen CONFIRMADO y aplican al crear (viejo). SALIDA_VENTAS nunca cambia.')
on conflict (clave) do nothing;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- (B)+(C) cerrar_guia_zona_idempotente — ahora con ESPEJO DE TRASLADO al cierre + skip de tipos que no mueven saldo aquí.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.cerrar_guia_zona_idempotente(p_id_guia text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id        text := nullif(btrim(coalesce(p_id_guia,'')), '');
  v_estado    text;
  v_tipo      text;
  v_zona      text;
  v_zdest     text;          -- zona destino (solo SALIDA_MOVIMIENTO) → espejo IN
  v_signo_in  boolean;       -- la guía SUMA al saldo (entrada/traslado-in) vs resta (salida)
  v_es_venta  boolean;       -- SALIDA_VENTAS: no mueve saldo aquí (lo hace zona_descontar_venta)
  v_es_trasl_in boolean;     -- ENTRADA_TRASLADO: espejo metadata-only de un SALIDA_MOVIMIENTO → NO re-sumar aquí
  v_es_mov    boolean;       -- SALIDA_MOVIMIENTO con destino → aplicar OUT origen + IN espejo destino
  v_aplicar_stock boolean := true;    -- ✅ [GATE-STOCK] ACTIVO (go-live 2026-06-17, sync OFF).
  v_d         record;
  v_cb        text;
  v_cant      numeric(20,3);
  v_apl       numeric(20,3);
  v_delta     numeric(20,3);
  v_signo     numeric(20,3);
  v_refk      text;
  v_kres      jsonb;          -- resultado del kardex → gatear el saldo por dedup (anti doble-conteo)
  v_aplicadas int := 0;
  v_saltadas  int := 0;
begin
  -- Gate: _claim_zona_ok acepta '' (GAS/service_role), 'MOS' y 'mosExpress' (PWA ME). Superset seguro,
  --   consistente con reabrir_guia_zona / zona_guia_registrar_meta / zona_kardex_registrar. El execute sigue
  --   limitado a service_role (los wrappers me/mos.cerrar_guia_zona, granted a authenticated, son la puerta gated).
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- lock de cabecera: serializa contra cierres concurrentes (doble-tap / cron + manual)
  select estado, tipo, zona_id, zona_destino into v_estado, v_tipo, v_zona, v_zdest
    from me.guias_cabecera where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  v_tipo        := upper(coalesce(v_tipo,''));
  v_zona        := upper(btrim(coalesce(v_zona,'')));
  v_zdest       := upper(nullif(btrim(coalesce(v_zdest,'')),''));
  v_signo_in    := (v_tipo like 'ENTRADA%' or v_tipo like 'TRASLADO_IN%');
  v_es_venta    := (v_tipo = 'SALIDA_VENTAS' or v_tipo = 'SALIDA_VENTA');
  v_es_trasl_in := (v_tipo = 'ENTRADA_TRASLADO');                       -- espejo metadata-only → no mueve saldo aquí
  v_es_mov      := (v_tipo = 'SALIDA_MOVIMIENTO' and v_zdest is not null);

  for v_d in
    select linea, cod_barras, cantidad, cantidad_aplicada
      from me.guias_detalle
     where id_guia = v_id
     order by linea asc nulls last
  loop
    v_cb   := nullif(btrim(coalesce(v_d.cod_barras,'')), '');
    v_cant := coalesce(v_d.cantidad, 0);
    v_apl  := coalesce(v_d.cantidad_aplicada, 0);
    v_delta := v_cant - v_apl;

    -- línea sin código → solo alinear marca, sin stock
    if v_cb is null then
      update me.guias_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
      continue;
    end if;

    -- delta 0 → SKIP TOTAL (red de seguridad anti-duplicado: recerrar/reabrir+recerrar no toca nada)
    if v_delta = 0 then
      v_saltadas := v_saltadas + 1;
      continue;
    end if;

    -- VENTA o ENTRADA_TRASLADO (espejo) → NO mueve saldo aquí. Solo marca aplicado (evita doble-conteo).
    --   · SALIDA_VENTAS: el saldo lo aplica zona_descontar_venta por caja.
    --   · ENTRADA_TRASLADO: su IN ya lo aplica el cierre del SALIDA_MOVIMIENTO origen (espejo abajo).
    if not v_es_venta and not v_es_trasl_in then
      v_signo := case when v_signo_in then v_delta else -v_delta end;
      v_refk  := 'CIERRE-GUIA:'||v_id||':'||v_d.linea;

      -- KARDEX origen (ref única determinista; idempotente aunque se recierre N veces). Gateamos el saldo por dedup.
      v_kres := me.zona_kardex_registrar(jsonb_build_object(
        'zona', v_zona, 'codBarra', v_cb,
        'tipo', case when v_signo_in then 'TRASLADO_IN'
                     when v_es_mov   then 'TRASLADO_OUT'
                     else 'SALIDA_JEFA' end,
        'delta', v_signo, 'refTipo', 'GUIA', 'refId', v_refk,
        'usuario', 'sistema-cierre-zona', 'origen', 'CIERRE-IDEM'));

      -- SALDO atómico origen — SOLO si el kardex NO fue dedup (reintento/doble-tap NO dobla el saldo).
      if v_aplicar_stock and not coalesce((v_kres->>'dedup')::boolean, false) then
        insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
          values (v_cb, v_zona, v_signo, 'sistema-cierre-zona', now())
        on conflict (cod_barras, zona_id) do update
          set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_signo,
              fecha_ultimo_registro = now();
      end if;

      -- ESPEJO DE TRASLADO: SALIDA_MOVIMIENTO con destino → IN en la zona destino (+v_delta). Mismo gate por dedup.
      --   refId distinto (CIERRE-GUIA-IN) → el OUT y el IN nunca se pisan. cantidad_aplicada de la línea (del OUT)
      --   gobierna AMBOS lados → recerrar = delta 0 = SKIP = ni OUT ni IN se re-aplican.
      if v_es_mov then
        v_kres := me.zona_kardex_registrar(jsonb_build_object(
          'zona', v_zdest, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN',
          'delta', v_delta, 'refTipo', 'GUIA', 'refId', 'CIERRE-GUIA-IN:'||v_id||':'||v_d.linea,
          'usuario', 'sistema-cierre-zona', 'origen', 'CIERRE-IDEM'));
        if v_aplicar_stock and not coalesce((v_kres->>'dedup')::boolean, false) then
          insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
            values (v_cb, v_zdest, v_delta, 'sistema-cierre-zona', now())
          on conflict (cod_barras, zona_id) do update
            set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_delta,
                fecha_ultimo_registro = now();
        end if;
      end if;
    end if;

    update me.guias_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
    v_aplicadas := v_aplicadas + 1;
  end loop;

  update me.guias_cabecera set estado = 'CERRADA' where id_guia = v_id;

  return jsonb_build_object('ok', true, 'idGuia', v_id, 'estado', 'CERRADA',
    'stockAplicado', v_aplicar_stock, 'lineasAplicadas', v_aplicadas, 'lineasSaltadas', v_saltadas,
    'eraEstado', v_estado);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM, 'idGuia', v_id);
end;
$fn$;
revoke all on function me.cerrar_guia_zona_idempotente(text) from public, anon, authenticated;
grant execute on function me.cerrar_guia_zona_idempotente(text) to service_role;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- WRAPPERS para que el GAS (token de dispositivo, app='mosExpress') y la PWA puedan CERRAR una guía.
--   me.cerrar_guia_zona(p {idGuia}) — firma jsonb, gate me._claim_zona_ok() (acepta '' GAS/service_role · MOS · mosExpress).
--   mos.cerrar_guia_zona(p {idGuia}) — profile 'mos' para la PWA MOS (gate mos._claim_ok).
--   Ambos delegan en la idempotente. La idempotente ahora gatea con _claim_zona_ok (acepta '', MOS, mosExpress),
--   así el cierre desde GAS (app='' service_role), PWA-MOS (MOS) o PWA-ME (mosExpress) pasa el claim. El EXECUTE de
--   la idempotente sigue limitado a service_role → la puerta pública gated son estos wrappers (granted authenticated).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.cerrar_guia_zona(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idGuia', p->>'id_guia', p->>'idGuiaWH', '')), '');
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;
  return me.cerrar_guia_zona_idempotente(v_id);
end;
$fn$;
revoke all on function me.cerrar_guia_zona(jsonb) from public, anon;
grant execute on function me.cerrar_guia_zona(jsonb) to service_role, authenticated;

create or replace function mos.cerrar_guia_zona(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idGuia', p->>'id_guia', p->>'idGuiaWH', '')), '');
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;
  return me.cerrar_guia_zona_idempotente(v_id);
end;
$fn$;
revoke all on function mos.cerrar_guia_zona(jsonb) from public, anon;
grant execute on function mos.cerrar_guia_zona(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- (D) FIX MONEY-CRÍTICO de la metadata para el modelo ABIERTA — zona_guia_registrar_meta.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 🔴 PROBLEMA detectado en la prueba de rollback (test 10): la versión de 150 graba el detalle SIEMPRE con
--    cantidad_aplicada = cantidad. Eso es CORRECTO para el modelo VIEJO (estado CONFIRMADO/SALIDA_VENTAS: el saldo
--    YA se aplicó al crear → marcar aplicada=cantidad hace que cerrar dé delta 0 = no re-aplica). Pero es LETAL para
--    el modelo NUEVO: si una guía nace 'ABIERTA' con cantidad_aplicada=cantidad, su cierre calcula delta 0 → el
--    stock se aplicaría 0 VECES (faltante fantasma silencioso).
-- 🟢 FIX: cantidad_aplicada = 0 cuando estado='ABIERTA', = cantidad en cualquier otro estado. Así:
--      · ABIERTA   → aplicada=0 → 1er cierre aplica el total UNA vez (modelo nuevo).
--      · CONFIRMADO/SALIDA_VENTAS/CERRADA → aplicada=cantidad → delta 0 al cerrar (modelo viejo, sin doble-conteo).
--    on conflict (id_guia,linea) también respeta el estado (re-meta de una ABIERTA mantiene aplicada=0; pasar a
--    CONFIRMADO la re-alinea). Resto IDÉNTICO a 150 (mismos blindajes 🔴-1/🔴-2: no borrar detalle bueno con items vacío).
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
  v_abierta boolean    := false;   -- 🔴 (D): ABIERTA → cantidad_aplicada=0 (el cierre aplica el saldo)
  v_fecha  timestamptz;
  v_items  jsonb       := coalesce(p->'items', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_apl    numeric(20,3);
  v_lin    int := 0;
  v_n      int := 0;
  v_valid  int := 0;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' or v_zona = '' or v_tipo = '' then
    return jsonb_build_object('ok',false,'error','Requiere idGuia, zona y tipo');
  end if;
  v_abierta := (v_estado = 'ABIERTA');

  -- fecha: epoch ms o ISO, o now().
  begin
    if (p->>'fecha') is not null and btrim(p->>'fecha') <> '' then
      if (p->>'fecha') ~ '^[0-9]+$' then v_fecha := to_timestamp((p->>'fecha')::bigint / 1000.0);
      else v_fecha := (p->>'fecha')::timestamptz; end if;
    else v_fecha := now(); end if;
  exception when others then v_fecha := now(); end;

  insert into me.guias_cabecera (id_guia, fecha, vendedor, zona_id, tipo, observacion, zona_destino, estado, ultima_actividad)
    values (v_id, v_fecha, v_user, v_zona, v_tipo, v_obs, v_zdest, v_estado, now())
  on conflict (id_guia) do update
    set estado           = excluded.estado,
        observacion      = coalesce(excluded.observacion, me.guias_cabecera.observacion),
        ultima_actividad = now();

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
      v_apl  := case when v_abierta then 0 else v_cant end;   -- 🔴 (D): ABIERTA arranca en 0 → cierre aplica una vez
      v_lin := v_lin + 1;
      insert into me.guias_detalle (id_guia, linea, cod_barras, cantidad, cantidad_aplicada)
        values (v_id, v_lin, v_cb, v_cant, v_apl)
      on conflict (id_guia, linea) do update
        set cod_barras = excluded.cod_barras, cantidad = excluded.cantidad,
            cantidad_aplicada = excluded.cantidad_aplicada;
      v_n := v_n + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'idGuia', v_id, 'lineas', v_n, 'estado', v_estado);
end;
$fn$;
revoke all on function me.zona_guia_registrar_meta(jsonb) from public;
grant execute on function me.zona_guia_registrar_meta(jsonb) to service_role, authenticated;
