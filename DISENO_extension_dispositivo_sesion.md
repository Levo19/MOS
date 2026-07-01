# DISEÑO · Extensión de dispositivo + identidad unificada (mega tabla)

> Fuente de verdad. Evoluciona `DISENO_accesos_personal_unificado.md`.
> Regla: **una persona = una fila por día**, aunque tenga varios equipos y varios roles.
> Estado: **DISEÑO APROBADO por el dueño** (2026-06-30). Falta implementar.
> Directrices: **cero-GAS**, revisión adversarial antes de declarar listo, efectos modernos + **háptica** en cada momento clave.

---

## 1. El problema que resuelve

- Un mismo cajero/vendedor usa **2 equipos a la vez**: la **tablet** (fija, escanea ventas) y el **celular** (móvil: ingresos de almacén, imprimir adhesivos/membretes, auditar productos).
- Antes aparecía un "segundo usuario" y se usaba **vetar** como parche para que no cobrara doble. Vetar mata base **y** comisión → castiga de más si esa fila sí vendió.
- También: la misma persona podía verse como `MEX:Sergio` (ME) y `OPxxx` (WH) = dos filas para una persona.

**Objetivo:** que el segundo equipo se **ate** a la sesión existente (no cree otra persona), con la identidad y la seguridad correctas.

---

## 2. Modelo de DOS capas (clave de todo)

```
 ┌── CAPA FÍSICA (por DISPOSITIVO · UUID) ──────────────────────┐
 │  📌 Tablet  UUID-aaa  [aprobado]  perms: CAJERO   push_1     │  → seguridad
 │  📱 Celular UUID-bbb  [aprobado]  perms: VENDEDOR push_2     │  → espía
 │     cada equipo: su UUID · su aprobación · su stream · su token │  → bloqueo · impresora
 └──────────────────────────────┬───────────────────────────────┘
                                │  (se "atan")
 ┌── CAPA PERSONA (identidad · NOMBRE|ZONA) ────────────────────┐
 │  👤 SERGIO | ZONA-01   →  1 fila · base 1× · comisión         │  → pago
 │        🔗 dispositivos atados: Tablet(principal) + Celular    │  → actividad
 └──────────────────────────────────────────────────────────────┘
```

- **Capa física NO cambia**: UUID, aprobación, bloqueo, espía, impresora y token siguen **por equipo**.
- **Capa persona** solo agrupa para **pago y actividad**.
- En **Infraestructura** ves **2 equipos físicos** (no "Sergio" y "Sergio extensión"). La persona sale **una vez** en Personal del día con chip "🔗 2 dispositivos".

---

## 3. Identidad

- ME (cajeros/vendedores virtuales): `MEX:<NOMBRE>|<ZONA>`. Cada `(nombre, zona)` es una fila independiente (base + comisión propia). La comisión ya matchea por `(vendedor, zona)` → queda exacta por zona (se elimina la "zona dominante" inventada y su tiebreaker).
- **Uniformización de nombres** (mata mismatch por espacios/mayúsculas):
  - Input: el cuadro de texto en **MAYÚSCULA** + `trim` (sin minúsculas).
  - Guardado en tabla: **MAYÚSCULA** + `trim`.
  - Match: `mos._norm_nom` ya hace mayúscula+trim+quita-tildes → triple blindaje.
  - Ojo: un typo real de letra ("SEGIO") no lo arregla mayúscula → lo caza el admin.
- WH y personas registradas (con id real en `mos.personal`): usan su **id real** en todos lados. `MEX:` es solo para temporales sin registro.

---

## 4. Extensión de dispositivo (el "companion") + SEGURIDAD

El segundo equipo **no entra fácil**. Modelo tipo "vincular WhatsApp Web": **el equipo principal autoriza**.

```
 📱 CELULAR pide entrar como SERGIO
        │
        ▼
 ¿Hay sesión ACTIVA hoy con "SERGIO" en su zona?
     ┌──────┴───────┐
    NO              SÍ
     │               │
     ▼               ▼
  Login       📌 TABLET (principal) recibe:
  normal      ┌──────────────────────────────────────────┐
  (abre       │ 🔗 Un equipo quiere entrar como SERGIO    │
   su fila)   │    📱 Galaxy A14 · hace 3 seg             │
              │    código: 7-2-9                          │
              │    [ ✓ Soy yo, aceptar ] [ ✗ Rechazar ]  │
              └──────────────────────────────────────────┘
                 │ acepta EN el equipo que Sergio tiene en mano
                 ▼
        Extensión concedida → celular atado a la MISMA fila
        (mismo id · 2º device · NO nueva base)
              │ rechaza / "No, soy otro"
              ▼
        Identidad NUEVA (2º nombre) → fila propia + base propia
```

- Para extender hay que tener **acceso físico al principal** → nadie suplanta.
- El **código (7-2-9)** que muestra el celular debe coincidir con el que aprueba el principal → no se acepta por error.
- **Fallback** si el principal está lejos/apagado: lo aprueba el **admin** desde MOS (mismo modal de seguridad UUID que ya existe). Nunca entra sin autorización.
- Doble gate: (1) el UUID del celular ya debe estar **aprobado** (seguridad de equipo), (2) recién ahí pide la **extensión** (identidad). La extensión **no** salta la aprobación de dispositivo.

---

## 5. Roles y permisos (por DISPOSITIVO)

- El rol/permiso es **por equipo, no por persona**. Tablet=CAJERO (vende, caja), celular=VENDEDOR (ingresos, adhesivos, auditar). Cada uno respeta **sus** permisos.
- **Se permite el MISMO rol** en ambos (ej. vendedor+vendedor por rapidez). No fuerza rol distinto.
- La fila anota los roles (`CAJERO + VENDEDOR`) solo para mostrar el **checklist de auditoría correcto** de lo que hizo en cada equipo.
- **Sin duplicidad de dinero**: idempotencia por `localId` (una acción repetida colapsa). Roles complementarios (vender vs ingresar) no pisan lo mismo.

### Campos compartidos (la "nota" del cajero)
- Editable desde 2 equipos → se sincroniza **en vivo** por los canales realtime existentes (`me.ops_meta` / `wh.ops_meta`).
- **Guard de frescura**: gana la escritura más nueva por timestamp del server (mismo patrón que el merge de preingresos) → **nunca se pisa ni se pierde**. "Siempre actualizada".

---

## 6. Impresión — ruteo al PRINCIPAL

- Cada equipo puede tener **su propia impresora** (movilidad) para lo que imprime **él**.
- Lo que llega **de afuera** (cobro enviado desde MOS, preingreso guardado en WH) → imprime en la impresora del **equipo PRINCIPAL** (la tablet fija; lo móvil puede estar en el bolsillo).

```
 mega tabla · fila de Sergio
    device_id = PRINCIPAL (tablet)   ← columna YA existe
              │ (se resuelve)
              ▼
 dispositivo PRINCIPAL → su printerId (PrintNode, server-side)
              │
   MOS "enviar a cobrar"  ─┐
   WH  "guardar preingreso"─┴──► imprime en el printer del PRINCIPAL
```

- La impresora **NO se copia** en la mega tabla (evita dato duplicado). La mega tabla marca el `device_id` principal; el `printerId` se **resuelve desde ese equipo**.
- ⚠️ Requisito: el `printerId` del principal debe estar **server-side** (para cajas ME ya lo está — el "aviso a cajas" ya imprime así). Asegurar que el principal registre su impresora en el server, no solo en localStorage.

---

## 7. Notificaciones · Espía 2.0

- **Notificaciones (push):** un mensaje/alerta del admin a "Sergio" → **fan-out a los DOS equipos** (le llega esté donde esté). Una tarea de un equipo específico → solo a ese equipo.
- **Espía 2.0:** por equipo (cada uno su stream WebRTC). Ves **2 targets** (📌tablet, 📱celular), espías cualquiera por separado. El *multi-target dashboard* (roadmap del espía) los **agrupa bajo "Sergio"**.
- **Chunks:** por stream de cada equipo, independientes.

---

## 8. Duplicados: la herramienta correcta según el caso

| Caso | Qué es | Herramienta |
|---|---|---|
| Fantasma / 2º device mismo nombre+zona | No debe existir como 2ª fila | **Extensión → una sola fila** (ya no hay qué vetar) |
| Mismo Sergio movido a otra zona (vendió real en 2) | 2 filas legítimas, base duplicada | **Sanción = monto de la base** en la 2ª (respeta la comisión) |
| Dos personas distintas, mismo nombre | 2 reales | "No, soy otro" en login → 2º nombre + **chip alerta** |
| Retención por causa (mala conducta) | Decisión RRHH | **Vetar** (solo para esto) |

- **Chip de alerta ⚠️** cuando un nombre está en >1 fila el día (Personal del día + Liquidaciones agrupadas por nombre: "Sergio · lunes ZONA-01 · lunes ZONA-02 ⚠️"), mostrando la **venta real de cada una** → el admin decide en 2 segundos.
- Objetivo: que el **90% de las veces ya no se necesite vetar**.

---

## 9. UX — efectos modernos + HÁPTICA (parte del diseño, no adorno)

Reusar `vibrate()` + `SoundFX` (WH ya los tiene) y el patrón sensorial existente.

- **Extensión pedida (principal):** el modal entra con spring + el código (7-2-9) con count-in; **háptico** `[40,60,40]` al aparecer; tono `open`.
- **Extensión aceptada:** en ambos equipos, glow verde + "🔗 vinculado" que sube flotante; **háptico** doble-tick `[10,30,10]`; tono `savedTick`. El chip "🔗 2 dispositivos" aparece con fade.
- **Extensión rechazada:** shake rojo en el celular; **háptico** `[80]`; tono `error`.
- **Chip de alerta ⚠️ (nombre en 2 filas):** pulso suave (respira) para llamar la atención sin molestar; al tocarlo, expand con las 2 filas y su venta.
- **Nota sincronizada:** al llegar el valor del otro equipo, el campo hace un flash sutil (no roba el foco); **háptico** ligero `[8]`.
- **Cobro/preingreso impreso en el principal:** en el principal, glow + "🖨 impreso" flotante + `[10,30,10]`; en el que lo envió, tono `savedTick`.
- **Cierre forzado 11pm / veto / pago:** mantener los efectos que ya existen (veto = beep + overlay enmallado; pago = beep).
- Regla: **cada acción que cambia estado tiene feedback** (visual + sonoro + háptico), sincronizado con el tap (optimista), y si falla suena `error`.

### 9.1 Animaciones extra (curadas · modernas)

- **Haz de vinculación ("linking beam"):** al atar el celular, un haz/pulso de luz **viaja del ícono de un equipo al otro** (estilo vincular WhatsApp Web) y los dos chips de dispositivo hacen un **snap magnético** al juntarse. Háptico `[10,40,10]` al conectar.
- **Botón "Soy yo" = mantener presionado (hold-to-confirm):** en vez de un tap, se **presiona y se mantiene** ~0.8s mientras un **anillo se llena** alrededor del botón; al completar, "click" satisfactorio + háptico en **rampa** (`[15,20,25,20,40]`). Doble beneficio: **evita un aceptar accidental** (más seguridad) y se siente premium.
- **Código 7-2-9 estilo odómetro:** los dígitos **giran/caen uno por uno** (flip vertical) al aparecer, y **pulsan en sincronía** en las dos pantallas (principal y celular) para que sea obvio que es el mismo código.
- **Reflow por zona (técnica FLIP):** al agrupar Personal del día por zona, las cards **se reacomodan con transición suave** a su bucket y los encabezados de zona **entran deslizando**. Nada salta de golpe.
- **Chip ⚠️ con destello (sheen sweep):** además del "respirar", un **brillo diagonal barre** el chip cada ~4s (como un "nuevo") — llama la atención sin molestar; al tocarlo, **expande** las 2 filas con sus ventas.
- **Ticket volador (print routing):** al enviar un cobro desde MOS o guardar un preingreso en WH, un **íconito de ticket "vuela"** desde la app emisora hacia el ícono del equipo **principal** y **aterriza** con el sonido de impresión. Deja claro a dónde fue.
- **Odómetro de pago/comisión:** cuando la fila se actualiza (venta nueva, sanción), el monto **cuenta hacia el nuevo valor** (rolling number), no salta. Verde si sube, ámbar si baja.
- **Nota entrante (ripple):** cuando llega la edición del otro equipo, un **ripple** nace del borde por donde entró + un **flash sutil** del campo, sin robar el foco; háptico ligero `[8]`.
- **Avatar con órbita de dispositivos:** en la card de la persona, un **puntito satélite** orbita el avatar por cada equipo atado (1 punto = 1 equipo) → se ve de un vistazo cuántos equipos tiene.
- **Skeleton shimmer** al cargar Personal del día (placeholder que brilla) en vez de spinner.
- **Éxito con micro-partículas:** al concretar la vinculación, un **burst sutil** de partículas verdes (corto, elegante, no confeti barato).

---

## 10. Plan de implementación (fases · cero-GAS · adversarial)

**Backend (Supabase, cero-GAS):**
1. Identidad `MEX:<NOMBRE>|<ZONA>` en los hooks de accesos (288) + `recomputar_dia` usa `r.zona` directa (sin derivar dominante). Migrar filas actuales.
2. Tabla/columna de **dispositivos atados** por fila (device principal + secundarios + rol por device). Reusar `device_id` (principal) que ya existe.
3. RPC de **extensión**: `pedir_extension` (celular) → notifica al principal; `aprobar_extension` (principal/admin) con código. Idempotente, gateado, a prueba de fallos.
4. Resolver **printerId del principal** server-side para el ruteo cross-app (cobro MOS / preingreso WH).
5. **Chip/alerta**: RPC/campo que marque "nombre repetido hoy" + venta de cada fila.
6. Uniformización MAYÚSCULA+trim al guardar.

**Frontend (ME/WH/MOS):**
7. Login: detectar sesión activa (mismo nombre/zona/día) → modal "¿extender? / ¿soy otro?".
8. Principal: recibir/aprobar la extensión (realtime) con el código.
9. Nota + campos compartidos: realtime + guard de frescura.
10. Personal del día + Liquidaciones: agrupar por zona, chip "🔗 N dispositivos" y "⚠ nombre repetido".
11. Efectos + háptica de la sección 9.
12. Ruteo de impresión al principal (MOS cobro, WH preingreso).

**Verificación (directriz adversarial):**
- Suplantación imposible sin el principal (o admin).
- Multi-device mismo nombre/zona = 1 fila, base 1×.
- Zona-move = 2 filas + chip; sanción-base respeta comisión.
- Nota nunca se pisa (2 equipos editando).
- Cobro/preingreso siempre al printer del principal.
- Push a los 2 equipos.
- Cero-GAS end-to-end; idempotencia por localId.

---

## 11. Decisiones CERRADAS (por el dueño)

- Notificaciones → **a ambos** equipos. ✔
- Extensión → **el principal (o admin) aprueba**, con código. ✔
- Rol → **por dispositivo**, se permite **el mismo**. ✔
- Nota → **realtime + frescura**, siempre actualizada. ✔
- Impresión cross-app → **impresora del principal**; impresora NO va en la mega tabla (se resuelve por device). ✔
- Base → **una vez** (extensión = una fila); zona-move = sanción-base; vetar solo por causa. ✔
- **Háptica + efectos modernos** en cada momento clave. ✔

## 12. Abierto / a afinar en implementación
- Formato exacto del id compuesto (`MEX:NOMBRE|ZONA` vs separador seguro para `_liqdia_key`).
- Homónimo **misma zona** real (raro): 2º nombre obligatorio al registrar + detector.
- Caducidad de la extensión (¿se corta al cierre 11pm como la sesión?).
