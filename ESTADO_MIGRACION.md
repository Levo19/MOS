# 🧭 ESTADO DE LA MIGRACIÓN — léeme primero (handoff)

> **Punto de entrada único.** Si retomas esta conversación o cambiaste de modelo (p. ej. a Fable 5),
> lee SOLO este archivo para saber dónde vamos. Está escrito para ser autocontenido: no necesitas la
> memoria de Claude ni el historial. Última actualización: **2026-06-12**.

---

## 0. En una frase
Estamos sacando a **MosExpress (ME)** de Google Apps Script (GAS) y pasándolo a **Supabase**, paso a paso,
sin apagar nada en producción. Visión final del usuario: **"todo en Supabase, GAS ya no existirá"**.

- **Apps del ecosistema:** MOS (admin/master), warehouseMos (WH/almacén), MosExpress (ME/punto de venta).
- **Foco actual de la migración:** ME. WH y MOS migran después con el mismo patrón.
- **Stack:** Vue 3 (CDN, sin build) + GAS + Google Sheets → migrando a Supabase (Postgres + Edge Functions Deno).

## 1. Estrategia (cómo migramos sin romper)
Patrón **strangler-fig** con interruptores (feature flags):
1. **Sheets sigue siendo la fuente de verdad.** Supabase es una "sombra" que se llena en tiempo real (dual-write).
2. Cada responsabilidad de GAS se reescribe como **RPC de Supabase** o **Edge Function**, detrás de un **flag**.
3. Se prende el flag → la app escribe/lee directo a Supabase, con **fallback a GAS** si algo falla.
4. Cuando la sombra es 100% confiable, se retira GAS para esa pieza.

**Flags centrales** viven en la tabla `mos.config` (clave-valor). El frontend los lee por RPC `me.get_flags()`
(anónimo, sin token). Prender/apagar = un UPDATE en SQL. Patrón en frontend: `serverFlag || localStorage`.

## 2. ✅ LO QUE YA ESTÁ LIVE EN PRODUCCIÓN (flota completa)
- **Escritura directa de ventas NV** → `me.crear_venta_directa` (RPC). Flag `ME_ESCRITURA_DIRECTA=1`.
- **Impresión vía Edge Function** (PrintNode) → `supabase/functions/imprimir`. Flag `ME_IMPRESION_DIRECTA=1`.
  Validada en prod (impresiones reales, 0 duplicados).
- **Movimientos de caja directos** → `me.crear_movimiento_directo`. Usan el flag de escritura.
- **Red de seguridad del cierre** → reconciliación cada 10 min + al iniciar el cierre (rescata ventas que el
  dual-write best-effort pudo perder).
- **Numeración de correlativo** atómica e idempotente en Supabase (`me.siguiente_correlativo`).
- **Lecturas operativas** (estado de cajas, ventas del día por zona, cobros, créditos) ya leen de Supabase.
- **Frontend ME en producción: v2.8.4.**

### 🔴 KILL-SWITCH (si algo se ve raro en ventas)
```sql
update mos.config set valor='0' where clave='ME_ESCRITURA_DIRECTA';
```
Eso devuelve TODA la escritura de ventas a GAS al instante (sin redeploy). Para impresión:
`update mos.config set valor='0' where clave='ME_IMPRESION_DIRECTA';`

## 3. 🟢 LISTO PERO APAGADO (esperando algo del usuario)
- **CPE directo (boleta/factura electrónica)** → todo cableado en `supabase/21_fase2_cpe_directo.sql` +
  Edge Function `supabase/functions/emitir-cpe` (llama a NubeFact). Flag `ME_CPE_DIRECTO=0`.
  **Falta:** el **token de NubeFact** (el usuario aún no lo tiene). Cuando llegue: setear secret →
  verificar serie → prender flag → probar 1 boleta. Insight clave: en **boletas**, NubeFact devuelve el QR
  **al instante** (no espera a SUNAT, que valida async) → el CPE puede ser casi tan rápido como la NV.

## 3.5 🔍 REVISIÓN EXHAUSTIVA DEL SISTEMA (2026-06-12) — LEER ANTES DE SEGUIR
Se auditó TODO el ecosistema (5 áreas en paralelo + verificación manual). Resultado:
**6 CRÍTICOS · 16 ALTOS** documentados con archivo:línea en `REVISION_SISTEMA_2026-06-12.md`,
con plan de remediación en 4 lotes. Los peores: flujo de cobro de créditos ME sin lock (doble
cobro posible), cobros optimistas del frontend que nunca reconvergen, `crear_venta_directa` sin
validar caja/claims (en prod), router GAS de MOS sin auth en escrituras, capa CPE viva del lado
server con flag apagado. **La remediación de los lotes 1-2 tiene prioridad sobre seguir migrando**
(créditos-directo absorbe el fix del lock como parte del diseño).

## 4. ⏳ CABOS ABIERTOS / PRÓXIMOS PASOS
1. **Validar el PRIMER cierre real con ventas directas.** La red de reconciliación está desplegada pero aún no
   se ejecutó en un cierre real. → Cuando un cajero cierre caja, verificar que el monto cuadra.
2. **Activar CPE** cuando haya token NubeFact (paso 3 de arriba).
3. **Cajas-directo (apertura/cierre como RPC)** — es lo más *money-critical*; siguiente write-entity grande.
   Nota: `crear_venta_directa` aún NO valida caja abierta; cerrar ese gap al hacer cajas-directo.
4. **Créditos/cobros directo** — siguiente patrón sistemático (RPC + mirror + flag + frontend). Flujo ya leído
   en `gas/Creditos.gs`. **No empezado.**
5. **Lectura directa de ventas** (`ME_LECTURA_DIRECTA=0`) — aún NO segura (si una venta-GAS se cae de la sombra,
   el cajero la perdería y re-emitiría → duplicada). Habilitar recién cuando la sombra sea 100% confiable.
6. **Retirar GAS** pieza por pieza, y al final hacer a Supabase la fuente de verdad (el corte final).

## 5. 📇 Tarjeta de presentación (feature aparte, ya en prod)
Función para imprimir una tarjeta térmica con QR a WhatsApp (comunicación controlada con clientes/proveedores).
- **En ME (v2.8.4):** Herramientas → "📇 IMPRIMIR TARJETA" → modal Cliente/Proveedor → imprime por la infra Edge.
  Plan B si no hay impresora: muestra el QR en pantalla.
- **Cabecera bitmap diferenciada:** ícono (carrito=cliente / camión=proveedor) + banda negra con la palabra en
  blanco, dibujada en canvas→raster ESC/POS (nítida). Proveedor lleva marco blanco interior.
- **Números dinámicos** en `mos.config`: `TARJETA_WA_COMERCIAL`, `TARJETA_WA_COMPRAS`, `TARJETA_MARCA`.
  ⚠️ **Siguen en placeholder `51000000000` — falta poner los reales** (`update mos.config set valor='51...'`).
- **Edición desde MOS** (v2.43.200): MOS → Config → Infraestructura → "Tarjeta de presentación" (modal +51 fijo).
- ⚠️ **Por verificar con el usuario:** que la cabecera bitmap (GS v 0) imprima bien en su impresora. Si sale
  basura → fallback a ASCII.
- ⏸️ **Parkeado:** portar la tarjeta a WH (WH imprime por GAS, no por Edge → es un build aparte).

## 6. ✨ Modo Pro + tema de color (UX, ya en prod ME v2.8.4)
- **Atajos de teclado (PC):** Espacio=Cobrar→Confirmar/Imprimir, Esc=cerrar modal/limpiar granel, /=buscador,
  Alt+1/2/3=módulos. Autodetecta PC. Toggle en Herramientas.
- **Barra inferior auto-oculta:** se colapsa a una línea fina con colores de marca + dots de alerta; se expande
  al pasar el mouse (PC) / tocar (touch); se re-oculta ~5s. Activa también en tablet.
- **Tema de color por módulo:** `colorModulo` (POS verde `#10b981` / CAJA azul `#3b82f6` / TOOLS naranja `#ea580c`).
  El header y el nav adoptan el color del módulo activo.

---

## 7. 🗂️ Mapa de archivos clave
| Qué | Dónde |
|---|---|
| Frontend ME (todo en un archivo, ~16k líneas) | `C:\Users\ISO\Documents\MosExpress\index.html` |
| Service Worker ME (bump VERSION en cada deploy) | `C:\Users\ISO\Documents\MosExpress\sw.js` |
| Backend GAS ME | `C:\Users\ISO\Documents\MosExpress\gas\Code.gs` |
| Frontend/Backend MOS | `C:\Users\ISO\ProyectoMOS\js\app.js`, `gas\Code.gs` |
| SQL de migración (numerados) | `C:\Users\ISO\ProyectoMOS\supabase\*.sql` (último: `22_tarjeta_presentacion.sql`) |
| Edge Functions (Deno) | `C:\Users\ISO\ProyectoMOS\supabase\functions\imprimir` y `\emitir-cpe` |
| Proyecto Supabase (ref) | `rzbzdeipbtqkzjqdchqk` |

### Docs relacionados (este archivo los resume — entra a ellos solo si necesitas el detalle)
- `ROADMAP_SUPABASE_TOTAL.md` — el plan completo "retirar GAS por completo" (cada responsabilidad → su reemplazo).
- `PUNTO_DE_RETOMA.md` — checkpoint corto (versión anterior de este resumen).
- `MIGRACION_FASE2_PLAN.md` / `MIGRACION_FASE2_ROADMAP_READS.md` / `FASE2_WIRING_PENDIENTE.md` — detalle de Fase 2.
- `MIGRACION_RUNBOOK.md` — pasos operativos (cómo correr SQL, desplegar Edge Functions, etc.).
- `MIGRACION_SUPABASE.md` / `MIGRACION_SUPABASE_DICCIONARIO.md` — diseño general y diccionario de datos.

---

## 8. ⚠️ Reglas DE ORO al trabajar acá (respétalas siempre)
1. **App de DINERO en producción → máxima cautela.** Toda implementación pasa por una **revisión senior 20×
   adversarial** antes de declararse lista (estándar fijo del usuario).
2. **Vue 3 + prefijo `_`:** una propiedad accedida en el template a nivel raíz que empiece con `_` o `$` queda
   OCULTA por Vue → `ReferenceError` + pantalla en blanco. (Propiedades de objeto `item._x` sí están ok.)
3. **Bump del Service Worker** (`VERSION` en `sw.js` + `version.json`) en CADA cambio de frontend, o los cajeros
   siguen viendo la versión vieja.
4. **Deploy ME = git push** (GitHub Pages sirve estático). Sin `git push`, el usuario ve la versión vieja.
5. **Español NEUTRAL** (el usuario es peruano) — nunca voseo argentino. Vale para UI, toasts, commits y respuestas.
6. **Marca el punto de retoma:** al pausar o cambiar de tema, actualiza ESTE archivo (`ESTADO_MIGRACION.md`).
7. **Flags, no redeploys** para prender/apagar comportamiento: `update mos.config set valor='...' where clave='...'`.
8. **Idempotencia:** las escrituras directas dedupean por clave compartida directo↔GAS (evita filas duplicadas).
