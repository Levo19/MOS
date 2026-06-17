# Pendientes — Cutover MOS hacia 100% Supabase (sacar GAS)

> Estado al 2026-06-17. Todo lo de abajo está CONSTRUIDO o ANALIZADO; falta ACTIVAR/terminar.
> Contexto completo en memoria: `architecture_mos_cutover_lecturas_faseDE_activo.md`.

## 1. Verificar (mañana, tras reset de cuota urlfetch ~2am Lima)
- [ ] Confirmar que el heartbeat se selló solo y las 56 lecturas directas van rápido.
- [ ] Si sigue lento: correr `syncMOSReciente` una vez en el editor de GAS.
- [ ] Confirmar que Fase 0 (sync incremental) redujo el urlfetch (no volver a reventar la cuota).

## 2. Activar DUAL-WRITE-FRONTEND (ya construido inerte, gated OFF)
Patrón seguro (GAS verdad + espejo a Supabase, sin apagar sync). Runbook: `RUNBOOK_cutover_escritura_proveedores.md`.
Por cada módulo: prender flag frontend `<mod>DualWrite` + kill-switch server `MOS_<MOD>_DIRECTO='1'`.
- [ ] proveedores (piloto no-dinero — empezar por acá, validar en vivo)
- [ ] pedidos (solo crearPedido)
- [ ] proveedor-producto (agregar/actualizar)
- [ ] gastos ⚠️dinero (validar idempotencia local_id antes)
- [ ] jornadas ⚠️dinero
- [ ] evaluaciones

## 3. Completar lo omitido (faltan RPCs / cases)
- [ ] `actualizarPedido` — falta case en router GAS (Code.gs) + usar RPC `mos.actualizar_pedido_proveedor` (ya existe).
- [ ] `eliminarProductoProveedor` — falta RPC `mos.eliminar_proveedor_producto` + branch en `_postDirectoMOS`.
- [ ] `importarJornadasDesdeCajas` — falta RPC `mos.importar_jornadas`.

## 4. DINERO MÁXIMO (sesión dedicada, con paridad 100% validada)
- [ ] liquidaciones: `marcarPagos` (shape `fechas[]` vs `dias[]` + snapshot cross-app), `anularPago` (exige clave admin server-side → portar verificación o dejar el gate en GAS).
- [ ] vetar/desvetar liquidación día (RPCs existen, SQL 86).

## 5. Lecturas ME pendientes (shape incierto del bridge ME)
- [ ] meHistorialVenta / meHistorialCliente / meHistorialExtra — confirmar shape real del bridge ME antes de portar.

## 6. Final — eliminar GAS del todo (capa datos)
- [ ] Corte de la Hoja: solo cuando dual-write esté activo y validado en vivo en TODOS los módulos.
- [ ] Mover el sello del heartbeat fuera de GAS (pg_cron o señal de frescura por dato) → que la frescura NO dependa del urlfetch de GAS.

## 7. NO portables (quedan en GAS / externos por diseño)
PrintNode (impresión), NubeFact/CPE (facturación electrónica), OCR/IA (Claude API), espía/audio/GPS, push FCM, clave admin bcrypt. Requieren reescritura fuera de Google si algún día se quieren mover.
