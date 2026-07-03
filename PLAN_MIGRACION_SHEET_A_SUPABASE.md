# 🗺️ Plan — Eliminar la Hoja de Google (VENTAS_CABECERA) → ME/MOS 100% Supabase

> Meta: que `me.ventas` (Supabase) sea la ÚNICA fuente de verdad de ventas. Hoy la Hoja es el "master"
> y Supabase la sombra; hay ~40 lecturas de la Hoja (incl. el cierre de caja) que deben migrarse ANTES
> de apagar la Hoja. Programa por ETAPAS, cada una probada (paridad Supabase↔Hoja) antes de avanzar.
> Origen: investigación 2026-07-02 (feasibility turno.html→Supabase).

## Principio de seguridad (money-safe)
- **Nunca** apagar una escritura/sync a la Hoja hasta que TODAS sus lecturas estén en Supabase.
- Cada etapa: (1) verificar que el dato existe en Supabase con paridad; (2) migrar el lector; (3)
  validar en vivo; (4) recién entonces avanzar. La Hoja queda como respaldo inerte hasta la última etapa.
- Orden: primero lo que ya está listo + duele (turno), luego lo money-crítico, luego el resto.

## Precondición — Etapa 0: durabilidad de la escritura a Supabase
Hoy cada venta/cobro/cierre hace `_dualWriteVentaME` (best-effort, maxRetry:1, error tragado, fuera de la
tx de la Hoja). Si Supabase está degradado en ese instante, la venta queda solo en la Hoja hasta el heal
de 15min. **Antes de que algún lector dependa 100% de Supabase:**
- [ ] Endurecer el dual-write (retry con backoff, o cola persistente) O confiar en el heal insert-missing
      (MigracionME `activarMEVentasDirecto` ya hace ON CONFLICT DO NOTHING cada 15min sin revertir ediciones).
- [ ] Verificar diario: `count(me.ventas del día) == count(Hoja del día)` (script de paridad).

## Inventario de lectores de la Hoja VENTAS_CABECERA (~40) — a migrar
**Money-crítico (primero):**
- ME `Caja.gs:_cerrarCajaAtomicoCore` (cuadre de efectivo lee FormaPago de la Hoja). ⚠️ **Mitigado en parte:**
  el cierre YA corre por `me.cerrar_caja` directo (lee Supabase); solo el FALLBACK GAS lee la Hoja.
- MOS `Cajas.gs:datosTurno` (turno.html) · `getCierresCaja` · `anularTicketME` · `cambiarMetodoME` · `imprimirTicketZCierre`
- MOS `Finanzas.gs:472,1286` (ingresos del día) · ME `ReporteCierre.gs`, `AlertaEfectivo.gs`, `Code.gs:estadoCajas`
**Cross-app / analítica:**
- MOS `Conexiones.gs`, `Almacen.gs` (velocidad/ranking stock), `Evaluaciones.gs` (KPIs vendedor), `Proveedores.gs`
- ME `Radio.gs:topProductosHoy`
**Fiscal / correlativo / reportes:**
- ME `NubeFact.gs:reconciliarCPEsPendientes` · `Ventas.gs` (correlativo + reportes IGV/CPE mensuales) · `Guias.gs`
- ME `Creditos.gs` (6 funciones leen FormaPago) · `EditarVenta.gs` (5, read-then-write)
**Bridge/infra (se retiran al final):** `Fase2Auth.gs`, `MigracionME.gs`, el sync mismo.

## Etapas
### ✅ Etapa 1 — turno.html / datosTurno → `me.datos_turno` (HECHO + LIVE 2026-07-02)
DESPLEGADO (clasp deploy @437) + VERIFICADO: el endpoint GAS `datosTurno` devuelve `me.datos_turno`
(Supabase EN VIVO). La Hoja ELIMINADA del camino del turno. GAS queda solo como proxy autenticado
(service_role). **Para cero-GAS TOTAL** (turno.html directo a Supabase sin GAS) falta darle auth segura a
turno.html — el atajo anon fue (bien) bloqueado por seguridad (expondría datos del turno al público).
⚠️ **Pendiente para que las ediciones no se reviertan:** correr `activarMEVentasDirecto()` en el editor
de Apps Script de ME (mete `ventas` a ME_SYNC_OFF_TABLAS) — si no, el sync Hoja→Supabase revierte la
edición directa de forma de pago en ≤15min.

### (histórico) Etapa 1 — descripción original
`me.datos_turno(p_id_caja)` ya existe y devuelve la MISMA forma que consume turno.html, leyendo `me.ventas`
en vivo → refleja ediciones al instante + rápido. Migrar el lector (datosTurno) a la RPC, con fallback Hoja
detrás de un flag. turno.html no cambia (o pasa a directo si se le da token). **Arregla el desync + la lentitud.**

### Etapa 2 — money-crítico
- Confirmar que el cierre corre 100% directo (ya verificado: PK-VENTAS) → el fallback GAS que lee la Hoja
  se puede retirar tras P4/P5. `estadoCajas`, `ReporteCierre`, `AlertaEfectivo`, MOS `getCierresCaja/Finanzas`
  → migrar a RPCs Supabase (`me.estado_cajas`, `mos.cierres_caja`, etc. — varias ya existen).

### Etapa 3 — cross-app / analítica (MOS)
Conexiones/Almacen/Evaluaciones/Proveedores → leer `me.ventas` sombra (o RPCs) en vez de la Hoja ME.

### Etapa 4 — fiscal / correlativo / reportes (ME)
Correlativo ya está migrado a `me.correlativos`/`fac.series`. Migrar reportes IGV/CPE + reconciliar +
Creditos + EditarVenta a Supabase. (Se cruza con el go-live CPE.)

### Etapa 5 — apagar la Hoja
Cuando 0 lectores dependan de la Hoja: apagar el sync Hoja↔Supabase para `ventas`, dejar de escribir la Hoja,
Hoja = archivo histórico. ME/MOS 100% Supabase para ventas.

## Estado
- Etapa 1: EN CURSO. Resto: pendiente, en orden.
- Verificación de escritura (Etapa 0): el heal insert-missing ya cubre (no revierte ediciones).
