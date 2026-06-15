# 🔍 Revisión iterativa 50x — Bug hunt total (post Rondas 1-5)

> Fecha: 2026-06-12. Alcance: TODO lo implementado en la migración WH+ME a Supabase
> (dual-write WH, helpers/guards, cierre-directo ME, SQL 23-27). Método: barrido adversarial
> multironda en 3 frentes paralelos independientes + verificación a mano de cada hallazgo serio.

## Veredicto
**Sin bugs críticos reales.** Los 2 hallazgos "CRÍTICOS" de dinero reportados por el barrido
resultaron **FALSOS POSITIVOS** (verificados contra la fuente de verdad). Se aplicaron 3 endurecimientos
defensivos de bajo riesgo. El sistema queda con la sombra WH al instante en todas las tablas operativas
y el cierre-directo ME sigue inerte y correcto, listo para validación.

---

## 🟥 Falsos positivos (verificados a mano — NO eran bugs)

### FP-1 / FP-2 · "me.cerrar_caja y me.simular_cierre suman movimientos _VIRTUAL como efectivo"
**Reclamo:** el RPC sumaría `INGRESO_VIRTUAL`/`EGRESO_VIRTUAL` al efectivo, descuadrando vs frontend.
**Verificación:** el RPC usa **igualdad estricta** `case when tipo='INGRESO'` / `tipo='EGRESO'`
(SQL 27 líneas 84-87, SQL 26 líneas 27-28). En Postgres `tipo='INGRESO'` **NO** matchea `'INGRESO_VIRTUAL'`
(no es substring). Es **idéntico** al núcleo GAS de referencia `Caja.gs:423-424`:
`if (tipoE === 'INGRESO') ingresosEfe += mtoE; else if (tipoE === 'EGRESO') egresosEfe += mtoE;`
Los 4 tipos válidos son `['INGRESO','EGRESO','INGRESO_VIRTUAL','EGRESO_VIRTUAL']` (EditarVenta.gs:15).
Por eso la validación previa dio **147.40 = GAS al centavo**. El agente asumió matching por substring.
**Conclusión: NO es bug. El RPC excluye los _VIRTUAL correctamente, espejando GAS.**

---

## 🟩 Endurecimientos aplicados (defensa, bajo riesgo)

| # | Dónde | Cambio | Deploy |
|---|-------|--------|--------|
| H1 | WH `Supabase.gs` `_sbUpdate` | Guard simétrico al de `_sbDelete`: PATCH sin filtros = UPDATE de toda la tabla → BLOQUEADO. (`_sbUpdate` hoy no se usa, anti-foot-gun a futuro.) | GAS @444 (5 IDs) |
| H2 | ME `Supabase.gs` `_sbUpdate` | Mismo guard. | GAS @207 |
| H3 | WH `MigracionWH.gs` `_dualWritePatchWH` | Rechaza `patch` vacío/no-objeto antes del HTTP (ya rechazaba filtros vacíos). | GAS @444 |
| H4 | `27_fase2_cerrar_caja.sql` | Tras el dedup, guard explícito `if v_caja.estado <> 'ABIERTA' → CAJA_ESTADO_INVALIDO`. RPC **inerte**, se aplicará a la DB el día de activación/validación de `ME_CIERRE_DIRECTO`. | repo (no aplicado a DB aún) |

---

## 🟨 Hallazgos menores — riesgo aceptado / backlog (NO bloqueantes)

- **Flag `serverFlag || localStorage` permite override local del kill-switch (reportado ALTO).**
  NO explotable en rutas de dinero: cierre y CPE tienen kill-switch **server-side autoritario** en la
  propia RPC (SQL 27 línea 45 y SQL 24 chequean `mos.config` y rehúsan si el flag está en '0'). El OR del
  frontend es opt-in por dispositivo a propósito durante el rollout. Si un device fuerza el flag local, la
  RPC igual responde DESACTIVADO y el front cae a GAS → sin doble escritura, sin bypass. **Riesgo aceptado.**
- **Audio en `setTimeout` (iOS) reanuda fuera de gesto (reportado ALTO).** Pre-existente, no introducido por
  la migración; sólo afecta que un sonido no suene (tiene `.catch`). **Backlog UX, fuera de alcance.**
- **`_enviarMutacionDinero` re-encola en 409/400 (BAJO).** Idempotente (sin dinero duplicado); sólo bloat de
  cola/toasts. **Backlog.**
- **`_sbSelectAll` backstop `offset>200000` (BAJO).** Lee ~201k en vez de 200k filas si alguna vez se llegara;
  irrelevante a la escala real. **No se corrige.**
- **`_sbOnce_` con filtro de valor null pasa el conteo de claves (BAJO).** Genera un filtro `IS NULL` válido
  (no un op sin filtro); mitigado por los guards de `_dualWritePatchWH`. **No se corrige.**

---

## ✅ Confirmado correcto por el barrido (sin cambios)
- **56 call-sites de dual-write WH:** todos best-effort (try/catch), después de la escritura a Sheets,
  tabla correcta, PK presente, sin loops HTTP, sin gaps de mutación. `_whRowMap` mapea header→pgcol bien.
- **5 helpers re-lee-fila:** col 0 = id verificado contra HEADERS de cada hoja (PREINGRESOS/LOTES/MERMAS/
  AUDITORIAS/PRODUCTO_NUEVO). `_dualWriteDetallesGuiaWH` numera líneas igual que el batch.
- **`_whVal` coerción de tipos:** 0 numérico sobrevive, '' → null, fechas ISO en TZ Lima, bool/json robustos.
- **Verificador universal `verificarParidadWH`:** guard de PK compuesta + heurística de fecha (nunca
  vencimiento como ventana) correctos. Gate re-corrido **VERDE en 9 tablas** (ver MIGRACION_WH_FASE2.md).
- **SQL 23-27:** claim `me.jwt_app()='mosExpress'`, `search_path=''`, validaciones de total/caja/zona,
  CPE kill-switch y cierre inerte — todo en su lugar.
