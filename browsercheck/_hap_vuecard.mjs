// Monta el TEMPLATE REAL de la card v2 (recortado tal cual de index.html) con Vue 3 y el
// CSS real del head. Verifica que compila, que renderiza y mide la barra en cada ancho.
import fs from 'fs';
import { chromium, webkit } from 'playwright';

const SRC = 'C:/Users/ISO/ecosistema MOS/MosExpress/index.html';
const html = fs.readFileSync(SRC, 'utf8');
const L = html.split('\n');
const css = [[314, 1230], [1231, 1408], [2036, 2390], [3047, 3159]]
  .map(([a, b]) => L.slice(a, b - 1).join('\n')).join('\n');

// recorte exacto del bloque de la card (desde el v-for hasta el cierre del div)
const ini = L.findIndex(l => l.includes('v-for="prod in productosFiltrados"'));
const fin = L.findIndex((l, i) => i > ini && l.trim() === '</div>' && L[i - 1].includes('promo-stripe'));
if (ini < 0 || fin < 0) { console.error('no se encontró el bloque de la card', ini, fin); process.exit(1); }
const cardTpl = L.slice(ini, fin + 1).join('\n');
console.log('template de la card: líneas ' + (ini + 1) + '-' + (fin + 1));

const page_html = `<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>card v2 · Vue real</title>
<script src="https://unpkg.com/vue@3.4.21/dist/vue.global.prod.js"><\/script>
<script src="https://cdn.tailwindcss.com"><\/script>
<script>tailwind.config={theme:{extend:{colors:{posPrimary:'#059669'}}}}<\/script>
<style>
${css}
</style></head><body class="bg-white">
<div id="app"><main class="p-3"><div class="grid gap-3 grid-cols-3 sm:grid-cols-4 md:grid-cols-5">
${cardTpl}
</div></main></div>
<script>
const { createApp, ref } = Vue;
const P = (id,n,cat,precio,stock,npres,um,promo)=>({idUnico:id,nombreCorto:n,cat,precio,stock,unidadMedida:um,
  imagen:"data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='120' height='120'><rect width='120' height='120' fill='%23e5e7eb'/></svg>",
  presentaciones:Array.from({length:npres},(_,k)=>({Factor:k+1})), promoStr:promo||''});
createApp({
  setup(){
    const productosFiltrados = ref([
      P('1','ARROZ COSTEÑO EXTRA 750G','ABARROTES',4.5,12,3,'NIU'),
      P('2','ACEITE PRIMOR PREMIUM BOTELLA 900 ML','ACEITES',11.9,0,4,'NIU'),
      P('3','LECHE GLORIA EVAPORADA TARRO 400G','LACTEOS',4.2,8,1,'NIU','Lleva 3 por S/ 11.70'),
      P('4','AZUCAR RUBIA A GRANEL','ABARROTES',3.8,25.5,2,'KGM'),
      P('5','GASEOSA INKA KOLA 3L','BEBIDAS',10.5,0,6,'NIU'),
      P('6','DETERGENTE BOLIVAR FLORAL 780G','LIMPIEZA',9.9,5,1,'NIU'),
      P('7','PAN FRANCES SIN PRECIO','PANADERIA',0,4,1,'NIU'),
      P('8','PAPEL HIGIENICO ELITE x4','LIMPIEZA',7.5,0,2,'NIU')
    ]);
    const pulsingProductId = ref(null), anaPosPressingId = ref(null);
    const nada = () => {};
    return { productosFiltrados, pulsingProductId, anaPosPressingId,
      cardTapPOS: nada, abrirAnaliticaPos: nada, anaPosPressStart: nada, anaPosPressCancel: nada,
      abrirPresentaciones: nada, abrirAlternativas: nada,
      tieneAlternativas: p => p.idUnico !== '8' };
  }
}).mount('#app');
<\/script></body></html>`;
fs.writeFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_hap_vuecard.html', page_html, 'utf8');

for (const [nm, bt] of [['chromium', chromium], ['webkit', webkit]]) {
  const b = await bt.launch();
  for (const w of [360, 390, 412, 768, 1024, 1280]) {
    const mob = w < 700;
    const ctx = await b.newContext({ viewport: { width: w, height: 900 }, hasTouch: mob, deviceScaleFactor: mob ? 2 : 1 });
    const page = await ctx.newPage();
    const errs = []; page.on('pageerror', e => errs.push(String(e).slice(0, 140)));
    await page.goto('http://127.0.0.1:8124/_hap_vuecard.html', { waitUntil: 'networkidle' });
    await page.waitForTimeout(1000);
    const r = await page.evaluate(() => {
      const cards = [...document.querySelectorAll('.pos-card')];
      const c = cards[1];
      const bs = c ? [...c.querySelectorAll('.cab')] : [];
      const r0 = bs[0] && bs[0].getBoundingClientRect(), r1 = bs[1] && bs[1].getBoundingClientRect();
      const vis = e => e && getComputedStyle(e).display !== 'none';
      return {
        cards: cards.length,
        mustaches: (document.body.innerHTML.match(/\\{\\{/g) || []).length,
        anchoCard: c ? +c.getBoundingClientRect().width.toFixed(1) : 0,
        btn: r0 ? [+r0.width.toFixed(1), +r0.height.toFixed(1)] : null,
        gap: (r0 && r1) ? +(r1.left - r0.right).toFixed(1) : null,
        recorte: bs.map(x => x.scrollWidth - x.clientWidth),
        modo: vis(c && c.querySelector('.cab-txt')) ? 'texto-completo' : 'compacto',
        etiqueta: bs.map(x => x.innerText.replace(/\\s+/g, ' ').trim()),
        altPulsa: !!(c && c.querySelector('.cab-alt')),
        sinAltEnUltima: !!(cards[7] && cards[7].querySelector('.cab-off')),
        chip: !!document.querySelector('.stk-chip'),
        promo: !!document.querySelector('.promo-stripe'),
        sinPrecio: document.body.innerText.includes('Sin precio'),
        desborde: document.documentElement.scrollWidth - document.documentElement.clientWidth
      };
    });
    console.log(nm.padEnd(9) + String(w).padStart(5) + 'px ' + JSON.stringify(r) + (errs.length ? ' ERR:' + errs[0] : ''));
    if (w === 360 || w === 1280) await page.screenshot({ path: `_hap_vuecard_${nm}_${w}.png`, clip: { x: 0, y: 0, width: w, height: Math.min(520, 900) } });
    await ctx.close();
  }
  await b.close();
}
