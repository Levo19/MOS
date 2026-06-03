# Sistema de Membretes — `/assets/membrete/`

**Single source of truth** del sistema de membretes y adhesivos.
Cualquier app del ecosistema (MOS, WH, ME) lee de acá su definición y comportamiento.

## 📦 Contenido

| Archivo | Qué es | Quién lo consume |
|---|---|---|
| `spec.json` | Especificación canónica de tipos, sizes, fonts, calibración, estados | Todas las apps + backend |
| `membrete-modal.js` | Módulo standalone con UI/UX unificada | MOS + WH + ME (via script tag) |
| `gen.py` | Pipeline reproducible de logos | Diseñadores / CI |
| `logo-tienda-ME-S.{png,hex,b64}` | Logo tienda 🏪 | Backend WH + frontend MOS |
| `logo-almacen-WH-S.{png,hex,b64}` | Logo almacén 📦 | Backend WH + frontend MOS |

## 🎯 Tipos de membrete

- **🏠 ADHESIVO_ENVASADO** — adhesivo de envasado tradicional
- **🏪 MEMBRETE_ME** — góndola tienda con precio prominente
- **📦 MEMBRETE_WH** — andamio almacén con nombre prominente + multi-código
- **🔧 CALIBRADOR** — adhesivo de prueba con regla vertical mm

## 🔧 Calibración inteligente

Sistema OFFSET acumulativo (no GAPDETECT por print):

```
PRINT 1: OFFSET 0       → impreso
PRINT 2: OFFSET -d      → compensa drift
PRINT N: OFFSET -(N-1)*d
```

Donde `d` (drift dots/print) se mide UNA VEZ al cambiar rollo:
1. Imprimir 10 calibradores con regla vertical
2. Operador mide desvío del print #10
3. Sistema: `d = mm × 8 / 10`
4. Guarda en `ADHESIVO_DRIFT_DOTS_POR_PRINT`

## 🚀 Fire-and-forget

Frontend crea lote → backend ENCOLADO → trigger time-based procesa.
Operador puede cerrar la app. Lote sigue. Vuelve y ve progreso.

## 🎯 Setup en producción

```javascript
// Editor GAS WH (1 vez):
setupLotesAdhesivo();
instalarTriggerLotesEtiqueta();

// Editor GAS MOS (1 vez):
setupMembretesMePendientes();
instalarTriggerExpirarMembretes();
```
