-- 124_mos_lecturas_portables.sql — [MIGRACIÓN MOS · FASE 2 · LECTURAS PORTABLES restantes]
-- Porta a RPCs Supabase (esquema mos, gate mos._claim_ok) las lecturas 🟡 que aún van por GAS pero cuyo
-- dato YA vive en una sombra. Mismo patrón inerte/cross-app que 94/98/106..118 (define RPC + grant; el wiring
-- de js/api.js gobierna su activación por el gate de LECTURA _mosLecturaDirecta).
--
-- ALCANCE DE ESTE ARCHIVO (2 RPCs nuevas; la 3ra ya existía en 118):
--   1) mos.tarjeta_wa_obj       — getTarjetaWA (Code.gs:635) → mos.config {TARJETA_WA_*}              [PORTABLE]
--   2) mos.me_creditos_pendientes — meGetCreditosPendientes (Cajas.gs:1367) → me.creditos_pendientes()  [PORTABLE]
--   (·) mos.me_consultar_cliente — meConsultarCliente: YA definida en 118_mos_vistas_me.sql; aquí solo
--       se cablea en api.js. NO se redefine.
--
-- NO PORTABLES (reportadas, NO se tocan):
--   · getLiquidacionesPendientesSemana — GAS es un STUB DEPRECADO (Liquidaciones.gs:1665) que devuelve [].
--     No hay nada que servir desde sombra; portarlo solo replicaría el [] vacío. Sin valor.
--   · getPromociones — NO existe sombra mos.promociones / me.promociones. La fuente es la hoja PROMOCIONES
--     (Promociones.gs:68). Sin sombra → no portable hasta que exista un sync de promociones a Supabase.
--   · getAuthCatalogo — el dato es una CONSTANTE JS hardcodeada (_AUTH_CATALOGO, Seguridad.gs:118), nunca
--     persistida en DB. No hay sombra; portarlo requeriría sembrar una tabla (fuera de alcance).
--
-- ── GATE + ENVOLTORIO (idéntico al resto de la Fase 2) ────────────────────────────────────────────────────
--   mos._claim_ok()        (74) — service_role/GAS o claim app='MOS'; otro → APP_NO_AUTORIZADA.
--   mos._frescura_sombra() (94) — agrega _heartbeat/_now/_ttl_min/_fresh (latido MOS_SYNC_HEARTBEAT).
--   revoke public + grant service_role, authenticated. STABLE · SECURITY DEFINER · search_path=''.
--   TZ America/Lima donde aplique (la maneja la RPC me.creditos_pendientes internamente).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.tarjeta_wa_obj(p jsonb) — números de WhatsApp + marca para las tarjetas.
--    Espeja getTarjetaWA (Code.gs:635). El front (app.js:18231) lee el OBJETO PLANO
--    { TARJETA_WA_COMERCIAL, TARJETA_WA_COMPRAS, TARJETA_MARCA } de r.data.
--    FUENTE: mos.config (claves TARJETA_*). getTarjetaWA intenta primero me.get_tarjeta_config y cae a
--    CONFIG_MOS; mos.config es la sombra de CONFIG_MOS (fuente de verdad MOS) → guardarTarjetaWA (Code.gs:650)
--    upserta mos.config EN EL ACTO al guardar, así que la sombra está siempre fresca para estas 3 claves.
--    Devolvemos exactamente esas 3 claves (no toda la config) para paridad de shape estricta con el consumidor.
--    Envoltorio: {ok:true, data:{...3 claves...}} || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.tarjeta_wa_obj(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_com   text;
  v_prov  text;
  v_marca text;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  select valor into v_com   from mos.config where clave = 'TARJETA_WA_COMERCIAL' limit 1;
  select valor into v_prov  from mos.config where clave = 'TARJETA_WA_COMPRAS'   limit 1;
  select valor into v_marca from mos.config where clave = 'TARJETA_MARCA'        limit 1;

  return jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'TARJETA_WA_COMERCIAL', coalesce(v_com,  ''),
      'TARJETA_WA_COMPRAS',   coalesce(v_prov, ''),
      'TARJETA_MARCA',        coalesce(v_marca,'')
    )
  ) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.tarjeta_wa_obj(jsonb) from public;
grant execute on function mos.tarjeta_wa_obj(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) mos.me_creditos_pendientes(p jsonb {diasAtras}) — créditos pendientes ME agrupados por día.
--    Espeja meGetCreditosPendientes (Cajas.gs:1367 → bridge ME creditos_pendientes → getCreditosPendientesFlip,
--    MigracionME.gs:942, que YA lee la RPC me.creditos_pendientes(dias_atras) cuando FUENTE_DATOS=supabase).
--    Aquí MOS llama la MISMA RPC ME cross-schema (DEFINER ejecuta como owner con grant ALL en esquema me),
--    de modo que MOS-directo y ME-flip-supabase devuelven el MISMO computado (una sola fuente de verdad).
--
--    me.creditos_pendientes devuelve {grupos, totalAcumulado, totalTickets}. Lo envolvemos en data:
--    El front (app.js:24917) hace `const d = (r && r.data) ? r.data : (r || {}); d.grupos`.
--    El helper _getObjDirectoMOS devolverá r.data (= {grupos,totalAcumulado,totalTickets}); como ese objeto NO
--    tiene .data, `d = r.data ? r.data : r` cae a r mismo → d.grupos resuelve. Paridad con el shape GAS
--    (getCreditosPendientesFlip emite {status:'success', grupos, totalAcumulado, totalTickets} y MOS lo recibe
--    desempaquetado por _meBridgeGet → r.grupos; el directo entrega lo equivalente vía r.data.grupos).
--
--    diasAtras: acepta {diasAtras} (lo que pasa el front) o {dias_atras}. Default 30. Clamp 1..365 defensivo.
--    Envoltorio: {ok:true, data:{grupos,totalAcumulado,totalTickets}} || _frescura_sombra().
--
--    ⚠️ FRESCURA: _frescura_sombra() refleja el latido del sync de MOS, NO el de ME (las tablas me.* son
--       sombras del sync de ME). Mismo riesgo documentado en 118 (NOTA A): si el sync de ME se atrasa, _fresh
--       puede reportar fresco. El front cae a GAS si _fresh=false (cota conservadora). Prerequisito de cutover:
--       un ME_SYNC_HEARTBEAT propio (pendiente, igual que el resto de read-paths cross-app ME).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.me_creditos_pendientes(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_dias int := coalesce(nullif(btrim(coalesce(p->>'diasAtras', p->>'dias_atras', '')), '')::int, 30);
  v_res  jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_dias < 1   then v_dias := 1;   end if;
  if v_dias > 365 then v_dias := 365; end if;

  v_res := me.creditos_pendientes(v_dias);   -- {grupos, totalAcumulado, totalTickets}
  if v_res is null then v_res := jsonb_build_object('grupos','[]'::jsonb,'totalAcumulado',0,'totalTickets',0); end if;

  return jsonb_build_object('ok', true, 'data', v_res) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.me_creditos_pendientes(jsonb) from public;
grant execute on function mos.me_creditos_pendientes(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS / GAPS (honestidad 40x)
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────
-- · me.creditos_pendientes (LANGUAGE sql, sin SECURITY DEFINER) es invocada AQUÍ desde una RPC DEFINER mos.*
--   que corre como owner (service_role) → tiene acceso a me.*; la RPC ME hereda el contexto del caller. OK.
-- · tarjeta: si las 3 claves no estuvieran en mos.config, se devuelven ''. El front trata '' como "no
--   configurado" igual que el fallback GAS (CONFIG_MOS vacío → '').
-- · me_consultar_cliente: ya en 118. CAVEAT vigente — no resuelve SUNAT/RENIEC en vivo; doc ausente en la
--   sombra → encontrado:false → el front debe mantener el lookup SUNAT por GAS (gate de lectura sólo cubre el
--   match contra sombra, no el servicio externo). El read-path se cablea con esa salvedad.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
