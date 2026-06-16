# Punto de retoma — Rediseño cutover ESCRITURA MOS (Fase 2/3 corregida)

Última sesión: 2026-06-15. Tras el ROLLBACK (el sync Hoja→Supabase pisaba las escrituras directas + read-back
stale = duplicación), se rediseñó el cutover con el patrón correcto y se **construyó TODO lo construible, INERTE**.

## ⚠️ ENFOQUE CAMBIADO A DUAL-WRITE (2026-06-15, decisión del usuario)
El enfoque "apagar-sync + escritura-directa" resultó FRÁGIL: un device en versión vieja escribe por
GAS→hoja ignorando el flag de servidor; con el sync apagado ese dato se pierde de la sombra. El 1er flip
en vivo (proveedores) se activó y revirtió en minutos al detectar el device del usuario en v2.43.193.
**Nuevo enfoque = DUAL-WRITE estilo ME (robusto ante flota mezclada):**
- **Escritura** sigue por GAS→hoja (verdad) para TODOS los devices; el handler GAS además ESPEJA a la
  sombra al instante (`_dualWriteMOS(tabla,obj)` best-effort vía `_sbOnce_`, byte-coherente con el sync).
  El sync NO se apaga (respaldo). El flag ya NO gobierna escritura.
- **Lectura** directa de sombra, gated por flag (solo lectura). Se activa por módulo CUANDO su dual-write
  esté probado fresco (comparar sombra vs hoja unos días). NO depende de que la flota actualice.
- ✅ Piloto proveedores: `_dualWriteMOS` + invocado en crearProveedorMaster/actualizarProveedorMaster
  (deploy @411, commit 8fc62e9). INERTE para el usuario (solo acelera la sombra). Falta: activar su
  lectura (flag) tras verificar frescura.
- **Replicar `_dualWriteMOS` a cada módulo restante** (pedidos/pagos-prov/provprod/gastos/jornadas/...)
  en su handler GAS de escritura, cada uno 40x. Luego activar su lectura.
- SW arreglado v2.43.219 (rollout network-first confiable; device pre-network-first requiere 1 unregister).

## PATRÓN ANTERIOR (apagar-sync) — DESCARTADO para escritura, pero la infra sirve
La lectura directa (RPCs `*_lista`) + heartbeat + resembrar siguen siendo útiles. Lo que se descarta es
"apagar el sync + escritura directa por flag". Mantener sync activo + dual-write.
Rollback dual-write: no aplica (la hoja siempre tiene el dato; el sync reconcilia).

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
