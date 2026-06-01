# 🛰️ Roadmap — Espía v2.0

> Última actualización: 2026-06-01
> Versión actual: MOS `v2.43.104` · WH `v2.13.91` · ME `v2.7.42` · Backend GAS `@331`

---

## ⏳ PENDIENTE — Por prioridad

### 🥇 #1 · TURN server (NAT simétrico / CGNAT)
**Por qué importa**: ~10-30% de targets (datos móviles + redes corporativas) no conectan hoy. El código ya soporta TURN, solo falta config externa.

**Acción manual (no requiere código)**:
1. Crear cuenta gratis en https://www.metered.ca/tools/openrelay/ (0.5 GB/mes)
2. Editor Apps Script MOS → ⚙ Configuración del proyecto → Propiedades del script
3. Agregar 3 properties:
   - `ESPIA_TURN_URL` = URL del TURN (ej: `turn:a.relay.metered.ca:80,turn:a.relay.metered.ca:443?transport=tcp`)
   - `ESPIA_TURN_USER` = username de Metered
   - `ESPIA_TURN_CRED` = password de Metered
4. Listo. `espiaConfig` los devuelve automático al cliente.

**Costo**: gratis hasta 0.5 GB/mes. Si crece, $20/mes por 50 GB en Metered, o migrar a Twilio NTS (pay-per-use ~$0.40/GB).

**Verificación post-config**: probar espía con target en datos móviles. ANTES no conectaba, después debería.

---

### 🥈 #2 · Multi-target dashboard (espiar 2-3 zonas en grid)
**Por qué importa**: hoy es 1 modal por device. Supervisor con 3 zonas activas no puede vigilar simultáneo.

**Diseño**:
```
┌────────────────────────────────────────┐
│ 👁 SUPERVISIÓN — 3 dispositivos        │
├────────────┬──────────────┬────────────┤
│ Zona1      │ Zona2        │ Hotel Caja │
│ [cam]      │ [pantalla]   │ [cam]      │
│ GPS 📍     │ GPS 📍       │ GPS 📍     │
└────────────┴──────────────┴────────────┘
Click en cualquiera → expande full-screen
```

**Tiempo estimado**: ~6 horas dev.

**Costos**:
- Cada sesión consume su token HMAC + peer connection + sync poll
- Con `espiaSync` batch ya optimizado: 3 sesiones simultáneas ≈ 10k req/h. Cae bien en cuota gratis Apps Script (20k/día).
- En PC del supervisor: 3 streams = ~6 mbps de bajada + ~3 cpu cores. Aceptable en cualquier PC moderna.

**Riesgo**: medio. Refactor del modal `espiaV2Modal` para soportar N sesiones independientes en grid responsive.

---

### 🥉 #3 · Push-to-Talk: master habla al device por audio
**Por qué importa**: el espía hoy es **unidireccional** (master oye al device). Si querés dar instrucción urgente, hay que llamar por WhatsApp.

**Cómo funcionaría**:
- Botón `🎤 Hablar` en el modal del master (hold-to-talk)
- Master `getUserMedia({audio:true})` propio → `addTrack` al peer
- Cliente recibe el track de audio, lo reproduce en altavoz (no auricular)
- Mientras presionado: indicador visual ambos lados

**Tiempo estimado**: ~4 horas dev.

**Costos**: ninguno extra — el PC ya está bidireccional, solo no usábamos el sentido master→device.

**Consideración legal**: en algunos contextos laborales, comunicación bidireccional requiere disclosure al empleado. Verificar con jurídico antes de habilitar.

---

## ✅ YA IMPLEMENTADO (no requiere acción)

### #4 · Limpieza automática de chunks Drive
**Estado**: existe `cronLimpiarBufferEspia()` en `gas/EspiaWebRTC.gs:1236`. Borra chunks >7 días + purga sesiones zombi.
**Trigger**: `setupEspiaCleanupTrigger()` instala cron domingos 3AM.

**ACCIÓN PENDIENTE (verificar 1 vez)**:
- Editor Apps Script → Triggers (ícono ⏰ a la izquierda)
- Confirmar que `cronLimpiarBufferEspia` está listado con trigger "Time-driven · Week timer · Every Sunday 3AM"
- Si NO está: ejecutar manualmente `setupEspiaCleanupTrigger()` desde el editor (botón ▶)

---

## ❌ DESCARTADO

### #5 · Screenshot one-click + Grabación 30s on-demand
**Razón**: no encaja en el use case actual.

### Notificar al device que está siendo espiado
**Razón**: rompe el use case de auditoría real. Si el empleado sabe, cambia su conducta.

### Captura de keyboard del target
**Razón**: imposible desde PWA (browser no expone keystrokes del OS) + problemático laboral/legal.

### Geofencing con alertas auto
**Razón**: scope distinto al espía. Mejor módulo aparte si se quiere.

### iOS soporte completo
**Razón**: Apple bloquea sistemáticamente WebRTC + getDisplayMedia + Wake Lock en Safari. Inviable sin app nativa.

---

## 📌 ACCIONES MANUALES PENDIENTES (no es código)

| # | Acción | Tiempo | Crítico |
|---|---|---|---|
| 1 | Configurar TURN en Properties (3 strings) | 10 min | Sí — desbloquea 10-30% targets |
| 2 | Verificar trigger `cronLimpiarBufferEspia` activo | 2 min | Medio — Drive se llena en 6 meses sin esto |
| 3 | (Opcional) Rotar `ESPIA_HMAC_KEY` cada N meses | 1 min | Bajo — solo si sospecha de leak |
| 4 | (Opcional) Desactivar compat mode de HMAC tokens cuando todos los frontends hayan cacheado v2.43.90+ (~2 semanas tras último deploy) | 5 min | Bajo — más seguridad pero rompe frontends viejos |

---

## 📊 Métricas actuales del sistema

- **Endpoints del espía**: 19 (incluye batch sync, push batch, config, iniciarDispositivo, diagnóstico)
- **Versiones desplegadas**: MOS v2.43.104 · WH v2.13.91 · ME v2.7.42 · GAS @331
- **Cuota Apps Script consumida**: ~3-5k req/día por sesión EN_VIVO (estimado con sync batch)
- **TTL sesión**: PENDIENTE 10' / CONECTANDO 20' / EN_VIVO 60'
- **Cleanup chunks Drive**: 7 días retención (domingos 3AM)

---

## 🔍 Diagnóstico cuando algo falla

| Síntoma | Función a ejecutar en Apps Script editor |
|---|---|
| `POST 500` en cliente | `diagnosticarErroresEspia()` — agrupa excepciones por patrón |
| "Sin tokens FCM" | `reporteTokensEspia()` — qué devices tienen/no tienen token |
| "Sesión no encontrada" / cabeceras corruptas | `repararCabecerasSignaling()` |
| Sesiones zombi | `cronLimpiarBufferEspia()` (manual) |
| Ver chunks de un device | `espiaListarChunks` con `deviceId, desde, hasta` |
