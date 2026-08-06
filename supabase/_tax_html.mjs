import fs from 'fs';
const arbol = JSON.parse(fs.readFileSync('_tax_arbol.json','utf8'));
const MG = {"ABARROTES":22,"ACEITES":18,"BEBIDAS":18,"CONFITERIA":28,"CONSERVAS":22,"DECORATIVOS":40,"DESCARTABLES":28,"ENDULZANTES":20,"ENERGIZANTES":22,"ESPECIAS":35,"GALLETAS_SNACKS":22,"GRANEL":30,"INFUSIONES":28,"INSUMOS_REPOSTERIA":40,"LACTEOS":18,"LIMPIEZA":22,"MENESTRAS":22,"OTROS":25,"PRODUCTOS_CHINOS":28,"REPOSTERIA":32,"SALSAS":25,"VINAGRES":25,"VINOS_LICORES":30};
const esc = s => s.replace(/&/g,'&amp;').replace(/</g,'&lt;');
const tit = s => s.replace(/_/g,' ');
const cats = Object.keys(arbol).sort((a,b)=>{
  const ta = Object.values(arbol[a]).reduce((x,y)=>x+y.n,0), tb = Object.values(arbol[b]).reduce((x,y)=>x+y.n,0);
  return tb-ta;
});
let cards = '';
for (const cat of cats) {
  const subs = Object.entries(arbol[cat]).sort((a,b)=>b[1].n-a[1].n);
  const tot = subs.reduce((x,[,v])=>x+v.n,0);
  cards += `<article class="cat"><header><h3>${esc(tit(cat))}</h3><span class="tot">${tot}</span><span class="mg">margen ${MG[cat]}%</span></header><ul>`;
  for (const [s,v] of subs) {
    cards += `<li><div class="sr"><span class="sn">${esc(s)}</span><span class="sc">${v.n}</span></div><div class="ej">${esc(v.ej.slice(0,2).join(' · '))}</div></li>`;
  }
  cards += `</ul></article>\n`;
}
const html = fs.readFileSync('_tax_plantilla.html','utf8').replace('<!--CARDS-->', cards);
fs.writeFileSync('C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/taxonomia-mos.html', html);
console.log('ok', cats.length, 'categorias');
