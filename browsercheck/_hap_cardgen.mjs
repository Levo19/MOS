// Genera un harness estático con el CSS REAL del head de ME + el markup REAL de la card v2,
// para medir la barra [🧱 · 🔄] a distintos anchos sin depender del backend.
import fs from 'fs';
const SRC = 'C:/Users/ISO/ecosistema MOS/MosExpress/index.html';
const html = fs.readFileSync(SRC, 'utf8');
const lines = html.split('\n');
// Bloques <style> del head (1-indexado): 314-1205, 1206-1383, 2011-2365, 3022-3134
const rangos = [[314, 1205], [1206, 1383], [2011, 2365], [3022, 3134]];
let css = '';
for (const [a, b] of rangos) css += lines.slice(a, b - 1).join('\n') + '\n';

const cardTpl = (nombre, cat, precio, stock, pres, promo, agotado) => `
<div class="bg-gray-50 rounded-2xl shadow-sm border border-gray-200 overflow-hidden cursor-pointer pos-card transition-all active:scale-95 flex flex-col relative${promo ? ' has-promo' : ''}">
  ${promo ? '<span class="promo-star">⭐</span>' : ''}
  <div class="prod-img w-full bg-gray-200 relative${agotado ? ' card-agotado' : ''}">
    <img src="data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='120' height='120'><rect width='120' height='120' fill='%23e5e7eb'/></svg>" class="w-full h-full object-cover mix-blend-multiply">
    <span class="stk-chip ${stock > 0 ? 'stk-on' : 'stk-off'}">${stock > 0 ? stock : 'Sin stock'}</span>
  </div>
  <div class="p-2 flex-1 flex flex-col bg-white relative">
    <h3 class="font-bold text-gray-800 text-[11px] leading-tight line-clamp-3">${nombre}</h3>
    <div class="text-[8.5px] text-gray-400 font-bold truncate mt-0.5">${cat}</div>
    <p class="text-posPrimary font-black text-sm mt-2">S/ ${precio}</p>
  </div>
  <div class="cardv2-acts">
    <button class="cab ${pres > 1 ? 'cab-pres' : 'cab-off'}"><span class="cab-ico">🧱</span>${pres > 1 ? '<span class="cab-n">' + (pres - 1) + '</span><span class="cab-txt">' + (pres - 1) + ' PRESENT.</span>' : '<span class="cab-txt">PRESENT.</span>'}</button>
    <button class="cab ${agotado ? 'cab-alt' : 'cab-off'}"><span class="cab-ico">🔄</span><span class="cab-txt">PARECIDOS</span></button>
  </div>
  ${promo ? '<div class="promo-stripe">🎯 3x2 EN LA 2DA</div>' : ''}
</div>`;

const out = `<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>Harness card v2</title>
<script src="https://cdn.tailwindcss.com"></script>
<script>tailwind.config={theme:{extend:{colors:{posPrimary:'#059669'}}}}</script>
<style>
${css}
</style></head><body class="bg-white">
<main class="p-3">
  <div class="grid gap-3 grid-cols-3 sm:grid-cols-4 md:grid-cols-5" id="grid">
    ${cardTpl('ARROZ COSTEÑO EXTRA 750G', 'ABARROTES', '4.50', 12, 3, false, false)}
    ${cardTpl('ACEITE PRIMOR PREMIUM BOTELLA 900 ML', 'ACEITES', '11.90', 0, 4, false, true)}
    ${cardTpl('LECHE GLORIA', 'LACTEOS', '4.20', 8, 1, true, false)}
    ${cardTpl('AZUCAR RUBIA GRANEL', 'ABARROTES', '3.80', 25, 2, false, false)}
    ${cardTpl('GASEOSA INKA KOLA 3L', 'BEBIDAS', '10.50', 0, 6, false, true)}
    ${cardTpl('DETERGENTE BOLIVAR 780G', 'LIMPIEZA', '9.90', 5, 1, false, false)}
  </div>
</main>
</body></html>`;
fs.writeFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_hap_card.html', out, 'utf8');
console.log('harness escrito, css bytes=' + css.length);
