# browsercheck — verificación en navegador REAL del ecosistema MOS

Harness Playwright/Chromium headless para revisar las PWAs (ME/MOS/WH) como en un navegador de verdad:
carga la app desplegada, captura **consola**, intercepta **toda la red** (marca 🚨 cualquier fetch a GAS =
`script.google.com`), ejecuta JS en el contexto de la página y saca **screenshots**.

## Uso
```
cd browsercheck
node check.js <escenario.json>
```

## Escenario (JSON)
```json
{
  "url": "https://levo19.github.io/MosExpress/",
  "localStorage": { "mosexpress_deviceId": "<uuid-aprobado>" },   // opcional: sembrado ANTES de cargar
  "waitMs": 35000,                                                 // cuánto observar (ping/pollers/auth)
  "evalAfter": "(async()=>{ return {online:navigator.onLine}; })()",  // expresión (IIFE async permitida)
  "screenshot": "shot.png",
  "blockGasHard": false                                           // true = ABORTA requests a GAS (prueba dura)
}
```

## Qué reporta
- Red por categoría (GAS / SB-REST / SB-RPC / SB-AUTH / SB-EDGE / PRINTNODE / CDN / …).
- 🚨 lista de hits a GAS (o "CERO fetches a GAS").
- Status de respuestas SB/GAS relevantes.
- Consola de la página (últimas 40).
- Resultado del `evalAfter` + ruta del screenshot (que se lee con la tool Read).

## Notas
- La app es device-gated: un navegador fresco genera un deviceId nuevo → pantalla "Esperando aprobación".
  Para ver la UI real hay que sembrar en `localStorage` un `mosexpress_deviceId` **aprobado** (usar un
  device de PRUEBA dedicado, NO el de un cajero real — el heartbeat marcaría ese device activo).
- `node_modules` y binarios de Chromium NO se commitean (ver .gitignore).
