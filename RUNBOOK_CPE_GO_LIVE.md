# 🧾 RUNBOOK — Go-live CPE (NubeFact producción)

> Estado 2026-07-02. La capa `fac.*` está **INERTE** (`FAC_CPE_DIRECTO=0`, `fac.config.activo=false`,
> sin token). El POS ME emite hoy por `me.correlativos` (`ME_CPE_DIRECTO=1`, BBB1≈70). **NO activar**
> producción hasta completar el checklist. Origen: revisión 200x del proceso CPE.

## Diseño confirmado (dueño)
- **Serie por ZONA de emisión.** Cada zona tiene su seriado en `mos.series_documentales`
  (hoy todas comparten BBB1/FFF1 solo por el demo; en prod cada zona su serie).
- **MOS/VIP es una "zona" más** con su propia serie (la jefa emite CPE/NV con su seriado).
- **Al convertir NV→boleta/factura** desde ME o MOS, el CPE respeta la serie de la **zona de emisión de la NV**.

## ✅ Ya arreglado + probado (capa inerte, aplicado a prod, sin activar)
- **Serie por zona (B3):** `fac.emitir_cpe` acepta `zona` y deriva la serie de `mos.series_documentales`
  (prioridad: serie explícita > serie de la zona > default `fac.config`). `me.convertir_nv_cpe` pasa
  `v_nv.zona_id` → la conversión toma la serie de la zona de la NV, sin tecleo manual. `serieNueva`
  ahora es OPCIONAL. Frontend ME: el modal auto-llena la serie desde la estación del cajero + la ajusta
  al alternar Boleta/Factura (v2.8.122). Probado ROLLBACK: ZONA-01→BBB1, override, default.
- **B1 (guard base imponible):** `fac.emitir_cpe` rechaza líneas con `valor_unitario` incoherente
  (base>total o IGV negativo; exonerado/inafecto base==total). Antes solo validaba `total==Σsubtotal`.
  `BASE_IMPONIBLE_INVALIDA`. Probado: bloquea vu malo, no bloquea gravado/exonerado válidos.
- **Seed de series (bloqueador de arranque):** `fac.admin_seed_series_from_zonas(clave_admin)` siembra
  en `fac.series` TODA boleta/factura activa de `mos.series_documentales` (correlativo 0, sin resetear
  existentes). `fac.serie_de_zona(zona,tipo)` helper. Devuelve las series `en_cero_falta_alinear`.

## ✅ B2 (huérfano cross-system) — RESUELTO vía reconciliador (323)
`fac.reconciliar_huerfanos(p)` (SQL 323) + cron `fac-huerfanos` (diario 08:17 UTC, no-op si inerte):
por cada serie activa camina NubeFact desde `correlativo+1`; si NubeFact TIENE un número que local NO
tiene → lo importa (fila `ORFANO_RECUP`, marca "revisar datos") + **avanza `fac.series.correlativo`**
→ el número nunca se reusa (sin duplicado). Idempotente (`on conflict (serie,numero)`). Probado con mock
de `fac._consultar`: detecta, importa, avanza a 69, re-run no duplica. Cierra el riesgo del huérfano
(NubeFact aceptó pero la tx local rollbackeó): antes se reusaba el número; ahora el barrido lo recupera.
Residual mínimo: la fila recuperada trae solo serie/nº/estado/nf_* (consultar_comprobante no da items/
cliente) → queda marcada para revisión manual. NO se reordena el emit (una NubeFact-rechazada dejaría la
NV anulada sin CPE; el reconciliador es la red correcta).

## (histórico) diseño previo de B2 — reemplazado por 323
**Problema:** en `me.convertir_nv_cpe` (y `me.emitir_cpe_fac`), NubeFact acepta el número (queda en SUNAT)
y si un statement POSTERIOR de la misma tx falla → rollback borra el registro local Y retrocede el
correlativo, pero SUNAT conservó el número → la próxima venta lo reusa = duplicado/hueco, invisible a la
reconciliación (que solo mira filas locales existentes).
**Diseño de fix (no rushear en código de emisión):**
1. **Reordenar el converter** para que `fac.emitir_cpe` sea la ÚLTIMA operación de la tx: anular la NV +
   insertar la venta-CPE (correlativo placeholder) + detalle ANTES; emitir al final; el correlativo se
   linkea por `local_id` (fac.comprobantes.local_id ↔ me.ventas.ref_local). Así nada falible corre tras el POST.
2. **Reconciliador de huérfanos:** cron que compara, por serie, `fac.series.correlativo` vs
   `max(numero)` en `fac.comprobantes`, y (opcional) camina la secuencia de NubeFact para detectar
   números emitidos sin fila local → los importa. Cierra la ventana residual.
3. Ventana amplia en `fac.reconciliar` (hoy 7 días) para PENDIENTE de cortes largos de NubeFact.
**Nota honesta:** la atomicidad perfecta entre Postgres y un HTTP externo no existe; el objetivo es
minimizar la ventana + hacerla DETECTABLE. Requiere su propia sesión + 200x.

## 🚦 CHECKLIST DE ACTIVACIÓN (en orden, con el token de producción en mano)
1. **DECIDIR el contador único.** Recomendado: **unificar en `fac.*`** (tiene emisión-en-Postgres,
   reconciliación, anulación, alineación por serie, y el panel VIP-MOS ya lo usa). Implica migrar el POS
   a `fac.emitir_cpe` y retirar `me.crear_cpe_directo` — paso deliberado, con su prueba. NO correr los dos
   contadores sobre la misma serie real.
2. **Definir la serie REAL de cada zona** en `mos.series_documentales` (hoy todas BBB1/FFF1 = demo).
   Limpiar las filas DUPLICADAS de esa tabla.
3. **Pegar el token de producción**: `fac.admin_set_config({nubefact_ruta, nubefact_token, clave_admin})`.
   (Solo pegar ≠ activar; `activo` sigue false hasta el paso 6.)
4. **Sembrar** `fac.series`: `fac.admin_seed_series_from_zonas({clave_admin})`.
5. **ALINEAR cada serie** a su ÚLTIMO número REAL en NubeFact producción (del panel NubeFact, no de las
   tablas locales): `fac.admin_alinear_correlativo({serie, numero, clave_admin})` por CADA serie. Verificar
   con `fac.get_config` que `proximo = ultimo_NubeFact + 1`. ⚠️ Reconciliar antes los ~18 BBB1 PENDIENTE
   sin hash (pudieron NO llegar a NubeFact).
6. **Fixear B2** (arriba) + validar con el token DEMO: emitir 1 boleta gravada multi-línea, 1 exonerada,
   1 factura → confirmar que NubeFact acepta el IGV por línea y la serie correcta.
7. **NO** correr `cpe_activar_produccion()` con `reset_correlativo=true` (resetea BBB1 a 1 = re-emite
   duplicados). Ningún emit de prueba en series reales (STUB quema número).
8. **Activar:** `fac.admin_set_config({activo:true})` + flag `FAC_CPE_DIRECTO=1`. Prender el cron
   `CPE_RECON_ON=1`. Vigilar los primeros comprobantes reales 1×1.

Docs relacionados: memoria `architecture_fac_cpe_centralizado`, `project_facturacion_nubefact`.
Archivos: `fac_02_emitir.sql`, `262_me_convertir_nv_cpe.sql`, `322_cpe_serie_seed_go_live.sql`, `fac_04_admin.sql`.
