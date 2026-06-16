# Punto de retoma — Rediseño cutover ESCRITURA MOS (Fase 2/3 corregida)

Última sesión: 2026-06-15. Tras el ROLLBACK (el sync Hoja→Supabase pisaba las escrituras directas + read-back
stale = duplicación), se rediseñó el cutover con el patrón correcto y se **construyó TODO lo construible, INERTE**.

## EL PATRÓN (validado, piloto = Gastos)
Para flipear un módulo a directo, las 3 cosas van JUNTAS:
1. **Lectura directa** (RPC `*_lista` sobre la sombra) — cierra el read-back stale.
2. **Escritura directa** (flag `MOS_*_DIRECTO='1'`) + **heartbeat-por-escritura** (`mos._tocar_latido_sync()`).
3. **Apagar el sync de esa tabla** (`MOS_SYNC_OFF_TABLAS` += tabla) — sino la hoja la pisa.
Gate de frescura: `_fresh` (heartbeat MOS_SYNC_HEARTBEAT, TTL 30min). Sombra stale → cae a GAS (seguro).
Rollback: `resembrarHojaDesdeSombra(tabla)` (append-only por PK).

## CONSTRUIDO (INERTE — flags en '0', MOS sigue 100% GAS)
- `83_mos_gastos.sql` — piloto gastos: sync-off mecanismo + heartbeat-por-escritura + resembrar. (commit 01add7e)
- `MigracionMOS.gs` — `_mosSyncOffTablas`/`apagarSyncTablaMOS`/`prenderSyncTablaMOS`, `resembrarHojaDesdeSombra`,
  `_syncMOSImpl` respeta sync-off. deploy @406.
- `93_mos_resumen_dia.sql` — **mos.resumen_dia(fecha,idPersonal)**: porta el recompute cross-app de jornales
  (_calcularKpisAutoDia, lee me.ventas/cajas + wh.envasados/sesiones). Paridad 160/160 EXACTA vs sombra.
  Comparador `compararResumenDiaMOS_multi()` en MigracionMOS.gs (deploy @408). (commit b1b8a0f)
- `94_mos_lecturas_proveedores_jornadas.sql` — 5 RPCs lectura (proveedores/pedidos/pagos-prov/provprod/jornadas)
  + heartbeat-por-escritura en sus 9 RPCs de escritura (81/84). Shape == _MOS_SPECS. (commit b6c96f9)
- `js/api.js` — wiring frontend de las 5 lecturas, gated por el flag del módulo, fallback _fresh→GAS.
  SW 2.43.217. (commit e2d4a07)

=> Cada módulo NO-DINERO (proveedores/pedidos/pagos-proveedor/provprod/jornadas) + gastos está a **UN FLIP**
de distancia: lectura+escritura+heartbeat listos; solo falta encender flag + sync-off (acción del usuario).

## PENDIENTE — lo valida/activa el USUARIO (lección del rollback: no apurar dinero)
### Validaciones previas a cualquier flip
- [ ] Correr en editor GAS: `compararResumenDiaMOS_multi(['2026-06-12','2026-06-13','2026-06-14'])` → validación
      Sheets↔Supabase definitiva del recompute de jornales (la lógica SQL ya es exacta vs sombra; falta confirmar
      sombra vs hoja, que depende de que los triggers de sync estén vivos).
- [ ] Estabilizar sync que mantiene la sombra fresca: `instalarTriggersSyncMOS()` + `setupLiqSyncTrigger()`
      (syncMOSCompleto venía 57% err, _liqSyncJob 47% err — heartbeat stale → todo cae a GAS).
- [ ] Validación física del piloto gastos (flip + crear/eliminar gasto + verificar no duplica + resembrar).

### Flips por módulo (orden recomendado, uno por uno con validación)
1. Gastos (piloto, ya construido)  2. Proveedores  3. Prov-producto  4. Pedidos  5. Pagos-proveedor
6. Jornadas → 7. Catálogo escritura (Fase B)  8. Etiquetas/Horarios/Evaluaciones (Fase C, caveats)
9. **Jornales/Liquidaciones/Pagos-jornal (Fase D)** — usa mos.resumen_dia; el más delicado (DINERO).
10. **Fase E**: apagar sync triggers globalmente + pg_cron (cuando TODOS los módulos estén directos).

### Falta construir (tandas futuras)
- `resembrarHojaDesdeSombra` probado para cada tabla (hoy genérico, validar PK por tabla).
- Cutover escritura catálogo (Fase B) — su lectura ya está viva.
- Fase D: wiring de jornales/liquidaciones usando mos.resumen_dia + materialización directa.

## CRÉDITOS A ROTAR (usuario, diferido): Supabase PAT `sbp_*` + Anthropic `sk-ant-*`. NO rotar WH_JWT_SECRET.
