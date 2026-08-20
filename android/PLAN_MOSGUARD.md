# 🛡️ MosGuard — plan vivo

> El hermano mayor: **Spy 2.0 + YapeCaptor en un solo APK**, más resguardo del propio celular
> (ubicación, foto, video en vivo — sin audio por defecto).
> Estado: **PLAN / no codificado**. Nace de esta conversación (2026-08-19).

---

## 0. La idea en una frase

Un solo servicio Android, persistente y difícil de matar, que **captura los Yapes del equipo**
(lo que ya hace YapeCaptor) **y** deja que el dueño, desde MOS, **vea el celular en vivo** si se
pierde o se lo roban — cámara y ubicación **directo P2P, sin depender de una web** para el video.

## 1. Por qué UNA sola app (no dos)

- **No es rendimiento** — un servicio más no pesa nada.
- **Resistencia al robo/kill**: dos apps = dos íconos, dos cosas que whitelistar en batería, dos
  servicios que Android/Doze mata por separado, dos cosas que se pueden desinstalar. **Una app
  blindada sobrevive mejor.**
- **Continuidad legítima**: Spy 2.0 ya hace monitoreo autorizado (equipos propios) en esos mismos
  celulares. MosGuard no agrega una capacidad nueva prohibida: unifica dos cosas que ya conviven.

## 2. La regla de oro (para no romper la plata)

La captura de Yapes toca **dinero**. MosGuard debe garantizar que un bug del módulo de
cámara/video **jamás** tumbe la captura:

- **`YapeListener` + cola + ingesta corren en su propio proceso** (`android:process=":captor"`).
  Un crash del guard vive en otro proceso y no lo arrastra.
- El **latido** (`Latido.kt`) queda en el proceso principal y reporta salud de AMBOS módulos.
- Migración sin cortar: el YapeCaptor actual sigue en producción; MosGuard se prueba en paralelo y
  recién cuando está sólido se reemplaza en los equipos. **Cero día sin captura de Yapes.**

## 3. El candado legal (heredado de LevoGuard — innegociable)

- **Ubicación (GPS) + foto**: OK sin gate (equipo propio).
- **Video en vivo**: **MUDO por defecto** (video sí, micrófono no).
- **Audio**: GATED — solo con `authorized_mode=1`, habilitado desde MOS con una referencia legal
  (denuncia / orden). Igual que el `/authorize` de LevoGuard. No se prende "por si acaso".
- **Screenshot remoto silencioso**: Android NO lo permite sin MediaProjection (muestra diálogo) o
  Device Owner. Fuera del alcance salvo que se decida provisionar el equipo como Device Owner.

## 4. Arquitectura — qué hereda de cada lado

```
                         MosGuard (dev.levo.mosguard)
        ┌───────────────── proceso principal ─────────────────┐
        │  GuardiaService  ·  Latido  ·  BootReceiver  ·  Prefs │   ← motor YapeCaptor (ya probado)
        │  Actualizador (auto-update)                          │
        │  GuardService (nuevo): GPS + foto + señalización     │   ← de LevoGuard + Spy 2.0
        └──────────────────────────────────────────────────────┘
        ┌──────────────── proceso :captor ────────────────────┐
        │  YapeListener  ·  Cola  ·  ColaService               │   ← dinero, aislado
        └──────────────────────────────────────────────────────┘
```

**De YapeCaptor (reusar tal cual):** GuardiaService (wakelock+wifilock+keepalive), Latido
(alarma 10 min), BootReceiver (re-atar tras reinicio/update), Cola en disco, Actualizador
(auto-update desde releases/latest), firma estable (mismo keystore = updates sin desinstalar),
backend Supabase (`yape_dispositivos`, `yape_latido`).

**De Spy 2.0 (reusar la señalización):** el intercambio WebRTC (oferta/respuesta/ICE) ya existe y
está probado. MosGuard lo reusa para el video; **el stream va P2P celular→tu pantalla**, no por una
web. La señal de "encontrarse" viaja por **Supabase Realtime** (que MOS ya usa) — no hace falta
ningún servicio nuevo. Solo un **TURN server** (metered.ca gratis 0.5 GB/mes) como relay para el
10-30% de casos en datos móviles/CGNAT donde el P2P directo no pasa.

**De LevoGuard (el diseño ya escrito):** estado robado/normal, evidencia sellada (SHA-256 + hora
servidor), el gate `authorized_mode`, el dashboard con mapa.

## 5. Dónde se maneja (el dueño)

Un panel **MosGuard dentro de MOS** (junto a 💜 Yapes en Configuración, o su propia entrada):
- lista de equipos con su último latido y ubicación en un mapa;
- botón **"Ver en vivo"** → abre el video P2P (cámara trasera/frontal, mudo);
- botón **"Marcar robado"** → el equipo empieza a mandar ubicación seguido + una foto;
- el toggle **audio** aparece bloqueado con candado hasta cargar la referencia legal.

## 6. Permisos nuevos (solo los que hagan falta, por fase)

| Fase | Permiso | Para |
|------|---------|------|
| 1 | `ACCESS_FINE_LOCATION` (+ background) | GPS real |
| 1 | `CAMERA` | foto frontal/trasera al marcar robado |
| 2 | `FOREGROUND_SERVICE_CAMERA` | video en vivo |
| gated | `RECORD_AUDIO` | audio — SOLO tras authorized_mode |

Cuantos más permisos pide una app, más la vigila MIUI/Play Protect y más la mata: por eso van
**por fase**, no todos de golpe.

## 7. Fases (de más valor / menos riesgo a más)

- **Fase 0 — Refactor motor.** Renombrar a `dev.levo.mosguard` (nuevo applicationId = instalación
  nueva, sin pisar el YapeCaptor de producción), separar el proceso `:captor`, dejar el latido
  reportando ambos módulos. *Sin capacidades nuevas todavía.* Verificación: capta Yapes igual.
- **Fase 1 — Resguardo básico (el 90% del valor).** GPS + foto al marcar "robado", panel MosGuard
  en MOS con mapa. Con esto ya recuperás la mayoría de los casos: dónde está y quién lo tiene.
- **Fase 2 — Video en vivo (mudo).** Reusar señalización de Spy 2.0 + `libwebrtc` en el
  GuardService, TURN configurado. Ver la cámara a demanda, sin audio.
- **Fase 3 — Audio (gated).** Solo detrás de `authorized_mode` + referencia legal. Opcional.

## 8. Lo que NO se hace (decisiones tomadas)

- ❌ Dos APKs (se unifica, con proceso aislado en su lugar).
- ❌ Screenshot remoto silencioso (Android no lo permite sin Device Owner).
- ❌ Audio sin gate legal.
- ❌ Migrar los equipos hasta que MosGuard esté probado en paralelo.

## 9. Costos / dependencias externas

- **TURN server**: metered.ca (gratis 0.5 GB/mes) — solo config, sin código. Crítico para video en
  datos móviles.
- **CI**: mismo workflow `apk-yape.yml` (o un `apk-mosguard.yml` gemelo) → release `mosguard-vN`,
  auto-update desde releases/latest. Mismo keystore estable.
- Backend: Supabase que ya existe (se agregan columnas de ubicación/estado a `yape_dispositivos`).

## 10. Punto de retoma

Plan aprobado en concepto (2026-08-19). **Siguiente paso a decidir por el dueño:** ¿arrancamos por
la **Fase 0 + Fase 1** (refactor + GPS/foto, el 90% del valor sin tocar producción), y dejamos el
video en vivo para cuando eso esté probado? El YapeCaptor de las zonas sigue intacto hasta el final.
