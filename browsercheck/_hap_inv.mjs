// Inventario HÁPTICO estático de ME: botones del template sin :active, sin touch-action y
// acciones importantes sin vibración.
import fs from 'fs';
const SRC = 'C:/Users/ISO/ecosistema MOS/MosExpress/index.html';
const html = fs.readFileSync(SRC, 'utf8');
const lines = html.split('\n');
// template Vue = desde <div id="app"> hasta el cierre del body
const ini = lines.findIndex(l => l.includes('<div id="app"')) + 1;
const fin = lines.length;
const tpl = lines.slice(ini - 1, fin);

// 1) botones (etiqueta <button ...>) — se toma la etiqueta completa aunque abarque varias líneas
const texto = tpl.join('\n');
const tags = texto.match(/<button\b[\s\S]*?>/g) || [];
let sinActive = [], conActive = 0, sinTouch = 0;
tags.forEach((t, i) => {
  const cls = (t.match(/class="([^"]*)"/) || [])[1] || '';
  const dyn = (t.match(/:class="([^"]*)"/) || [])[1] || '';
  const todo = cls + ' ' + dyn;
  const tieneActive = /active:/.test(todo) || /\bcab\b|\bvr-b\b|\bpv-fila\b|\bana-x\b|\bpv-x\b|\bnav-tab\b/.test(cls);
  if (tieneActive) conActive++; else sinActive.push({ i, cls: cls.slice(0, 90).replace(/\s+/g, ' ') });
  if (!/touch-action|manipulation/.test(todo)) sinTouch++;
});
console.log('BOTONES en template: ' + tags.length);
console.log('  con :active/clase con active  : ' + conActive);
console.log('  SIN feedback :active          : ' + sinActive.length);
console.log('  sin touch-action explícito    : ' + sinTouch);
// 2) elementos con @click que no son <button>
const clicks = (texto.match(/@click[.\w]*="/g) || []).length;
console.log('@click totales en template      : ' + clicks);
// 3) divs/spans/a clickables (no button)
const noBtn = (texto.match(/<(div|span|a|li|label|td|tr)\b[^>]*@click/g) || []).length;
console.log('clickables que NO son <button>  : ' + noBtn);
// 4) vibraciones existentes en TODO el archivo
const vibs = (html.match(/navigator\.vibrate/g) || []).length;
console.log('navigator.vibrate en el archivo : ' + vibs);
// 5) reglas :active en el CSS del head
const cssHead = lines.slice(313, 1205).join('\n') + lines.slice(1205, 1383).join('\n') + lines.slice(2010, 2365).join('\n') + lines.slice(3021, 3134).join('\n');
console.log('reglas :active en <style> head  : ' + ((cssHead.match(/:active/g) || []).length));
console.log('touch-action en <style> head    : ' + ((cssHead.match(/touch-action/g) || []).length));
console.log('\n--- muestra de botones SIN :active (primeros 40) ---');
sinActive.slice(0, 40).forEach(b => console.log('  ' + (b.cls || '(sin class)')));
fs.writeFileSync('_hap_inv_sinactive.txt', sinActive.map(b => b.cls).join('\n'), 'utf8');
console.log('\n(lista completa en _hap_inv_sinactive.txt)');
