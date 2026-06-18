# Plan — WH stock 100% Supabase (eliminar GAS de la escritura de almacén)

> Objetivo: `wh.stock` + `wh.ajustes` + cierre de guías = 100% Supabase, sin sync que se cruce.
> Estado: base construida (RPCs INERTES paso4 + cierre idempotente deployado + lecturas directas). Falta el cutover de escritura.
> ⚠️ Inventario/dinero de PRODUCCIÓN — migración por FASES con validación, NO de un golpe.

## Ya hecho (base)
- RPCs escritura directa WH INERTES y validadas (ingreso, ajuste, merma, cerrar_guia FIFO) — "WH escritura directa PASO 4".
- `wh.cerrar_guia_idempotente` (SQL 143) — delta-reconciliación, recerrar=0, 100% Supabase. ✅ deployado.
- pg_cron `wh-autocierre-inactividad` 30min (reemplazó al viejo buggeado). ✅
- Cron viejo `wh-autocierre` (70) DESAGENDADO (era la fuente de re-duplicación). ✅
- Lecturas de stock directas (getStock→wh.stock_enriquecido). ✅
- 79 duplicados limpiados + 47 Tipo1 alineados + LOPESA=216 estable.

## Falta (el cutover, por fases)
### Fase 1 — Migrar ESCRITURAS WH a Supabase (warehouseMos PWA)
- Que la PWA warehouseMos llame las RPCs directas (ingreso/ajuste/merma/cerrar) en vez de GAS.
- Patrón dual-write-frontend primero (GAS verdad + espejo) o directo-puro (requiere sync-off). Decidir.
- TODAS las escrituras de stock con cierre IDEMPOTENTE (cantidad_aplicada) para no duplicar.

### Fase 2 — Apagar el sync GAS de wh.* (WH_SYNC_OFF_TABLAS)
- Solo cuando la flota esté 100% en la versión nueva (un equipo viejo escribiendo a la Hoja con sync apagado = dato perdido — lección incidente proveedores 2026-06-15).
- Verificar que no quede ningún flujo que dependa de la Hoja como verdad.

### Fase 3 — Ajustes 100% Supabase
- `wh.ajustes` escrito directo (RPC crear_ajuste). Auditorías (conteo físico) → ajuste directo.
- Migrar el botón "ajustar" y "auditar" de la PWA a las RPCs.

### Fase 4 — Auditorías centralizadas (30/día por operador)
- Centralizar el flujo de auditoría obligatoria (almacenero/vendedor/cajero) → ajuste + log en kardex.

## ⚠️ ESTADO + LANDMINES (2026-06-17, sesión larga)
- Lecturas STOCK WH = Supabase ✅. Lecturas GUÍAS = aún Hoja (por eso la app muestra guías ABIERTA aunque Supabase=CERRADA).
- Escritura WH Fase 1 CONSTRUIDA INERTE en `warehouseMos/gas/EscrituraDirectaWH.gs` (gate `WH_ESCRITURA_DIRECTA` OFF + flags server `WH_*_DIRECTO`). El cierre idempotente GAS está en Guias.gs (NO pusheado).
- **LANDMINE 1 — guía ② `G1781445112212`**: CERRADA en Supabase (+LOPESA=216) pero **ABIERTA en la Hoja**. Si se pushea el cierre nuevo y se cierra desde la app, el backfill de la Hoja la trata como no-aplicada → re-aplica 59 líneas → re-duplica. **Reconciliar su `cantidadAplicada` en la Hoja ANTES de pushear** (o cerrarla en la Hoja primero de forma controlada).
- **LANDMINE 2 — apagar sync sin flota 100% o sin escritura/lectura directa**: app escribe a Hoja → con sync OFF no llega a Supabase = datos perdidos. ORDEN OBLIGATORIO: (1) app escribe+lee directo Supabase, (2) validar 1-2 ops, (3) flota 100%, (4) sync OFF.
- **LANDMINE 3 — cron viejo**: `wh-autocierre` (70) ya desagendado; vigilar que no haya OTROS crons/triggers GAS que re-cierren guías sin idempotencia.
- Red de seguridad activa: `mos.reconciliar_stock` nocturno + log master cazan cualquier cruce.

## PENDIENTE para "CERO GAS" (del audit 50x, 2026-06-17) — NO OLVIDAR
**Ya 100% Supabase (verificado):** escrituras WH (28/29 flags RPC), lecturas WH (stock/guías/dashboard/proyectado/envasado/reporte/lotes/mermas — @484 migró las últimas que leían Hoja vieja), sync Hoja→Supabase APAGADO (8 tablas), MOS módulo Zona (todas API.zona.* → mos.* RPCs, 0 GAS).

**Falta migrar (datos, por prioridad):**
1. **GAS-RELAY (paso grande final):** la PWA warehouseMos llama endpoints GAS (doPost) que relayean a Supabase. El DATO ya es Supabase, pero pasa por GAS como proxy. Cutover de cliente = reescribir api.js de la PWA para llamar PostgREST/RPC directo con JWT (`mintTokenWH`, app=warehouseMos) + RLS + mover orquestadores compuestos (cierre/envasado que resuelven catálogo en GAS).
2. **`WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO='0'`** — único flag de escritura apagado. RPC existe; activar tras validar (decisión dueño).
3. **PICKUPS / DEVOLUCIONES_ZONA / SESIONES / LOTES_HISTORIAL** — se escriben/leen de la Hoja sin sombra/RPC directa. Diseñar RPCs + sombra si se quieren mover (hoy la Hoja es su fuente; `wh.pickups` existe pero no se escribe por RPC ni está en sync-off).
4. **getAlertasStock** — deliberadamente en Hoja (patrón delete-y-reescribe; la sombra acumularía huérfanos). Necesita purga equivalente antes de flipear.

**Riesgos a vigilar (del audit):**
- **Triggers autocierre** (`cerrarGuiasAbiertasGlobal` 21h, `autocerrarGuiasInactivas` 15min): con gate ON usan RPC idempotente ✓; si el gate OFF o RPC falla, caen a Hoja+dual-write. Confirmar gate `WH_ESCRITURA_DIRECTA` y considerar `desinstalarTriggersAuditoriaWH()` tras corte total.
- **Acoplamiento de flags:** `WH_ESCRITURA_DIRECTA` + `WH_SYNC_OFF_TABLAS` no se validan entre sí. Si se prende escritura directa de una tabla NO listada en sync-off, el sync la revierte. Mantener las 8 tablas listadas.
- **`reconciliarWH` (GAS vieja)** compara Hoja vs Supabase por suma → marcará "drift" esperado (Hoja ya no recibe escrituras directas). IGNORAR; la red real es `mos.reconciliar_stock` (Supabase) + log master.

**Irreductible (NO son datos de stock, quedan en GAS/externo):** OCR guías (Claude), PrintNode (impresión etiquetas/tickets), push/FCM, Drive (fotos), espía WebRTC.

**Pendiente UX (no migración):** colores kardex (rojo=salida/DEC · verde=ingreso/INC · naranja=guía ABIERTA/pendiente) en WH y MOS zona · el "Log de errores" master debe mostrar SOLO estado=ABIERTA (hoy muestra RESUELTA stale, ej. LOPESA real 288 ya resuelto).

## Reglas duras (money-safety)
- Cada escritura con cierre/ajuste IDEMPOTENTE (clave única ref + cantidad_aplicada) → nunca duplica.
- No apagar el sync hasta flota 100%.
- Cada fase validada en vivo (1-2 operaciones) antes de la siguiente.
- El reconciliador nocturno (mos.reconciliar_stock) + botón master vigilan diferencias en todo momento.
