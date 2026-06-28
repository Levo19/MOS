# CUTOVER CPE → PRODUCCIÓN (miércoles) — runbook

**Meta:** el miércoles = setear series en MOS Config + pegar el apikey + 1 comando + 1 venta de prueba.

## Single-source de series (verificado 2026-06-28) ✅
**Las series se manejan SOLO desde MOS → Configuración** (módulo zonas). Lo que setees ahí manda en TODO:
- MOS Config → escribe `mos.series_documentales` (SQL 269).
- **Emisión** (`me.crear_cpe_directo`, SQL 270) → lee la serie autoritativa de `mos.series_documentales` (estación → zona).
- **Cajas** → overlay `mos.series_documentales_app` (283/284) lee de ahí.
- El trigger de `mos.series_documentales` **bumpea `catalogo_version`** → las cajas refrescan SOLAS (~50s). No hay que tocar nada más.

## Estado actual
- **Vía activa:** ME emite directo (`ME_CPE_DIRECTO=1`) → `me.crear_cpe_directo` → Edge `emitir-cpe` → NubeFact. **Arquitectura verificada: con el token real emite de verdad** (demo → `aceptada=false` → PENDIENTE; producción → `true` → EMITIDO).
- **Secrets (DEMO):** `NUBEFACT_TOKEN/RUTA/RUC` seteados. `APISPERU_TOKEN` (lookup) ya real, no cambia.
- **Series demo:** `BBB1`/`FFF1` en MOS Config. Correlativo `me.correlativos`: BBB1=22, FFF1=1.
- **Reconciliador** `cpe-reconciliar` (cada hora) activo, gateado por `CPE_RECON_ON=0`.

## Pasos del cutover (miércoles, EN ORDEN)

### 1) Setear las series reales en **MOS → Configuración** (UI)
Cuando NubeFact te dé las series de producción, ponlas en el módulo de Configuración de zonas (boleta/factura por zona). Eso escribe `mos.series_documentales` y se propaga solo a emisión + cajas.

### 2) Un comando: reset de correlativo + reconciliador
En el **SQL editor de Supabase**:
```sql
select me.cpe_activar_produccion();
```
Lee las series vigentes (las que acabas de setear), **resetea su correlativo a 1** (producción empieza en 1 — el demo nunca fue a SUNAT) y prende `CPE_RECON_ON=1`.
- Si NubeFact YA tiene correlativos en esa serie: `select me.cpe_activar_produccion('{"reset_correlativo":false}'::jsonb);`

### 3) Pegar el apikey de producción (los secrets)
```
npx supabase secrets set \
  NUBEFACT_TOKEN=<token_produccion> \
  NUBEFACT_RUTA=<url_dedicada_produccion> \
  NUBEFACT_RUC=<ruc> \
  --project-ref rzbzdeipbtqkzjqdchqk
```
*(NUBEFACT_RUTA = la URL `api/v1/<UUID>` de producción que te da NubeFact.)*

### 4) Validar con 1 boleta de prueba
Emite UNA boleta real (monto chico) en una caja online. Debe:
- Imprimir con **QR SUNAT real + Hash + "Autorizado mediante R.I. SUNAT"**.
- En MOS → Tributario, verse **EMITIDO / aceptada por SUNAT**.
- Si queda PENDIENTE → revisar token/ruta; el reconciliador reintenta cada hora igual.

### Rollback
```
npx supabase secrets set NUBEFACT_TOKEN=<token_demo> NUBEFACT_RUTA=<ruta_demo> --project-ref rzbzdeipbtqkzjqdchqk
update mos.config set valor='0' where clave='CPE_RECON_ON';
```
(y volver las series demo en MOS Config si hizo falta).

## Ya listo (no tocas)
Emisión ME→Edge→NubeFact (verificada) · single-source de series (MOS Config → emisión + cajas, auto) · modelo único de ticket (QR/hash) · trazabilidad fiscal MOS · reconciliador (gateado) · helper `me.cpe_activar_produccion` (SQL 286) · lookup RUC/DNI (token ya puesto).
