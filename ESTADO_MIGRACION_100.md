# Estado migración a Supabase — Listado FIJO para llegar al 100%

> Documento maestro. Marca lo que falta para retirar Sheets+GAS de las 3 apps (MOS · warehouseMos · MosExpress).
> Convención: ☐ pendiente · ✅ hecho · 🔴 TU PARTE (Luis) · 🔵 MI PARTE (Claude). Actualizado 2026-06-15.

---

## MOS (master) — foco actual

### Infra (✅ completa)
- ✅ Edge `mint-mos`, JWT, gate `mos._claim_ok`, RPCs de todos los módulos + 100x integral.
- ✅ Lectura directa de catálogo (viva en prod).
- ✅ `mos.resumen_dia` (recálculo cross-app de jornales) — paridad exacta validada.
- ✅ `mos.get_flags()` (interruptor central de flags de servidor).
- ✅ Sync WH saneado (sesiones ya no se congelan) + SW arreglado v2.43.219 (rollout confiable).
- ✅ **Dual-write en TODOS los módulos** (las sombras `mos.*` se actualizan al instante además del sync).

### Lo que falta MOS
- 🔴 **Destrabar tu dispositivo** una vez para adoptar v2.43.219 (instructivo abajo).
- ✅ **Read-paths directos COMPLETOS y cableados** (SQL 94+98, INERTE): catálogo, finanzas, historial,
  proveedores, pedidos, pagos-prov, prov-producto, jornadas, evaluaciones, horarios. (etiquetas: RPC creada,
  sin consumidor en panel MOS. Quedan por GAS por diseño: getProductosProveedorConStock cross-app,
  getResumenDia/liquidaciones-cómputo, pagos-jornales.)
- ✅ Comparador `semaforoLecturasMOS()` (deploy @414) + `compararLiquidacionMOS_semana()` (Fase D ✓ paridad exacta).
- 🔴🔵 **Activar LECTURA directa módulo por módulo** (BLOQUEADO 2026-06-15 por cuota UrlFetch GAS agotada →
  sombra stale → activar no rendía; se resetea ~24h). **MAÑANA**: 🔴 re-correr `semaforoLecturasMOS()` (sin
  error de cuota) → 🔵 activar los módulos en ✓ con tu OK. Estado parcial visto: proveedores tabla ✓,
  jornadas 285 filas, gastos/etiquetas/evaluaciones/horarios ✓; historial ⚠ (8 huérfanas del cutover viejo,
  pruebas tuyas LEV217 neto-cero — resolver: resembrar a hoja o limpiar).
- ✅ **Fase D — liquidaciones** (SQL 96, INERTE): `mos.materializar_liquidacion_dia/_semana` (UPSERT
  preservante) + gate frescura `wh.sesiones` + comparador `compararLiquidacionMOS`. **Bug de dinero cazado
  por 40x y arreglado** (fecha UTC→Lima, descuadraba el P&L un día). Falta: activar `MOS_LIQDIA_DIRECTO='1'`
  (validación física) + apagar sync hoja→sombra de esas 2 tablas + cablear cron/front.
- ✅ **Fase E — pg_cron** (SQL 97, INERTE doble candado): jobs `mos-snapshot-liq-semana` (23:30 Lima,
  persiste el snapshot que hoy falta) + `mos-health-frescura` (04:00 Lima), ambos `active=false`. Plan de
  corte de Sheets documentado en DISENO_migracion_mos_fase2.md. Falta: activar (flag + `alter_job active:=true`
  + apagar `_liqDiaCronDiario`/`_liqSyncJob` GAS tras observar 1-2 noches).
- 🔵 Limpiar el wiring de escritura directa del frontend (`js/api.js _postDirectoMOS`) sin uso en dual-write (menor).
- 🔴🔵 **Corte final de Sheets de MOS**: cuando todas las lecturas estén directas y validadas. Gran decisión, con vos.

---

## warehouseMos (WH)

- ✅ Lectura directa de stock (viva, con gate de frescura + fallback).
- ✅ Escritura directa PASO 4: 7 RPCs atómicas validadas (INERTES).
- ✅ Sync robusto (presupuesto + rotación) + resync sesiones.
- 🔴 Correr `instalarTriggersSyncWH()` periódicamente / confirmar que el trigger sigue vivo.
- 🔵 **Activar escritura directa WH** (las RPCs PASO 4 están inertes) — replicar el enfoque dual-write/validación.
- 🔴🔵 **Retirar Sheets de WH** (corte final).

## MosExpress (ME)

- ✅ Escritura directa: ventas (cab+detalle), cajas, movimientos, anulaciones, créditos — en prod con dual-write.
- ✅ Lecturas flipeadas: ventas_zona, estado_cajas, cobros, créditos.
- ✅ Impresión por Edge Function (PrintNode) en vivo.
- 🟡 CPE directo (boleta/factura) por Edge `emitir-cpe`: cableado, INERTE — falta token NubeFact.
- 🔴 Activar CPE: setear secrets `NUBEFACT_TOKEN`/`NUBEFACT_RUC` + verificar serie + flag `ME_CPE_DIRECTO='1'` + 1 boleta de prueba.
- 🔴🔵 **Retirar Sheets de ME** (corte final, la gran decisión META 2).

---

## Transversal (las 3 apps)

- 🔴 **Rotar credenciales expuestas** (diferido): PAT Supabase `sbp_*` + key Anthropic `sk-ant-*`. **NO** rotar `WH_JWT_SECRET`.
- 🔵 Roadmap "100% Supabase, retirar GAS" (`ROADMAP_SUPABASE_TOTAL.md`): PrintNode/NubeFact a Edge ✅(ME),
  triggers → pg_cron (snapshot/cierre nocturno), retirar Sheets, apagar GAS.
- 🔵 pg_cron: snapshot nocturno + cierre (cuando los cutover estén completos).

---

## Resumen en una línea
**MOS:** dual-write completo → falta activar lecturas (validación) + Fase D liquidaciones (en curso) + corte final.
**ME:** casi 100% directo → falta CPE (token) + corte final. **WH:** lectura viva, escritura inerte → falta activarla + corte final.
**El "100%" final de cada app = retirar Sheets** (decisión grande, contigo).
