# Roadmap — MosExpress 100% Supabase (retirar GAS por completo)

> Visión del usuario: **"pasar TODO a Supabase, ya no existirá GAS para nada".**
> Este doc mapea CADA responsabilidad de GAS hoy → su reemplazo en Supabase, el orden, y los puntos finos.
> Mecanismo clave: **Edge Functions** (código server-side que corre EN Supabase, Deno/TS — el "GAS de Supabase",
> más rápido y global). Las llaves/secretos viven en los **secrets** de la Edge Function, NUNCA en el navegador.

## Estado actual (qué YA está en Supabase)
- ✅ Numeración correlativo (`me.siguiente_correlativo`, atómico+idempotente) — INSTANTÁNEA.
- ✅ Escritura de venta NV directa (`me.crear_venta_directa`, flag) — en pruebas.
- ✅ Lecturas operativas (estado_cajas, ventas_hoy_zona, cobros, creditos) — flipeadas, RPCs.
- ✅ Escrituras dual-write real-time (ventas, cajas, movimientos, anulaciones, créditos).
- ✅ Auth por dispositivo (mint-token JWT + RLS device-auth).
- ✅ Reportes (getFinanzasRango → mos.finanzas_rango).
- ✅ Catálogo, stock, etc. sincronizados a Supabase (Sheets aún es fuente para varios).

## Lo que falta mover (cada responsabilidad de GAS → Supabase)
| Responsabilidad GAS hoy | Reemplazo en Supabase | Notas |
|---|---|---|
| `procesarVenta` (NV) | `me.crear_venta_directa` (RPC) | hecho; falta CPE |
| `procesarVenta` (CPE/SUNAT) | Edge Function `emitir-cpe` (llama NubeFact) | ver sección NubeFact |
| Apertura/cierre caja | RPCs `me.abrir_caja` / `me.cerrar_caja` | el cierre es money-critical |
| Movimientos / créditos / anulaciones | RPCs (security definer, device-auth) | patrón ya probado |
| **NubeFact (emisión SUNAT)** | **Edge Function `emitir-cpe`** | secret del token NubeFact |
| **PrintNode (impresión)** | **Edge Function `imprimir`** | secret de la API key |
| Push (FCM) | Edge Function `push` (FCM server key secret) | |
| Triggers (sync, cierre semanal, escalar cobros, etc.) | **pg_cron** o Edge Functions scheduled | nativo de Supabase |
| Device auth / verificarDispositivo | mint-token (Edge Function) + tabla viva en Supabase | hoy lee la hoja viva |
| Bridges MOS/WH | esquemas compartidos `mos.*`/`wh.*` (ya comparten DB) | sin bridge, query directo |
| Fuente de verdad (Sheets) | **Supabase es la fuente; Sheets se retira** | el corte final |

## NubeFact — el insight clave (corrige una imprecisión previa)
El **QR/hash lo genera NubeFact** (al firmar el comprobante), **NO depende de que SUNAT lo acepte**. SUNAT
acepta después y de eso **se encarga NubeFact** (reintenta).
- **Boletas:** SUNAT NO valida una por una en tiempo real → van en **resumen diario** (async) → NubeFact
  devuelve el QR **al instante**. → **NO hay que esperar a SUNAT para imprimir.**
- **Facturas:** validación SUNAT más sincrónica → un poco más de demora.
→ Implicancia: el CPE **puede ser casi tan rápido como la NV**. El cuello NO es SUNAT (en boletas), es el
salto a GAS + el procesamiento/red de NubeFact. **Mover NubeFact a Edge Function + imprimir apenas hay QR**
(sin esperar la aceptación SUNAT, que es async) lo acelera mucho.
- PENDIENTE de diagnóstico: medir dónde se va el tiempo hoy en `emitirNubeFact` (GAS) — ¿esperamos la
  aceptación SUNAT innecesariamente, o es solo procesamiento? Eso define el fix exacto.

## PrintNode — Edge Function (más rápido Y seguro)
Hoy: `navegador → GAS (proxy, key segura) → PrintNode`. La llave está en GAS (bien, no en el navegador).
Futuro: `navegador → Edge Function (key en secret) → PrintNode`. **Igual de seguro** (key server-side) y
**más rápido** que GAS (Edge Functions ~100-300ms vs GAS ~500ms-1s, y son globales). Mejora neta.
(NO poner la key directo en el navegador / GitHub Pages público → cualquiera imprimiría a tus impresoras.)

## Orden de migración recomendado (cada paso con su 20×)
1. **Terminar escrituras NV directas** (wiring + reconciliación + cierre cuadra). ← EN ESTO.
2. **Cajas / movimientos / créditos / anulaciones** → RPCs directas (patrón probado).
   - ✅ **movimientos** HECHO (`supabase/19` `crear_movimiento_directo`, mirror `MIRROR_MOV`, reconcil; flag OFF;
     idempotente por `id_extra` compartido directo↔GAS; valida caja ABIERTA). Falta cajas (apertura/cierre =
     lo más money-critical), créditos, anulaciones. NOTA: `crear_venta_directa` aún NO valida caja abierta —
     cerrar ese gap al hacer cajas-directo.
3. **PrintNode → Edge Function** (rápido + seguro; saca un salto a GAS de cada impresión).
   - ✅ HECHO (`supabase/functions/imprimir`, desplegada; frontend flag `me_impresion_directa` OFF). Relay seguro:
     key en secret, auth por firma JWT (plataforma) + claim `app=mosExpress`, CORS ok, fallback a GAS. Intercepta
     el chokepoint `mandarImpresionPrintNode` (cubre TODA impresión). **PENDIENTE usuario**: setear el secret
     `PRINTNODE_API_KEY` (`supabase secrets set PRINTNODE_API_KEY=<key> --project-ref rzbzdeipbtqkzjqdchqk`) ANTES
     de activar el flag. Probado: no-auth→401, anon→401(claim), OPTIONS→200. Camino abierto para NubeFact→Edge.
4. **NubeFact → Edge Function `emitir-cpe`** (CPE directo desde la PWA; imprimir apenas hay QR).
   - 🟡 EDGE FUNCTION HECHA (`supabase/functions/emitir-cpe`, desplegada, inerte): port fiel de `emitirNubeFact`
     (IGV por tipo, payload, emisión boleta/factura, idempotencia por duplicado→consulta). Token en secrets
     `NUBEFACT_TOKEN`/`NUBEFACT_RUC`. Auth: firma JWT + claim app=mosExpress (probado anon→401). **FALTA:**
     (a) setear secrets (IDEAL: token DEMO de NubeFact para testear sin emitir a SUNAT real); (b) wiring del
     path CPE-directo en el front (correlativo B/F atómico + emitir + imprimir con QR + mirror) — detrás de
     flag, incremental, compliance-crítico; (c) NO test-emitir contra RUC real sin OK explícito (= boleta real).
5. **Triggers GAS → pg_cron / Edge Functions scheduled** (sync, cierres, escalaciones).
6. **Push, bridges, device-auth** → Edge Functions / esquemas compartidos.
7. **Retirar Sheets como fuente de verdad** (validación extensa + contingencia) — el CORTE FINAL.
8. **Apagar GAS.**

## Riesgos / consideraciones
- **Cada paso es money-critical** → 20× + prueba en dispositivo antes de habilitar (flag + fallback).
- **RLS fail-closed en TODAS las tablas** antes de exponer la Data API (hoy authenticated solo via RPCs).
- **Edge Functions necesitan el Supabase CLI** para deploy (hoy no usado; setear el flujo de deploy).
- **Hashear PINs** + mover secretos a un schema no expuesto (ver MIGRACION_FASE2_PLAN.md).
- **Idempotencia + reconciliación** en cada escritura (el patrón ref_local + índice único).
- **Contingencia**: mantener un rollback (flag server-controlled) hasta que cada pieza esté probada en prod.

## Referencias
- `FASE2_WIRING_PENDIENTE.md` — el wiring de escritura NV (contrato + plan).
- `MIGRACION_FASE2_PLAN.md` — auth/RLS, los 3 bloqueantes (ya resueltos #0), C1-C14.
- `supabase/14..18` — correlativo, RLS, crear_venta_directa, índices.
