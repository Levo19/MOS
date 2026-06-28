# CUTOVER CPE → PRODUCCIÓN (miércoles) — runbook

**Meta:** el miércoles = pegar el apikey de producción + 1 comando + 1 venta de prueba. Todo lo demás ya está listo.

## Estado actual (verificado 2026-06-28)
- **Vía activa:** ME emite por su path directo (`ME_CPE_DIRECTO=1`) → RPC `me.crear_cpe_directo` → Edge `emitir-cpe` → NubeFact. **Arquitectura verificada: con el token real, emite de verdad** (en demo NubeFact devuelve `aceptada_por_sunat=false` → PENDIENTE; en producción → `true` → EMITIDO).
- **Secrets seteados (DEMO):** `NUBEFACT_TOKEN`, `NUBEFACT_RUTA`, `NUBEFACT_RUC`. `APISPERU_TOKEN` (lookup RUC/DNI) ya seteado aparte (no cambia). `CPE_CRON_SECRET` seteado.
- **Series demo:** `BBB1` (boleta) / `FFF1` (factura) en `mos.series_documentales`. Contadores `me.correlativos`: BBB1=22 (21 boletas demo), FFF1=1.
- **Reconciliador** `cpe-reconciliar` (cada hora) ACTIVO pero gateado por `CPE_RECON_ON=0`.
- **fac layer** (`FAC_CPE_DIRECTO`, esquema `fac`) INERTE — NO es la vía activa, se ignora en este cutover.

## ⚠️ Decisión que necesito de ti (lo único que falta definir)
**¿Cuáles son las series REALES de producción** que registraste en SUNAT/NubeFact?
- Si son las MISMAS demo (`BBB1`/`FFF1`) → el comando las deja igual y solo resetea el correlativo.
- Si son otras (lo típico: `B001`/`F001`) → el comando las cambia.

## Pasos del cutover (miércoles)

### 1) Pegar el apikey de producción (los secrets)
```
npx supabase secrets set \
  NUBEFACT_TOKEN=<token_produccion> \
  NUBEFACT_RUTA=<url_dedicada_produccion>  \
  NUBEFACT_RUC=<ruc> \
  --project-ref rzbzdeipbtqkzjqdchqk
```
*(NUBEFACT_RUTA = la URL `api/v1/<UUID>` que te da NubeFact para producción. El RUC ya está, repítelo si no cambia.)*

### 2) Un comando: series + correlativo + reconciliador
En el **SQL editor de Supabase** (o vía DB), con TUS series de producción:
```sql
select me.cpe_activar_produccion('{"serie_boleta":"B001","serie_factura":"F001"}'::jsonb);
```
Esto: setea las series en `mos.series_documentales` (se propaga a ME y a las cajas), **resetea el correlativo a 1** (producción empieza en 1 — el demo nunca fue a SUNAT), y prende `CPE_RECON_ON=1`.
- Si NubeFact YA tiene correlativos en esa serie (raro en 1er cutover), agrega `,"reset_correlativo":false`.

### 3) Validar con 1 boleta de prueba
Emite UNA boleta real (monto chico) en una caja online. Debe:
- Imprimir con **QR SUNAT real + Hash + "Autorizado mediante R.I. SUNAT"** (ya no "en proceso de envío").
- En el panel MOS → Tributario, verla **EMITIDO / aceptada por SUNAT**.
- Si queda PENDIENTE: revisar que el token/ruta sean correctos (el reconciliador reintenta cada hora igual).

### Rollback (si algo sale mal)
```
npx supabase secrets set NUBEFACT_TOKEN=<token_demo> NUBEFACT_RUTA=<ruta_demo> --project-ref rzbzdeipbtqkzjqdchqk
```
+ `update mos.config set valor='0' where clave='CPE_RECON_ON';`  (y volver las series demo si hizo falta).

## Lo que YA quedó listo (no tocas)
- Emisión ME→Edge→NubeFact (verificada). Modelo único de ticket (QR/hash). Trazabilidad fiscal en MOS. Reconciliador (gateado). Helper de activación `me.cpe_activar_produccion` (SQL 286). Lookup RUC/DNI (token ya puesto).
