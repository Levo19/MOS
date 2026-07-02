# 📋 POR TERMINAR — Cierre/Cobro cero-GAS (retomar 2026-07-03)

> Contexto completo en `PUNTO_DE_RETOMA_cajas_cutover.md`. Este doc es solo la lista de pendientes.
> Estado hoy (2026-07-02): CIERRE cero-GAS **desplegado y live** (ME v2.8.118, SQL 27/315/318/319).
> Todo probado en ROLLBACK + 2 rondas 500x. Falta 1 verificación de campo + el "tail" de cobro.

---

## ✅ A. VERIFICACIÓN DE CAMPO — lo que TÚ debes hacer (rápido, sin riesgo)

### A1. Confirmar que el cierre corre cero-GAS (1 cierre real)
1. Abre una caja, hace 1–2 ventas normales (con productos que descuenten stock), y **cierra la caja** como cajero en MosExpress.
2. Anota el id de la caja (algo como `CAJA-17xxxxxxxxxx`).
3. Dime el id (o corre esta consulta en la DB) — quiero ver que aparezcan estos DOS:
   ```sql
   select id_pickup from wh.pickups        where id_pickup = 'PK-VENTAS-<CAJA>';
   select 1         from me.guias_cabecera where id_guia    = 'G-VENTAS-<CAJA>';
   ```
   - **Aparecen `PK-VENTAS` + `G-VENTAS`** → el cierre es 100% cero-GAS ✅ (lo esperado).
   - **Aparece `PCK-CC-<CAJA>`** → cayó al fallback GAS (hay que revisar por qué el directo no corrió: token/timeout). **Avísame y lo diagnostico.**
   - En CUALQUIER caso NO hay doble descuento ni doble pickup (guards + idempotencia probados).

### A2. Confirmar el descuento de stock (opcional, refuerza A1)
Tras el cierre de A1, revisa que el stock de la zona bajó por lo vendido:
```sql
select * from me.stock_movimientos where ref_id like 'VENTA-CAJA:<CAJA>:%';
```
Debe haber 1 fila por producto vendido, con `delta` negativo. Si está vacío pero hubo ventas → avísame.

### A3. (Ya pendiente de antes) Smoke visual del "asignar cobro" (308)
Asigna un cobro desde MOS y confirma en la pestaña Network del navegador que llama a
`asignar_cobro_cajero` (Supabase), no a GAS. Solo es verificación, riesgo bajo.

---

## 🔨 B. LO QUE FALTA IMPLEMENTAR — "tail" cero-GAS del COBRO (para mañana)

> El cobro PRINCIPAL (`confirmarCobrarAsignado`) y el CIERRE **ya son cero-GAS**. Lo de abajo son
> flujos de **baja frecuencia** que siguen usando GAS (todos con fallback, así que funcionan hoy).
> Los dejé sin cortar a propósito: necesitan RPC directa nueva + verificar auth, y no quise
> improvisar sobre el monolito de dinero sin su propia validación. Orden sugerido por valor/riesgo:

### B1. `adminConfirmarCobrar` → `me.cobrar_credito_directo` (314) — **LISTO PARA CABLEAR**
- La RPC directa **ya existe y está probada** (SQL 314). Solo falta cablearla en ME.
- ⚠️ **Antes de cablear:** verificar que 314 replica el chequeo de **PIN admin** que hace el GAS
  (`COBRAR_CREDITO_CON_EXTRA` pasa `adminAuth`). Si el GAS valida PIN y 314 no → cablear sería
  saltarse la auth (regresión de seguridad). Hay que leer el handler GAS y decidir: agregar la
  validación de PIN a 314, o confirmar que no aplica.
- Esfuerzo: bajo-medio. Es el de mayor valor del tail.

### B2. `confirmarRechazarAsignado` (RECHAZAR_COBRO_ASIGNADO) — nueva RPC
- Construir `me.rechazar_cobro_asignado` (flip cobro→RECHAZADO + la venta se queda CREDITO + notif).
- Cablear en ME con fallback GAS. Esfuerzo: bajo (es simple).

### B3. `COBRAR_VENTA` / `CREDITAR_VENTA` — nuevas RPCs (el grupo más grande)
Flujos que hoy van por `_enviarMutacionDinero` (con cola offline), sin RPC directa:
- `procesarCobroPendiente` (cobrar un ticket pendiente) → COBRAR_VENTA
- `confirmarMoneda` / `revertirCobro` / `revertirCobroDesdeModal` → COBRAR_VENTA
- `confirmarCredito` → CREDITAR_VENTA
- ⚠️ Cuidado: tienen **semántica de cola offline** (se encolan si no hay red). La RPC directa debe
  respetar eso (idempotencia por local_id). Es el trabajo más delicado del tail.
- Esfuerzo: medio-alto. Hacer con su propia revisión 500x.

### B4. Startup yesterday-close (`index.html` ~línea 8988) — cleanup aparte
- Cierre automático de una caja olvidada de ayer, dispara `CIERRE_CAJA` GAS con `montoFinal:0`.
- No pasa por el directo → no corre los efectos server-side. Es un caso raro (caja dejada abierta).
- Decidir: enrutarlo a `me.cerrar_caja` directo, o dejarlo (bajo riesgo). Esfuerzo: bajo.

### B5. (Final, cuando B1–B4 estén) — retirar los fallbacks GAS del cobro
- Una vez cada flujo tenga RPC directa probada, retirar los `fetch(API_URL...)` de cobro que quedan
  y decomisar los handlers GAS (`cobrarCreditoConExtra`, `confirmarCobroAsignado`, etc.). Acción
  grande e irreversible → hacerla al final, supervisada, con verificación de campo previa.

---

## 🛟 C. KILL-SWITCHES (si algo sale mal en producción)

Todo es reversible sin deploy, solo flags en `mos.config`:
```sql
-- revertir el cierre directo del cajero (vuelve a GAS por el fallback):
update mos.config set valor='0' where clave='ME_CIERRE_DIRECTO';
-- revertir cobro directo / cierre forzado:
update mos.config set valor='0' where clave in ('ME_COBRO_DIRECTO','ME_CIERRE_FORZADO_DIRECTO');
```
El fallback GAS síncrono sigue en el frontend, así que apagar el flag = cierre por GAS como antes.

---

## 📌 Referencia rápida — qué quedó LIVE hoy
- **ME v2.8.118** (frontend) · **SQL 27, 315, 318, 319** (backend, aplicados a prod).
- Cierre cajero: `me.cerrar_caja` corre server-side descuento stock + guía + pickup + cancela cobros
  ASIGNADO, atómico e idempotente. Mirror GAS retirado; fallback GAS mantenido.
- Backend probado: paridad de dinero, efectos completos, sin doble-pickup, sin deadlock, sin regresión.
