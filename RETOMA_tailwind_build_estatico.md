# PUNTO DE RETOMA · Sacar Tailwind del CDN (build estático)

**Estado**: pendiente, no empezado. Necesita su propia sesión.
**Apuntado**: 2026-08-10, tras la medición del incidente "el botón Auditar no reacciona" (2.43.737).
**Impacto**: es el mayor consumidor de CPU del panel MOS y la causa de que se degrade con el tiempo abierto.

---

## Qué pasa hoy

`index.html:13` carga Tailwind desde el CDN de desarrollo:

```html
<script src="https://cdn.tailwindcss.com"></script>
```

Ese script **no** sirve un CSS ya hecho: trae el compilador entero al navegador, lee el DOM,
genera el CSS en runtime y — lo importante — instala un **MutationObserver global sobre `<html>`**
con `{attributes, attributeFilter:['class'], childList, subtree}`. Cada vez que la app pinta
cualquier cosa, recompila.

## Lo medido (perfil CDP, CPU throttling 4x, `browsercheck/_735_tw.mjs` y `_735_twconf.mjs`)

| | |
|---|---|
| Función `pf` (el compilador) en el arranque | **17 118 ms** |
| `pf` al renderizar Finanzas | **13 336 ms** |
| Lo siguiente en la lista de consumo | 2 269 ms |
| Callbacks del MutationObserver hasta pintar Personal del día | 166 callbacks / **6 976 ms de CPU** |
| CSS generado en runtime | **769 KB** |
| Crecimiento del DOM en 20 navegaciones | 10 134 → 14 328 nodos (+41 %) |

**Prueba de causalidad**: bloqueando `cdn.tailwindcss.com` en la sesión de prueba, `pf` y todos
los frames de PostCSS desaparecen del perfil, el JS identificable cae de **~24 s a ~1,3 s** y el
tiempo ocioso sube de **1,0 s a 9,5 s**.

**Por qué empeora con el tiempo**: el costo escala con el tamaño del DOM, y el DOM crece +41 %
en 20 navegaciones. Por eso el panel arranca bien y a los 40 minutos "se cuelga": un clic que
cae dentro de una de esas tareas largas simplemente no llega a procesarse. Esto es lo que queda
**sin resolver** de los síntomas que reportó el dueño; la parte del botón mudo ya se arregló
en 2.43.737.

---

## Por qué el cambio es más barato de lo que parece (reconocimiento hecho)

1. **No hay `tailwind.config`, ni `theme.extend`, ni `darkMode` configurado** en todo el repo.
   Se usa el tema por defecto tal cual → el build no tiene que replicar ninguna personalización.
2. **Las clases dinámicas casi no existen.** En 48 000 líneas de `js/app.js` las clases viajan
   **completas** dentro de strings (`'text-rose-500'`, `'text-slate-100'`), que es exactamente
   lo que el escáner de Tailwind sabe detectar. Los `${cls}`, `${colorCls}`, `${estCls}`
   contienen la clase entera, no un fragmento.
3. **Solo 2 casos** arman una clase por pedazos, y ambos son decoración secundaria que ya tiene
   un `style="border-left:..."` inline al lado:
   - `js/app.js:7915` → `border-${c}-500/30`
   - `js/app.js:7938` → `border-${sevColor[a.severidad] || 'slate'}-500/30`

   Se resuelven con un safelist de esos colores o reescribiéndolos como mapa de clases completas.
4. Los `'zcard-' + s`, `'cjcard-' + i`, `'view-' + v` **no son Tailwind**: son ids y clases
   propias del CSS a mano. No los toca el purge.

**Alcance**: `index.html` (23 710 líneas) + `js/app.js` (47 979) + `js/api.js` (4 068).
También cargan el CDN `browsercheck/_hap_card.html` y `_hap_vuecard.html`, que son harnesses
de prueba y pueden quedarse como están.

---

## Plan propuesto

1. `npx tailwindcss -i src/tw.css -o css/tw.css --content "index.html,js/*.js" --minify`
   (sin config; solo `@tailwind base/components/utilities` en el archivo de entrada).
2. Safelist para los 2 casos dinámicos de arriba, o reescribirlos — mejor reescribirlos, son 2 líneas.
3. Reemplazar la etiqueta del CDN por `<link rel="stylesheet" href="css/tw.css?v=X.Y.Z">`
   y sumar ese pin al ritual de bump (hoy son: `version.json`, `var V`, `sw.js`, `?v=` de
   `api.js` y `app.js`).
4. **Verificación obligatoria antes del bump** — es un cambio de estilo global, un purge de más
   se ve como una pantalla rota en producción:
   - diff visual con Playwright de las pantallas principales (Dashboard, Catálogo, Almacén,
     Zona, Proveedores, Cajas, Finanzas, Tributario, Facturación, Configuración) contra la
     captura de la versión anterior;
   - abrir los overlays pesados (compras paso 1 y 2, Auditar, promociones, liquidaciones);
   - re-correr el perfil de `browsercheck/_735_tw.mjs` para confirmar que `pf` desapareció.
5. Repetir el antes/después de `browsercheck/_735_auditar_perf.mjs` para dejar el número medido.

**Ganancia esperada**: quitar ~30 s de CPU por sesión, los 769 KB de CSS generado en vivo, y
la degradación acumulativa. El panel deja de ponerse lento con el tiempo abierto.

**Riesgo**: medio-bajo por lo del reconocimiento, pero el fallo se ve en TODA la interfaz a la
vez. No hacerlo el mismo día que un cambio de dinero.

---

## Scripts de medición ya listos (commiteados)

- `browsercheck/_735_tw.mjs` — perfil CDP con y sin el CDN
- `browsercheck/_735_twconf.mjs` — confirmación del MutationObserver y del CSS generado
- `browsercheck/_735_profile.mjs` — long tasks del boot y del render de Finanzas
- `browsercheck/_735_auditar_perf.mjs` — clic → feedback → modal (el antes/después del 737)
