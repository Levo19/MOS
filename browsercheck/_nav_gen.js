// Censo de la barra de navegación de MOS en ancho de teléfono: qué botones hay y de dónde salen.
const fs = require('fs');

const ev = `(async()=>{
  const r={}, w=ms=>new Promise(s=>setTimeout(s,ms));
  const b=[...document.querySelectorAll('button,a')].find(el=>/Entrar a MOS/i.test(el.textContent||''));
  if(b)b.click(); await w(5000);
  const listo=()=>{ try { return !!MOS; } catch(_) { return false; } };
  for(let i=0;i<50 && !listo();i++){ await w(600); }
  try{ r.version=(await fetch('https://levo19.github.io/MOS/version.json?b='+Date.now()).then(x=>x.json())).version }catch(_){}
  const limpia = t => String(t||'').replace(/\\s+/g,' ').trim().slice(0,26);
  const cands=[...document.querySelectorAll('nav,[class*=nav],[class*=toolbar],[class*=tabbar],[class*=tb-],[class*=bottom]')]
    .filter(e=>{ const s=getComputedStyle(e), rc=e.getBoundingClientRect();
      return (s.position==='fixed'||s.position==='sticky') && rc.height>26 && rc.width>200
             && s.display!=='none' && e.querySelectorAll('button,a').length>=3; });
  const vistos=new Set();
  r.barras=[];
  cands.forEach(e=>{
    if ([...vistos].some(v=>v.contains(e))) return;
    vistos.add(e);
    r.barras.push({
      etiqueta: e.tagName.toLowerCase()+'.'+String(e.className||'').split(' ').filter(Boolean).slice(0,3).join('.'),
      id: e.id||'',
      top: Math.round(e.getBoundingClientRect().top),
      alto: Math.round(e.getBoundingClientRect().height),
      items: [...e.querySelectorAll('button,a')].map(x=>({
        txt: limpia(x.textContent),
        id: x.id||'',
        cls: String(x.className||'').split(' ').slice(0,2).join(' '),
        onclick: limpia((x.getAttribute('onclick')||'').slice(0,60)),
        visible: x.getBoundingClientRect().width>0
      })).filter(x=>x.visible)
    });
  });
  return r;
})()`;

fs.writeFileSync('_nav_movil.json', JSON.stringify({
  url: 'https://levo19.github.io/MOS/',
  waitMs: 50000,
  viewport: { width: 412, height: 900 },
  localStorage: { mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906477' },
  evalAfter: ev,
  screenshot: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_nav_movil.png'
}, null, 2));
console.log('escenario listo');
