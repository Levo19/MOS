# css/tw.css — Tailwind horneado (ya no viene del CDN)

El panel MOS cargaba `https://cdn.tailwindcss.com`, que **no** sirve un CSS hecho: baja el
compilador entero al navegador, lee el DOM y recompila en cada pintada con un
`MutationObserver` global sobre `<html>`. Medido con `browsercheck/_735_tw.mjs` y
`_735_twconf.mjs`: **17 s de CPU en el arranque**, **13 s** al renderizar Finanzas, y peor
cuanto más crece el DOM (+41 % en 20 navegaciones) — por eso el panel se degradaba a los
40 minutos abierto. Ahora el CSS es una hoja estática de ~33 KB.

## Regenerar (obligatorio cada vez que se agreguen clases nuevas de Tailwind)

Desde la raíz del repo (`ProyectoMOS`):

```
npx -y tailwindcss@3.4.17 -i src/tw.css -o css/tw.css --content "index.html,js/app.js,js/api.js,assets/**/*.js" --minify
```

(el mismo comando está en `package.json` como `npm run tw`)

- **v3** a propósito: el CDN era v3 y el panel usa el **tema por defecto** (no existe
  `tailwind.config`, ni `theme.extend`, ni `darkMode` en todo el repo). Saltar a v4
  cambiaría la paleta y el reset.
- `src/tw.css` solo tiene `@tailwind base; @tailwind components; @tailwind utilities;`.
- El `--content` incluye `assets/**/*.js` por si algún módulo compartido usa clases: es barato.

## Reglas para no romper la interfaz

1. **Las clases van SIEMPRE completas y literales en el código.** El escáner de Tailwind no
   evalúa JavaScript: solo busca cadenas. `` `border-${c}-500/30` `` no se ve y se purga.
   Si hace falta variar el color, usar un **mapa de clases completas** (así están hoy
   `_almRenderInsights` y `_almRenderAlertasOps` en `js/app.js`).
2. **Después de regenerar hay que bumpear el `?v=`** del `<link>` en `index.html` y el de
   `./css/tw.css?v=` en `sw.js` (van junto con `version.json`, `var V`, y el `?v=` de
   `app.js`/`api.js`). Si no, el navegador y el Service Worker sirven el CSS viejo.
3. **El `<link>` va ÚLTIMO en el `<head>`**, después del bloque `<style>` a mano. No es
   capricho: el CDN inyectaba su `<style>` al final del head, o sea *después* de los estilos
   propios, así que las utilidades de Tailwind le ganan a las clases de la casa en igualdad
   de especificidad (`.card-sm` vs `.p-3`). Moverlo arriba invierte esa cascada y cambia el
   aspecto de media interfaz.
4. **Verificar antes de deployar.** Un purge de más no se ve en un archivo: se ve como una
   pantalla rota. `browsercheck/_755_tw_visual.mjs` captura las vistas principales del build
   local y las compara contra producción.

## Qué NO toca el purge

`zcard-…`, `cjcard-…`, `view-…`, `badge-red`, `cat-…`, `zona-…` y compañía **no son
Tailwind**: son clases e ids del CSS a mano que vive dentro de `index.html`. Tailwind ni las
mira; sobreviven siempre.
