# Adhesivo Tony's — Especificación canónica

**Single source of truth** del diseño del adhesivo impreso en almacén.
Cualquier app del ecosistema MOS (WH, MOS, futura ME) lee de acá su definición.

## 📦 Contenido

| Archivo | Qué es | Quién lo consume |
|---|---|---|
| `spec.json` | Especificación: tamaño, posiciones, fuente, fecha, barcode | Todas las apps |
| `logo-tonys.svg` | Vector original del logo (fuente humana del diseño) | Diseñadores |
| `logo-tonys-S.png` | Bitmap 184×36 dots 1bpp B/W (lo que se imprime) | Diseñadores |
| `logo-tonys-S-preview-4x.png` | Preview 4× para inspección humana | Diseñadores |
| `logo-tonys-S.hex` | Hex TSPL2 BITMAP para `LOGO_TSPL_HEX` en `warehouseMos/gas/Envasados.gs` | WH backend |
| `logo-tonys-S.b64` | DataURI base64 PNG para `_ADHESIVO_LOGO_DATAURI` en `ProyectoMOS/js/app.js` | MOS frontend |
| `gen.py` | Pipeline reproducible que genera **los tres artefactos rasterizados** | CI / dev |

## 🔁 Cómo modificar el logo

1. Editar `logo-tonys.svg` (o ajustar el dibujo en `gen.py`)
2. Regenerar: `cd ProyectoMOS/assets/adhesivo && python gen.py`
3. Copiar contenido de `logo-tonys-S.hex` → `LOGO_TSPL_HEX` en `warehouseMos/gas/Envasados.gs`
4. Copiar contenido de `logo-tonys-S.b64` → `_ADHESIVO_LOGO_DATAURI` en `ProyectoMOS/js/app.js`
5. Bump version + deploy ambos

> El bitmap es **determinístico**: mismo input → mismo output bit a bit. Versionado en git permite detectar drift accidental.

## 📐 Geometría (de `spec.json`)

```
ADHESIVO 50×25mm @ 203 DPI = 400×200 dots
┌─────────────────────────────────────────────────┐  ← X=0
│  ┌─────────────┐                  Vto ENE/2027  │  ← Y=2 logo, Y=12 vto
│  │ 🏠 TONY'S   │                                │
│  │ 184×36 dots │                                │
│  └─────────────┘                                │  ← Y=38
│  ──────────────────────────────────────────     │  ← Y=42 separador
│                                                 │
│            COCO RALLADO LARGO 250GR             │  ← Y=46 desc startY
│                                                 │  ← LINE_H=38
│                                                 │
│         ┃ ║ ║ ║ ║ ║ ║ ║ ║ ║ ║ ║ ║ ║ ║ ║         │  ← Y=128 barcode
│         WHCOLAGO250GR                            │  ← Y=174 texto auto
└─────────────────────────────────────────────────┘  ← X=400, Y=200
```

## 🎨 Reglas de diseño

1. **Threshold 140 + Floyd-Steinberg** al rasterizar — calibrado para la TSC TTP-244CE.
2. **Sin curvas finas** — trazos mínimos de 4 dots para sobrevivir a 203 DPI.
3. **Fecha vto formato `MES/yyyy`** — tabla manual `MESES_ES`, NO depender de locale de GAS.
4. **Barcode minimalista** — quiet zone amplio (15×narrow), sin flechas decorativas.
5. **Barcode angosto** — si con narrow=2 supera 300 dots, usar narrow=1.

## 🧪 Test

En GAS WH: `previsualizarEtiqueta()` genera un TSPL2 sin imprimir y lo loguea para inspección.
En MOS frontend: el modal "Imprimir adhesivo" muestra el render WYSIWYG idéntico a la impresión.
