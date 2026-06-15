# Catálogo directo (cache local desde Supabase) — destraba remanente B3 + B4

> Decisión del usuario (2026-06-13): **cache local** alimentado por una RPC de catálogo directa a Supabase.
> Razón #1: WH es offline-first (almacén) → el catálogo DEBE estar disponible sin señal. Directo a mos.* rompe offline.
> El USO por-operación es siempre contra el cache local; solo la DESCARGA se migra de GAS a Supabase (GAS-cero).

## Hallazgos de la investigación (listos para ejecutar)
1. **Las 7 tablas que `descargarMaestros` baja YA están en Supabase** (schema `mos`):
   `productos` (2365 filas), `equivalencias`, `proveedores`, `personal`, `impresoras`, `zonas`, `estaciones` (+ `categorias`).
2. **Specs canónicos header↔snake** en `ProyectoMOS/gas/MigracionCatalogo.gs` → `_CAT_SPECS` (productos línea 68, equivalencias 98,
   categorias 102, personal 107…) y en `MigracionMOS.gs` (proveedores, impresoras, zonas, estaciones). Son `[pgCol, headerHoja, tipo]`
   = el mapeo EXACTO del backfill → invertirlo da el shape-hoja que el front cachea (cero divergencia).
3. `descargarMaestros` (WH) devuelve `{productos, equivalencias, proveedores, personal, impresoras, zonas, estaciones, ...}`
   donde cada uno es `_sheetToObjects(hoja MOS)` (shape-hoja camelCase). + filtros: equivalencias activas, personal estado='1',
   impresoras appOrigen=warehouseMos+activo, zonas estado='1', estaciones ALMACEN.adminPin.

## ⚠️ Punto crítico para el 40x (NO hacer al apuro)
El mapeo inverso de **bool** (`estado`, `es_envasable` en productos; `activo` en equivalencias; `estado` en personal/zonas):
- El front filtra distinto según cada uno: equivalencias usa `_esActivo(e.activo)`, personal usa `String(p.estado)==='1'`.
- Hay que verificar, POR CAMPO, qué espera el front (`true/false` vs `1`/`0` vs `'1'`/`'0'`) ANTES de elegir el tipo de _sbValFront.
- Riesgo si se equivoca: filtrar productos ACTIVOS como inactivos → el almacén deja de ver productos. CRÍTICO.
- Tipos especiales en productos: `tipo_producto` (USER-DEFINED enum), `historial_cambios`/`segmentos_precio` (jsonb), `tipo_igv` (int).

## Plan (cada paso con 40x)
1. **RPC backend** `mos.catalogo_wh_rls()` (o varias `mos.<tabla>_wh_rls`) en schema `mos`, gate `me.jwt_app()='warehouseMos'`,
   `security definer`, `jsonb_agg` por tabla con los filtros de descargarMaestros. Devuelve `{ok, productos, equivalencias, ...}`.
   Validar: claim warehouseMos pasa, ajeno rechazado, conteos = filas reales, bools correctos.
2. **Front**: nuevo `_sbDescargarMaestros()` que llama la RPC + mapea con `_CAT_SPECS` invertido (porteado igual que `_WH_SPECS_LEC`),
   resolviendo CADA bool según lo que el front espera. Reapuntar `descargarMaestros` (gate flag) con fallback a GAS.
3. **Validar paridad**: comparar el catálogo de la RPC vs `descargarMaestros` de GAS (gate, como PASO 3) — bools, conteos, shape.
4. Con el catálogo en cache local → **destrabar remanente B3**: getGuia (enriquece desc), getEnvasados (enriquece), getStockProducto,
   getProductos/getProducto (sirven del cache), getPendientesEnvasado (cálculo local), getLotesFIFO/HistorialLote.
5. Luego **B4**: orquestadores en cliente (aprobar_preingreso, auditar, envasado) validando productos contra el cache + las 12 RPCs PASO 4.

## Avance 2026-06-13 (2da parte)
- ✅ **RPC `mos.catalogo_wh_rls()` NÚCLEO HECHA Y VALIDADA 9/9** (`48_mos_catalogo_wh_rls.sql`): devuelve productos (2365)
  + equivalencias activas (60), CRUDO snake_case, gate `wh._claim_ok()`, security definer. Esto destraba el enriquecimiento
  de B3 y la validación de B4 (el catálogo central + canónico/equivalente).
- ✅ **Tipos bool verificados** (para el front mapear): `estado`/`activo` de personal/zonas/impresoras/equivalencias/estaciones
  = **boolean** → front a `'1'/'0'` (tipo `bool10`). `proveedores.estado` = **text** → crudo.
- ⚠️ **BLOCKER para incluir maestros**: el `adminPin` de la estación ALMACEN (descargarMaestros lo usa para REABRIR guías)
  NO aparece con `upper(coalesce(nombre,id_estacion))='ALMACEN'` en `mos.estaciones`. **Investigar cómo identificar la estación
  ALMACEN en Supabase ANTES de extender la RPC** — incluirla mal = WH no puede reabrir guías. Conteos de filtros listos:
  personal activo=6, zonas=3, impresoras(wh+activo)=2, proveedores=102.

## RESTA (catálogo completo + integración front)
1. Resolver el blocker del adminPin ALMACEN → extender `mos.catalogo_wh_rls()` a los 7 datasets (productos✅, equivalencias✅,
   + proveedores, personal[where estado], impresoras[where lower(app_origen)='warehousemos' and activo], zonas[where estado], adminPin).
2. Front: tipo `bool10` en `_sbValFront` + `_CAT_SPECS_LEC` (invertir `_CAT_SPECS`) + `_sbDescargarMaestros()` con flag+fallback a GAS.
3. Enriquecimiento B3 (getGuia/getEnvasados/getStockProducto/getPendientesEnvasado): usar `OfflineManager.getProductosCache()`
   YA poblado (no requiere la RPC; el cache local basta para enriquecer por-operación). getGuia conviene RPC dedicada (guia+detalle).
4. Validar paridad catálogo vs descargarMaestros de GAS (gate). Luego B4 (orquestadores en cliente).

## Estado al cerrar (2026-06-13)
- B3 wh-puro: ✅ 15 lecturas directas validadas. Fechas: ✅ TZ Lima.
- **Catálogo backend COMPLETO** ✅: `mos.catalogo_wh_rls()` (48) validada 10/10 con los 6 datasets de descargarMaestros
  (productos 2365, equivalencias 60, proveedores 102, personal 6, impresoras 2, zonas 3), filtros idénticos, bools crudos.
  adminPin OMITIDO (va por `mos.verificar_clave_admin`, ver `DISENO_autorizacion_roles.md`). estaciones omitida (solo servía al adminPin).
- **TODO el backend de PASO 5 + catálogo + autorización está hecho y validado.** Lo que RESTA es FRONTEND/integración (no SQL):
  1. Front catálogo: tipo `bool10` en `_sbValFront` + `_CAT_SPECS_LEC` (invertir `_CAT_SPECS` de MigracionCatalogo.gs) + `_sbDescargarMaestros()`
     que llama `mos.catalogo_wh_rls` y reemplaza descargarMaestros (flag + fallback a GAS).
  2. Enriquecimiento B3 (getGuia/getEnvasados/getStockProducto/getPendientesEnvasado) con `OfflineManager.getProductosCache()` local.
  3. F2 autorización: las apps llaman `mos.verificar_clave_admin` directo (fallback a GAS por flag).
  4. B4 orquestadores en cliente. B5 Edge (PrintNode/IA/fotos). B6 cutover + apagar GAS.
