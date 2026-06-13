# Roadmap — reads pendientes de flipear (Fase 2.A)

> Generado 2026-06-11. Clasificación evidence-based (grep de routers + caché + fuentes).
> **Hallazgo clave:** casi todos los reads pesados de MOS YA están cacheados server-side (`_almCached` 60-600s),
> así que su dolor de velocidad ya está mitigado y su ROI de flip es BAJO. La migración de valor está
> esencialmente capturada. Lo que queda con ROI real es poco.

## ✅ Ya flipeados (7 reads, en producción sobre Supabase)
| App | Read | Speedup | SQL |
|-----|------|--------|-----|
| ME | estadoCajas · cobros · creditos · ventasHoyZona | 5-8x | 06-09 |
| WH | getStock · getRotacionSemanal | 9x / 3.5x | 10-11 |
| MOS | getFinanzasRango | 442-831x | 13 |

---

## 🎯 TIER 1 — vale la pena (heavy + SIN caché). Prioridad real.
| Prioridad | App | Read | Por qué | Costo de build | Notas |
|:--:|-----|------|---------|----------------|-------|
| **1** | WH | **getDashboard** (Dashboard.gs:5) | Heavy (8 hojas), **sin caché**, se abre seguido. El audit lo descartó como *canary* por complejo, pero como FLIP con fallback es el de mayor ROI restante. | **XL** (8 fuentes + `_calcularPendientesEnvasado` factor/merma) | El más pesado. Byte-exact difícil (factor/merma/pendientes). |
| **2** | WH | **getHistorialStock** (Productos.gs:956) | Heavy (6 JOINs). Verificar si tiene caché (parece que no). | **L** | 6 JOINs; gating admin se queda en GAS. |

## 🟡 TIER 2 — ROI BAJO (heavy pero YA cacheados 60-600s). Flipear solo si molesta la latencia del cache-miss.
| App | Read | Caché actual | Fuentes |
|-----|------|:--:|---------|
| MOS | getCatalogoStockResumen | 180s | 5 (productos+equiv+stockWH+stockZonas+ventas) |
| MOS | getDashboardAlmacen | 300s | varias |
| MOS | getStockUnificado | 60s | stock WH+ME |
| MOS | getOperacionesUnificadas | 60s | guías+preingresos+… |
| MOS | getOperacionesConDetalle | 300s | + detalle |
| MOS | getRankingZonas | 300s | ventas por zona |
| MOS | getProductosSinVenta | 600s | ventas+catálogo |
| MOS | getInsightsStock | 600s | stock+ventas |
| MOS | getGuiasYPreingresos | 120s | guías+preingresos |
| MOS | getAlertasOperativas | 300s | varias |
| WH | getResumenPersonal | 5min (sub-query MOS) | personal+jornadas |
> El `_almCached` ya colapsa el costo: el hit pesado pasa 1× por ventana de TTL, no por request. Flipearlos
> es build XL para ahorrar el cache-miss ocasional → **diferir salvo queja concreta de latencia**.

## ⛔ NO flipear
- **Reads livianos** (getProducto/getCategorias/getProveedores/getEquivalencias/getPromociones/…): en Supabase serían MÁS lentos (la red > leer la hoja chica). Lección `getHistorialPrecios` = 0.2x.
- **getFinanzasDia**: materializa LIQUIDACIONES_DIA + sincroniza jornadas → es ESCRITURA disfrazada de lectura. Flipear saltaría esos writes.
- **Cross-app por SS_ID que dependen de catálogo vivo**: ojo lag de sync.

---

## Regla de build (cada read, sin excepción)
1. Leer la lógica GAS completa (todas las fuentes + redondeos).
2. Escribir `NN_<schema>_<fn>.sql` byte-exact (security definer, revoke public, grant service_role).
3. **Optimizar** para PostgREST timeout: filtrar al rango/scope + lookups deduplicados (no escaneo por línea).
4. `getXFlip` + router + `compararXMOS/WH/ME` (tolerancia: dinero ±0.01, estimaciones tolerancia relativa).
5. Deploy OFF → comparador → **iterar a paridad** → flip con `activarSupabaseX()`.
6. **Revisión senior 20× en cada paso.** Conexión directa a la DB (`.sbtools` + `.sb_db.url`) acelera la iteración.

## Veredicto
**La migración de lecturas está esencialmente completa en VALOR.** Quedan 2 candidatos reales (WH getDashboard/getHistorialStock, Tier 1) y un montón de Tier 2 de ROI bajo (ya cacheados). Atacar Tier 1 de a uno en sesiones dedicadas; Tier 2 solo si aparece queja de latencia.
