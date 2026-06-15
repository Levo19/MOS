# Autorización & Roles del ecosistema MOS — análisis + diseño de centralización en Supabase

> Pedido del usuario (2026-06-13): centralizar y profesionalizar el modelo de autorización. Jerarquía
> operador < admin < master (acumulativa). Admin = escalón superior con poderes especiales sobre operadores/
> vendedores; master = todos los poderes. PIN admin DINÁMICO 8 díg = 4 global + 4 personal → identifica QUÉ
> admin autoriza (auditoría). "Que siempre se tenga presente" → memoria [[architecture_autorizacion_roles]].

## 1. Cómo funciona HOY (estado real)
- **Validador único**: `verificarClaveAdmin(params)` en MOS `gas/Seguridad.gs:189`. WH y ME NO validan: delegan por
  HTTP a MOS (`warehouseMos/gas/Auth.gs:11`). MOS es el árbitro central de autorización. ✅ (ya está centralizado el QUIÉN valida).
- **PIN 8 díg**: `clave.substring(0,4)` = global (`CONFIG_MOS.ADMIN_GLOBAL_PIN`), `substring(4,8)` = personal.
  `_buscarAdminPorPin(personal)` (Seguridad.gs:169) busca en PERSONAL_MASTER un rol ADMIN/MASTER, estado='1', pin=coincide
  → devuelve {idPersonal, nombre, rol}. Así se sabe QUÉ admin autorizó.
- **Roles**: `PERSONAL_MASTER.rol` (OPERADOR/ADMIN/MASTER). Helper `_esRolAdmin` (Seguridad.gs:108) = rol ∈ {MASTER,ADMIN,ADMINISTRADOR}.
- **Catálogo de acciones protegidas**: `_AUTH_CATALOGO` (Seguridad.gs:118), hardcoded: `{accion:{tier,label}}`.
  tier1=rutina(cache 10min), tier2=sensible(cache 5min), tier3=crítico(sin cache, clave siempre).
- **Auditoría**: hoja `AUDITORIA_ADMIN` (MOS) con idAccion/fecha/accion/refDocumento/idPersonalAutoriza/nombreAutoriza/
  appOrigen/dispositivo/tier/deviceId/cliente_meta. Registrada por verificarClaveAdmin al autorizar.
- **Seguridad/aprobaciones**: SEGURIDAD_ALERTAS (dispositivos pendientes/suspendidos, desbloqueos, horarios) +
  DISPOSITIVOS.Permisos_JSON + triggers de reversión. Ver [[project_seguridad_sistema]].
- **Estado Supabase**: existen sombras `mos.personal`, `mos.config`, `mos.seguridad_alertas`, `mos.dispositivos`
  (+ bloqueos_usuario, config_horarios_apps), pero **Sheets es la fuente de verdad**. La VALIDACIÓN de PIN y el
  catálogo viven SOLO en GAS. No hay RPC de autorización en Supabase.

## 2. Lo que YA está bien (no romper)
- Validación centralizada en un solo punto (MOS). El modelo 4+4 con identificación del admin es sólido y bien pensado.
- Tiers con cache razonable + auditoría con metadatos ricos. Rotación de PIN global. Sistema de alertas/aprobaciones maduro.

## 3. Debilidades a mejorar (⚠ = confirmar en código antes de tocar)
1. **PIN en texto plano** en PERSONAL_MASTER/mos.personal.pin y ADMIN_GLOBAL_PIN. Quien vea la tabla ve todos los PINs.
2. **Validación en GAS, no en Supabase** → para GAS-cero, WH/ME no pueden autorizar sin MOS-GAS vivo. Falta RPC central.
3. **Catálogo `_AUTH_CATALOGO` hardcoded** en GAS (un solo archivo, una app) → no consultable por las apps directo.
4. ⚠ **Acciones sin chequeo de clave** (reportado por el mapeo, CONFIRMAR): `anularVentaIndividual` (ME Caja.gs),
   `crearCreditoDirecto`/`convertirACredito` (ME Creditos.gs) parecen no exigir `verificarClaveAdmin`. Verificar uno por uno.
5. **Auditoría dispersa**: MOS AUDITORIA_ADMIN + logs locales en WH/ME. Falta una sola tabla central.
6. **Rol como string libre** (sin enum/jerarquía numérica) → comparaciones ad-hoc; no se enforza nivel mínimo por acción.
7. **Sin RLS por rol** en Supabase (cuando se lea/escriba directo, falta gate por nivel de rol).

## 4. Diseño propuesto (centralizado y profesional en Supabase)
Principio: **una fuente de verdad de autorización, consultable por las 3 apps, con jerarquía explícita y auditoría única.**

### 4.1 Jerarquía de roles explícita
`mos.rol_nivel(rol text) -> int`: OPERADOR/VENDEDOR/ALMACENERO=1, ADMIN=2, MASTER=3. Acumulativa: nivel(actor) >= nivel_requerido.
(O tabla `mos.roles(rol, nivel, descripcion)` para no hardcodear.)

### 4.2 Catálogo de acciones en tabla
`mos.permisos_accion(accion text pk, tier int, nivel_minimo int, label text, app text)`. Reemplaza `_AUTH_CATALOGO`.
Seed con las acciones actuales (CIERRE_CAJA_FORZADO=tier3/master?, REABRIR_GUIA=tier1/admin, ANULAR_VENTA, CREDITO_*, APROBAR_DISPOSITIVO_*, etc.).
Las 3 apps leen el mismo catálogo → consistencia. Versionable sin tocar código.

### 4.3 RPC central de autorización (GAS-cero)
`mos.verificar_clave_admin(p_clave text, p_accion text, p_ref text, p_app text, p_device text) -> jsonb`:
1. valida formato 8 díg; separa 4+4.
2. global = `mos.config ADMIN_GLOBAL_PIN` (o su hash); personal → busca en `mos.personal` rol nivel>=2, estado activo, pin coincide.
3. lee `mos.permisos_accion[p_accion].nivel_minimo`; exige `rol_nivel(admin.rol) >= nivel_minimo` (admin vs master-only).
4. inserta en `mos.auditoria_admin` (única). 5. devuelve {autorizado, validado_por, id_personal, rol}.
Gate de claim por app (reusar `me.jwt_app()`/`wh._claim_ok()` patrón). Las 3 apps la llaman DIRECTO (sin MOS-GAS).

### 4.4 PIN hasheado (mejora de seguridad — OPCIONAL, requiere decisión)
`pgcrypto`: guardar `pin_hash` (bcrypt) en vez de texto. Validar con `crypt(p_pin, pin_hash)`. Global idem.
Implica: edición de PIN re-hashea; rotación re-hashea; el panel admin nunca muestra el PIN. Es la mejora más fuerte
de seguridad pero la más invasiva (cambia creación/edición/rotación en MOS). Por eso requiere tu OK explícito.

### 4.5 Auditoría única
`mos.auditoria_admin` (tabla) como destino de TODA autorización (las 3 apps vía la RPC). Append-only. Las hojas quedan de histórico.

## 5. Plan por fases (cada una INERTE + 40x, reversible)
- **F0**: tablas/funciones de soporte INERTES: `mos.roles`/`rol_nivel`, `mos.permisos_accion` (seed), `mos.auditoria_admin`. No tocan nada vivo.
- **F1**: RPC `mos.verificar_clave_admin` que REPLICA exacto a `verificarClaveAdmin` de GAS (mismo desglose 4+4, misma búsqueda,
  misma auditoría) leyendo `mos.personal`/`mos.config`. Validar PARIDAD vs GAS (mismos casos: ok admin, ok master, global mal,
  personal inexistente, rol insuficiente) con tx-rollback. INERTE (nadie la llama aún).
- **F2**: WH/ME (y MOS) llaman la RPC directo, con FALLBACK al `verificarClaveAdmin` GAS por flag. Cutover gradual.
- **F3** (opcional, tu decisión): hashear PINs (pin_hash) — migración con doble-lectura hasta confirmar.
- **F4**: cerrar brechas confirmadas (acciones tier2-3 sin clave) — exigir la RPC en cada endpoint.

## 6. DECISIONES TOMADAS (2026-06-13)
1. **Hashear PINs**: SÍ (bcrypt/pgcrypto). El usuario entendió el matiz (4 díg = mejora vs texto plano, no blindaje fuerte) y confirmó.
2. **Brechas (acciones sin clave)**: revisar APARTE después (primero la infra central).
3. **Niveles**: definidos juntos → **5 master-only** (REVOCAR_DISPOSITIVO, APROBAR_DISPOSITIVO_INSITU_MOS, PURGAR_CATALOGO,
   BAJA_CPE, ROTAR_PIN_GLOBAL); **resto = admin**. Las 3 dudosas (CIERRE_CAJA_FORZADO, BLOQUEAR/LIBERAR_DISPOSITIVO,
   CONVERTIR_NV_A_CPE) = admin. Modelo **CASCADA**: master (nivel 3) puede TODO lo de admin; nivel_minimo por acción.

## 6.bis ESTADO DE IMPLEMENTACIÓN
- ✅ **F0 (49_mos_autorizacion_f0.sql, 11/11)**: `mos.rol_nivel()` (MASTER=3/ADMIN=2/resto=1, fail-safe) + `mos.auditoria_admin`
  (tabla única append-only) + pgcrypto confirmada (hash bcrypt valida/rechaza OK).
- ✅ **F0.2 (50_mos_permisos_accion.sql, 8/8)**: tabla `mos.permisos_accion` sembrada con 36 acciones (5 master + 31 admin),
  reemplaza `_AUTH_CATALOGO` de GAS. Cascada validada.
- ✅ **F1 (51_mos_verificar_clave_admin.sql, 12/12)**: PINs HASHEADOS (bcrypt en `extensions` schema → calificar `extensions.crypt`/
  `gen_salt` porque la RPC tiene search_path=''): `pin_hash` en mos.personal + `ADMIN_GLOBAL_PIN_HASH` en mos.config, poblados
  desde texto plano (lpad 4 = padStart de GAS). RPC `mos.verificar_clave_admin(p_clave,p_accion,...)`: gate `wh._claim_ok()`,
  8 díg, global(hash) + admin por pin personal(hash, rol_nivel>=2, estado activo), chequeo `rol_nivel >= permisos_accion.nivel_minimo`
  (cascada), auditoría única `mos.auditoria_admin`. PARIDAD vs GAS validada (admin autoriza+identifica, global mal/personal inexistente/
  clave corta rechazan) + MEJORA (admin→master-only=NIVEL_INSUFICIENTE, master cascada) + gate (mosExpress rechazado).
  ⚠️ DEUDA para F2/F3: (1) si ADMIN_GLOBAL_PIN rota o un pin cambia, hay que RE-HASHEAR (el insert es `on conflict do nothing`;
  la edición/rotación de PIN debe regenerar el hash). (2) el texto plano `pin`/`ADMIN_GLOBAL_PIN` sigue existiendo (GAS lo usa);
  eliminarlo recién cuando F2 esté activo en las 3 apps.
- ✅ **AUDITORÍA 40x ADVERSARIAL (2026-06-13, revisor independiente)** sobre 46-52. Hallazgos REALES cerrados:
  - 🔴 CRÍTICA: `mos.auditoria_admin`/`mos.permisos_accion` creadas tras el loop RLS de 04 → SIN RLS, y auditoria_admin con
    insert/select a `authenticated` → cualquier token podía FORJAR/LEER la auditoría. **FIX (53): enable RLS + revoke** (8/8 validado:
    authenticated bloqueado insert+select, RPC definer sigue OK). ⚠️ REGLA: toda tabla mos.* nueva creada después de 04 DEBE
    `enable row level security` explícito (el loop de 04 no la cubre).
  - 🟡 MEDIA: catálogo exponía PINs (to_jsonb personal) → **FIX (48): `- 'pin' - 'pin_hash'`**. Y datos bancarios proveedores
    (numero_cuenta/cci) → **FIX (48): excluidos**. Ambos validados.
  - ✅ RPC `verificar_clave_admin` AUDITADA SÓLIDA: sin path de bypass, fail-closed ante hash/rol null, cascada correcta,
    auditoría no bloqueante bien aislada, sin oráculo de enumeración (timing-oracle baja, aceptable). 46 inyección OK (whitelist+%I).
  - DEUDA baja documentada: `mos.personal.pin` texto plano residual (RLS service_role-only lo mitiga; borrar tras F2). + `get_guia_rls` (52) agregada.
- ⏳ **F2**: WH/ME/MOS llaman la RPC directo con fallback a GAS por flag. El `adminPin` del blocker del catálogo WH (reabrir guía)
  va por esta RPC (acción REABRIR_GUIA). ⏳ **F4**: cerrar brechas confirmadas (revisión aparte).

## 7. Relación con el blocker del catálogo (descargarMaestros)
El `adminPin` que `descargarMaestros` buscaba en la estación ALMACEN **NO debe migrarse** — es este PIN dinámico 4+4.
La reapertura de guías en WH debe llamar la RPC `mos.verificar_clave_admin` (acción REABRIR_GUIA), no un pin de estación.
→ Al extender `mos.catalogo_wh_rls()` a maestros, OMITIR adminPin; la autorización va por la RPC central.
