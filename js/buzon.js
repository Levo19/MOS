/* [964] Buzón Directo — reportes/dudas/capacitaciones de admins al Master, con push dirigido.
   Módulo AUTÓNOMO: usa el global API (RPCs buzon*) y localStorage['MOS_SESSION'] (sesión). No toca app.js.
   Distinto del "buzón IGV" (facturas): este es de REPORTES (tickets mos.buzon_tickets). */
(function () {
  'use strict';
  if (window.__BUZON_REP) return; window.__BUZON_REP = true;
  var B = {};
  window.BUZON = B;

  var CAT = { rep:{e:'🔧',n:'Falla / Regla',c:'#e5484d'}, ope:{e:'📊',n:'Operativa',c:'#e07a1a'},
              con:{e:'❓',n:'Consulta',c:'#0ea5e9'}, form:{e:'🎓',n:'Capacitación',c:'#12a877'} };
  // La sesión vive en localStorage['MOS_SESSION'] ({idPersonal, nombre, rol}); window.S NO existe (es
  // una variable interna de app.js). Leerla de acá es el camino confiable entre archivos.
  function ses(){ try { return JSON.parse(localStorage.getItem('MOS_SESSION')) || {}; } catch(_) { return {}; } }
  function esMaster(){ return String(ses().rol||'').toUpperCase()==='MASTER'; }
  function nombre(){ return String(ses().nombre||'').trim(); }
  function zona(){ var s=ses(); return String(s.zona||s.estacion||'').trim(); }
  function esc(t){ return String(t==null?'':t).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];}); }
  // API y MOS son `const` a nivel de script (globales léxicos), NO window.API. Un script posterior
  // (este) los ve por nombre. Fallback a window.API por si acaso.
  function apiRef(){ try { if (typeof API !== 'undefined' && API && API.post) return API; } catch(_){} return (window.API && window.API.post) ? window.API : null; }
  function api(a,p){ var A=apiRef(); if(!A) return Promise.reject(new Error('API no disponible aún')); try { return A.post(a,p||{}); } catch(e){ return Promise.reject(e); } }

  /* ── sonido ── */
  var AC=null, muted=false;
  function ac(){ if(!AC){ try{AC=new (window.AudioContext||window.webkitAudioContext)();}catch(e){} } return AC; }
  function tone(f,d,ty,g,w){ if(muted)return; var c=ac(); if(!c)return; var t0=c.currentTime+(w||0);
    var o=c.createOscillator(),ga=c.createGain(); o.type=ty||'sine'; o.frequency.value=f; o.connect(ga); ga.connect(c.destination);
    ga.gain.setValueAtTime(0,t0); ga.gain.linearRampToValueAtTime(g||.05,t0+.01); ga.gain.exponentialRampToValueAtTime(.0001,t0+(d||.15)); o.start(t0); o.stop(t0+(d||.15)+.02); }
  var sfx={ tick:function(){tone(520,.08,'triangle',.045);}, pick:function(){tone(600,.1,'sine',.05);tone(820,.12,'sine',.04,.05);},
    send:function(){tone(500,.1,'sine',.055);tone(700,.1,'sine',.05,.08);tone(1000,.18,'sine',.045,.16);}, pop:function(){tone(360,.12,'sine',.045);} };

  function toast(t){ var e=document.createElement('div'); e.className='bz-toast'; e.textContent=t; document.body.appendChild(e); sfx.pop();
    setTimeout(function(){ e.style.opacity='0'; setTimeout(function(){ e.remove(); },300); },2200); }

  /* ── CSS ── */
  function css(){ if(document.getElementById('bz-css'))return; var s=document.createElement('style'); s.id='bz-css';
    s.textContent = [
    ':root{--bzg:#e9a72c;--bzg2:#c98a12}',
    '.bz-fab{position:fixed;right:18px;bottom:18px;z-index:2147483000;height:54px;border:0;border-radius:18px;padding:0 18px 0 15px;display:flex;align-items:center;gap:9px;color:#1a1206;font-weight:800;font-size:14.5px;font-family:inherit;cursor:grab;touch-action:none;user-select:none;-webkit-user-select:none;background:linear-gradient(150deg,#f7c04a,#e9a72c);box-shadow:0 12px 30px -10px #e9a72c,0 0 0 5px #e9a72c22;transition:transform .18s}',
    '.bz-fab:hover{transform:translateY(-3px)}.bz-fab .i{font-size:20px}',
    '.bz-fab.bz-dragging{transition:none;cursor:grabbing;transform:scale(1.07);box-shadow:0 20px 44px -10px #e9a72c,0 0 0 5px #e9a72c33}',
    '.bz-fab .bdg{position:absolute;top:-7px;right:-7px;min-width:22px;height:22px;border-radius:11px;background:#e5484d;color:#fff;font-size:11.5px;font-weight:700;display:none;align-items:center;justify-content:center;padding:0 6px;box-shadow:0 0 0 3px #0003}',
    '.bz-fab .bdg.on{display:flex}',
    '.bz-ov{position:fixed;inset:0;z-index:2147483001;background:rgba(10,8,15,.55);backdrop-filter:blur(7px);-webkit-backdrop-filter:blur(7px);display:none;align-items:flex-end;justify-content:center;font-family:inherit}',
    '.bz-ov.on{display:flex;animation:bzf .25s}','@keyframes bzf{from{opacity:0}to{opacity:1}}',
    '@keyframes bzu{from{transform:translateY(30px);opacity:0}to{transform:none;opacity:1}}',
    '.bz-panel{background:var(--bzp,#fff);color:var(--bzi,#211d2a);width:min(560px,100%);max-height:92vh;border-radius:22px 22px 0 0;display:flex;flex-direction:column;overflow:hidden;animation:bzu .3s cubic-bezier(.2,.7,.3,1);box-shadow:0 -20px 60px -20px #000a}',
    '@media(min-width:600px){.bz-ov{align-items:center}.bz-panel{border-radius:22px}}',
    '.bz-h{display:flex;align-items:center;gap:11px;padding:15px 18px;border-bottom:1px solid var(--bzl,#e6e0d8)}',
    '.bz-h .mbx{width:40px;height:40px;border-radius:12px;display:grid;place-items:center;font-size:20px;background:linear-gradient(150deg,#f7c04a,#e9a72c)}',
    '.bz-h b{font-size:16px;font-weight:800;font-family:inherit}.bz-h .sub{font-size:12px;color:var(--bzm,#6d6678)}',
    '.bz-x{margin-left:auto;border:0;background:var(--bzc,#f3f0ec);width:34px;height:34px;border-radius:10px;color:var(--bzm,#6d6678);font-size:16px;cursor:pointer}',
    '.bz-body{overflow:auto;padding:14px 16px;flex:1}',
    '.bz-stats{display:flex;gap:8px;margin-bottom:12px}.bz-stat{flex:1;background:var(--bzc,#f7f4f0);border:1px solid var(--bzl,#e6e0d8);border-radius:12px;padding:8px 10px}.bz-stat b{font-size:19px;display:block;line-height:1;font-weight:800}.bz-stat span{font-size:10.5px;color:var(--bzm,#6d6678)}',
    '.bz-filt{display:flex;gap:6px;overflow-x:auto;margin-bottom:10px;padding-bottom:2px}.bz-filt button{border:1px solid var(--bzl,#e6e0d8);background:transparent;color:var(--bzm,#6d6678);border-radius:20px;padding:5px 11px;font-size:12px;font-weight:600;white-space:nowrap;cursor:pointer}.bz-filt button.on{background:var(--bzi,#211d2a);color:var(--bzc,#fff);border-color:var(--bzi,#211d2a)}',
    '.bz-tk{width:100%;text-align:left;border:1px solid var(--bzl,#e6e0d8);background:var(--bzp,#fff);border-radius:14px;padding:11px 13px;margin:7px 0;cursor:pointer;position:relative;display:block}',
    '.bz-tk:hover{border-color:var(--bzg)}.bz-tk.unseen{box-shadow:inset 3px 0 0 var(--bzg)}',
    '.bz-tk .row{display:flex;align-items:center;gap:7px;margin-bottom:4px}.bz-tag{font-size:10px;font-weight:700;padding:2px 8px;border-radius:20px;text-transform:uppercase}',
    '.bz-tk .ago{margin-left:auto;font-size:11px;color:var(--bzm,#6d6678)}.bz-tk h4{margin:0 0 2px;font-size:14.5px;font-weight:700}.bz-tk .u{font-size:12px;color:var(--bzm,#6d6678);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
    '.bz-tk .nb{position:absolute;right:10px;bottom:10px;min-width:20px;height:20px;border-radius:10px;background:#e5484d;color:#fff;font-size:11px;font-weight:700;display:grid;place-items:center;padding:0 5px}',
    '.bz-est{font-size:11px;font-weight:700;padding:3px 9px;border-radius:20px;background:#e9a72c22;color:var(--bzg2)}',
    '.bz-cats{display:grid;grid-template-columns:1fr 1fr;gap:10px}.bz-cat{border:1.5px solid var(--bzl,#e6e0d8);background:var(--bzc,#f7f4f0);border-radius:15px;padding:14px;text-align:left;cursor:pointer}.bz-cat:hover{transform:translateY(-2px)}.bz-cat .ci{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;font-size:20px;margin-bottom:9px}.bz-cat b{display:block;font-size:14.5px}.bz-cat span{display:block;font-size:11px;color:var(--bzm,#6d6678);margin-top:1px}.bz-cat.sel{border-color:var(--bzg);box-shadow:0 0 0 3px #e9a72c22}',
    '.bz-fld{display:block;font-size:11px;font-weight:700;color:var(--bzm,#6d6678);margin:13px 0 6px;text-transform:uppercase}',
    '.bz-in,.bz-ta{width:100%;border:1.5px solid var(--bzl,#e6e0d8);background:var(--bzc,#f7f4f0);color:var(--bzi,#211d2a);border-radius:12px;padding:11px 12px;font-family:inherit;font-size:14px}.bz-in:focus,.bz-ta:focus{outline:0;border-color:var(--bzg)}.bz-ta{resize:vertical;min-height:70px}.bz-ta.big{min-height:120px}',
    '.bz-two{display:grid;grid-template-columns:1fr 1fr;gap:10px}',
    '.bz-chips{display:flex;flex-wrap:wrap;gap:7px}.bz-chip{border:1.5px solid var(--bzl,#e6e0d8);background:var(--bzc,#f7f4f0);color:var(--bzi,#211d2a);border-radius:20px;padding:7px 12px;font-size:13px;font-weight:500;cursor:pointer}.bz-chip.on{background:var(--bzi,#211d2a);color:var(--bzc,#fff);border-color:var(--bzi,#211d2a)}',
    '.bz-tg{display:flex;background:var(--bzc,#f7f4f0);border:1.5px solid var(--bzl,#e6e0d8);border-radius:12px;padding:4px;gap:4px}.bz-tg button{flex:1;border:0;background:transparent;color:var(--bzm,#6d6678);font-weight:600;font-size:13px;padding:8px;border-radius:9px;cursor:pointer}.bz-tg button.on{background:var(--bzg);color:#1a1206}',
    '.bz-rev{max-height:0;overflow:hidden;opacity:0;transition:.3s}.bz-rev.on{max-height:120px;opacity:1;margin-top:10px}',
    '.bz-media{display:grid;grid-template-columns:repeat(4,1fr);gap:7px;margin-top:4px}.bz-ph{aspect-ratio:1;border-radius:11px;position:relative;overflow:hidden;border:1px solid var(--bzl,#e6e0d8);background:#0002}.bz-ph img,.bz-ph video{width:100%;height:100%;object-fit:cover}.bz-ph .rm{position:absolute;top:3px;right:3px;width:19px;height:19px;border-radius:6px;border:0;background:#000a;color:#fff;font-size:10px;cursor:pointer;z-index:2}.bz-ph .pl{position:absolute;inset:0;margin:auto;width:26px;height:26px;border-radius:50%;background:#000a;color:#fff;display:grid;place-items:center;font-size:12px;pointer-events:none}.bz-ph .ci{position:absolute;left:0;right:0;bottom:0;border:0;background:#000b;color:#fff;font-size:9px;padding:4px 5px;font-family:inherit}.bz-ph .up{position:absolute;inset:0;display:grid;place-items:center;background:#000a;color:#fff;font-size:10px}.bz-ph.add{border:1.5px dashed var(--bzl,#e6e0d8);display:grid;place-items:center;color:var(--bzm,#6d6678);cursor:pointer;background:var(--bzc,#f7f4f0)}',
    '.bz-addb{display:flex;gap:7px;margin-top:9px}.bz-addb button{flex:1;border:1px solid var(--bzl,#e6e0d8);background:var(--bzc,#f7f4f0);color:var(--bzi,#211d2a);border-radius:11px;padding:9px 4px;font-size:12px;font-weight:600;cursor:pointer;display:flex;align-items:center;justify-content:center;gap:5px}',
    '.bz-note{font-size:11px;color:var(--bzm,#6d6678);margin-top:8px}',
    '.bz-f{padding:12px 16px;border-top:1px solid var(--bzl,#e6e0d8);display:flex;gap:9px}.bz-btn{border:0;border-radius:12px;padding:12px 16px;font-weight:800;font-size:14px;font-family:inherit;cursor:pointer}.bz-btn.ghost{background:var(--bzc,#f3f0ec);color:var(--bzm,#6d6678)}.bz-btn.go{flex:1;background:linear-gradient(150deg,#f7c04a,#e9a72c);color:#1a1206}.bz-btn:disabled{opacity:.5}',
    '.bz-steps{display:flex;gap:6px;padding:12px 16px 0}.bz-steps i{height:4px;flex:1;border-radius:3px;background:var(--bzl,#e6e0d8)}.bz-steps i.done{background:var(--bzg)}',
    '.bz-thread{display:flex;flex-direction:column;gap:12px}',
    '.bz-facts{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:12px}.bz-fact{font-size:11px;color:var(--bzm,#6d6678);background:var(--bzc,#f7f4f0);border:1px solid var(--bzl,#e6e0d8);border-radius:8px;padding:4px 9px}.bz-fact b{color:var(--bzi,#211d2a)}',
    '.bz-msg{max-width:85%;display:flex;flex-direction:column;gap:5px}.bz-msg .bub{padding:10px 13px;border-radius:15px;font-size:14px;white-space:pre-wrap;word-break:break-word}.bz-msg .mt{font-size:10.5px;color:var(--bzm,#6d6678);padding:0 4px}',
    '.bz-msg.them{align-self:flex-start}.bz-msg.them .bub{background:var(--bzc,#f3f0ec);border:1px solid var(--bzl,#e6e0d8);border-bottom-left-radius:4px}',
    '.bz-msg.me{align-self:flex-end;align-items:flex-end}.bz-msg.me .bub{background:linear-gradient(150deg,#f7c04a,#e9a72c);color:#1a1206;border-bottom-right-radius:4px}',
    '.bz-sys{align-self:center;font-size:11px;color:var(--bzm,#6d6678);background:var(--bzc,#f7f4f0);border:1px solid var(--bzl,#e6e0d8);border-radius:20px;padding:4px 12px}',
    '.bz-shots{display:flex;gap:7px;flex-wrap:wrap}.bz-shot{width:110px;height:110px;border-radius:11px;overflow:hidden;position:relative;border:1px solid var(--bzl,#e6e0d8);cursor:pointer;background:#0002}.bz-shot img,.bz-shot video{width:100%;height:100%;object-fit:cover}.bz-shot .pl{position:absolute;inset:0;margin:auto;width:28px;height:28px;border-radius:50%;background:#000a;color:#fff;display:grid;place-items:center;font-size:12px}.bz-shot .cap{position:absolute;left:0;right:0;bottom:0;font-size:9px;color:#fff;padding:4px 5px;background:linear-gradient(0deg,#000b,transparent)}',
    '.bz-reply{padding:11px 14px;border-top:1px solid var(--bzl,#e6e0d8);display:flex;gap:8px;align-items:flex-end}.bz-reply .bz-ta{min-height:44px;max-height:120px}.bz-reply .snd{width:46px;height:46px;border-radius:14px;border:0;flex:none;font-size:18px;color:#1a1206;background:linear-gradient(150deg,#f7c04a,#e9a72c);cursor:pointer}',
    '.bz-acts{display:flex;gap:7px;padding:0 14px 10px}.bz-acts button{flex:1;border:1px solid var(--bzl,#e6e0d8);background:var(--bzp,#fff);color:var(--bzi,#211d2a);border-radius:11px;padding:9px;font-size:12.5px;font-weight:600;cursor:pointer}',
    '.bz-empty{text-align:center;color:var(--bzm,#6d6678);font-size:13px;padding:34px 10px}',
    '.bz-lit{position:fixed;inset:0;z-index:2147483002;background:#000d;display:none;align-items:center;justify-content:center;padding:16px}.bz-lit.on{display:flex}.bz-lit img,.bz-lit video{max-width:100%;max-height:100%;border-radius:12px}',
    '.bz-toast{position:fixed;left:50%;top:20px;transform:translateX(-50%);background:#211d2a;color:#f3f0ec;padding:11px 18px;border-radius:12px;font-weight:600;font-size:13.5px;z-index:2147483003;box-shadow:0 12px 30px -12px #000a;transition:opacity .3s;font-family:inherit}',
    '@media (prefers-color-scheme:dark){.bz-panel{--bzp:#1c1826;--bzi:#ece8f4;--bzm:#9d95af;--bzl:#312a40;--bzc:#211c2e}.bz-toast{background:#e9a72c;color:#1a1206}}',
    'body[data-theme="dark"] .bz-panel{--bzp:#1c1826;--bzi:#ece8f4;--bzm:#9d95af;--bzl:#312a40;--bzc:#211c2e}'
    ].join('');
    document.head.appendChild(s);
  }

  /* ── FAB + badge ── */
  var _badgeT=null;
  /* ── Buzón flotante MOVIBLE: se arrastra (mouse+touch) y recuerda su lugar; un toque simple = abrir. ── */
  function _bzClamp(x,y,el){ var w=el.offsetWidth||120,h=el.offsetHeight||54;
    var mx=Math.max(4,(window.innerWidth||360)-w-4), my=Math.max(4,(window.innerHeight||640)-h-4);
    return { x:Math.min(Math.max(4,x),mx), y:Math.min(Math.max(4,y),my) }; }
  function _bzApplyPos(el){ var raw; try{ raw=JSON.parse(localStorage.getItem('bz-fab-pos')||'null'); }catch(_){}
    if(!raw||typeof raw.x!=='number')return; var c=_bzClamp(raw.x,raw.y,el);
    el.style.left=c.x+'px'; el.style.top=c.y+'px'; el.style.right='auto'; el.style.bottom='auto'; }
  function _bzDraggable(el){
    var TH=6, sx=0, sy=0, ox=0, oy=0, moved=false, drag=false, pid=null;
    function mv(e){ if(!drag)return; var dx=e.clientX-sx, dy=e.clientY-sy;
      if(!moved && Math.sqrt(dx*dx+dy*dy)>TH){ moved=true; el.classList.add('bz-dragging'); el.style.right='auto'; el.style.bottom='auto'; }
      if(moved){ if(e.cancelable)e.preventDefault(); var c=_bzClamp(ox+dx,oy+dy,el); el.style.left=c.x+'px'; el.style.top=c.y+'px'; } }
    function up(){ if(!drag)return; drag=false; el.classList.remove('bz-dragging');
      window.removeEventListener('pointermove',mv); window.removeEventListener('pointerup',up); window.removeEventListener('pointercancel',up);
      try{ el.releasePointerCapture(pid); }catch(_){}
      if(moved){ var r=el.getBoundingClientRect(); try{ localStorage.setItem('bz-fab-pos',JSON.stringify({x:r.left,y:r.top})); }catch(_){} }
      else { open(); }   // no se movió → fue un toque → abrir el buzón
    }
    el.addEventListener('pointerdown',function(e){ if(e.button!=null&&e.button!==0)return;
      drag=true; moved=false; pid=e.pointerId; var r=el.getBoundingClientRect(); sx=e.clientX; sy=e.clientY; ox=r.left; oy=r.top;
      try{ el.setPointerCapture(pid); }catch(_){}
      window.addEventListener('pointermove',mv,{passive:false}); window.addEventListener('pointerup',up); window.addEventListener('pointercancel',up); });
    window.addEventListener('resize',function(){ if(el.style.left){ var r=el.getBoundingClientRect(); var c=_bzClamp(r.left,r.top,el); el.style.left=c.x+'px'; el.style.top=c.y+'px'; } });
  }

  function mount(){ if(document.getElementById('bz-fab'))return; css();
    var f=document.createElement('button'); f.id='bz-fab'; f.className='bz-fab'; f.type='button';
    f.innerHTML='<span class="i">📮</span> '+(esMaster()?'Buzón':'Reportar')+'<span class="bdg" id="bz-bdg"></span>';
    document.body.appendChild(f); _bzApplyPos(f); _bzDraggable(f);   // movible + toque = abrir
    poll(); if(_badgeT)clearInterval(_badgeT); _badgeT=setInterval(poll,45000);
    document.addEventListener('visibilitychange',function(){ if(!document.hidden)poll(); });
  }
  function poll(){ api('buzonBadge',{esMaster:esMaster(),autorNombre:nombre()}).then(function(r){
    var n=(r&&(r.data||r)&&((r.data||r).n))||0; var b=document.getElementById('bz-bdg'); if(!b)return;
    b.textContent=n>99?'99+':n; b.className='bdg'+(n>0?' on':''); }).catch(function(){}); }
  B.refrescarBadge=poll;

  /* ── overlay base ── */
  var ov=null;
  function panel(html){ if(!ov){ ov=document.createElement('div'); ov.className='bz-ov'; ov.onclick=function(e){ if(e.target===ov)close(); }; document.body.appendChild(ov); }
    ov.innerHTML='<div class="bz-panel">'+html+'</div>'; ov.classList.add('on'); }
  function close(){ if(ov)ov.classList.remove('on'); }
  B.cerrar=close;
  function head(title,sub){ return '<div class="bz-h"><div class="mbx">📮</div><div><b>'+esc(title)+'</b><div class="sub">'+esc(sub||'')+'</div></div><button class="bz-x" onclick="BUZON.cerrar()">✕</button></div>'; }

  function open(){ sfx.pop(); if(esMaster()) bandeja(); else mis(); }
  B.open=open;

  /* ══ MASTER: bandeja ══ */
  var _filt='';
  function bandeja(){ panel(head('Bandeja del Master','Reportes de tus admins')+'<div class="bz-body" id="bz-body"><div class="bz-empty">Cargando…</div></div>');
    api('buzonBandeja',{categoria:_filt}).then(function(r){ var d=(r&&(r.data||r))||{}; var R=d.resumen||{}; var ts=d.tickets||[];
      var fl=[['','Todos'],['rep','🔧 Fallas'],['ope','📊 Operativa'],['con','❓ Consultas'],['form','🎓 Capacit.']]
        .map(function(x){ return '<button class="'+(_filt===x[0]?'on':'')+'" onclick="BUZON.filtro(\''+x[0]+'\')">'+x[1]+'</button>'; }).join('');
      var list = ts.length ? ts.map(tkCard).join('') : '<div class="bz-empty">Sin reportes'+(_filt?' de este tipo':'')+'. 🎉</div>';
      document.getElementById('bz-body').innerHTML =
        '<div class="bz-stats"><div class="bz-stat"><b style="color:#e5484d">'+(R.nuevos||0)+'</b><span>nuevos</span></div><div class="bz-stat"><b style="color:#e07a1a">'+(R.proceso||0)+'</b><span>en proceso</span></div><div class="bz-stat"><b style="color:#12a877">'+(R.resueltos||0)+'</b><span>resueltos</span></div></div>'+
        '<div class="bz-filt">'+fl+'</div>'+list;
    }).catch(function(){ document.getElementById('bz-body').innerHTML='<div class="bz-empty">No pude cargar.</div>'; });
  }
  B.filtro=function(f){ _filt=f; sfx.tick(); bandeja(); };
  function tkCard(t){ var C=CAT[t.categoria]||CAT.rep;
    return '<button class="bz-tk '+((t.noVisto||0)>0?'unseen':'')+'" onclick="BUZON.abrir('+t.id+')">'+
      '<div class="row"><span class="bz-tag" style="background:'+C.c+'22;color:'+C.c+'">'+C.e+' '+esc(C.n)+'</span><span class="ago">'+hace(t.haceMin)+'</span></div>'+
      '<h4>'+esc(t.titulo)+'</h4><div class="u">'+esc(t.autor)+(t.zona?' · '+esc(t.zona):'')+' · '+esc(t.estado)+'</div>'+
      ((t.noVisto||0)>0?'<span class="nb">'+t.noVisto+'</span>':'')+'</button>'; }
  function hace(m){ m=m||0; return m<1?'ahora':m<60?('hace '+m+' min'):m<1440?('hace '+Math.round(m/60)+' h'):('hace '+Math.round(m/1440)+' d'); }

  /* ══ ADMIN: mis reportes ══ */
  function mis(){ panel(head('Mis reportes','Tu línea directa al Master')+'<div class="bz-body" id="bz-body"><div class="bz-empty">Cargando…</div></div>'+
      '<div class="bz-f"><button class="bz-btn go" onclick="BUZON.nuevo()">📮 Nuevo reporte</button></div>');
    api('buzonMis',{autorNombre:nombre()}).then(function(r){ var d=(r&&(r.data||r))||{}; var ts=d.tickets||[];
      document.getElementById('bz-body').innerHTML = ts.length ? ts.map(tkCard).join('')
        : '<div class="bz-empty">Todavía no enviaste reportes.<br>Toca <b>Nuevo reporte</b> para empezar. 📮</div>';
    }).catch(function(){ document.getElementById('bz-body').innerHTML='<div class="bz-empty">No pude cargar.</div>'; });
  }

  /* ══ COMPOSE (adaptativo) ══ */
  var step=1,cat=null,form={},media=[];
  var FORMS={
    rep:function(){ return banner('🔧','Dime <b>dónde</b> falla para reproducirlo — o convertirlo en una regla.')+
      f('¿En qué app?')+chips('app',['MOS','MosExpress','WarehouseMos','Otra'])+
      f('Módulo o pantalla específica')+'<input class="bz-in" oninput="BUZON.set(\'modulo\',this.value)" placeholder="Ej: Cajas → Cerrar caja · Yapes">'+
      f('¿Qué esperabas y qué pasó?')+'<textarea class="bz-ta" oninput="BUZON.set(\'detalle\',this.value)" placeholder="Toqué X y en vez de Y pasó Z…"></textarea>'; },
    ope:function(){ return banner('📊','Ubícalo para actuar: qué pasó, dónde y por cuánto.')+
      f('¿Qué ocurrió?')+chips('tipo',['Mal conteo','Descuadre','Faltante','Sobrante','Otro'])+
      '<div class="bz-two"><div>'+f('Zona / turno')+'<input class="bz-in" oninput="BUZON.set(\'zona\',this.value)" placeholder="Zona 3 · tarde"></div><div>'+f('Monto S/')+'<input class="bz-in" inputmode="decimal" oninput="BUZON.set(\'monto\',this.value)" placeholder="40.00"></div></div>'+
      f('Detalle')+'<textarea class="bz-ta" oninput="BUZON.set(\'detalle\',this.value)" placeholder="Cómo lo detectaste, a quién involucra…"></textarea>'; },
    con:function(){ return banner('❓','Explícala con todo el detalle que quieras.')+
      f('¿Sobre qué es?')+chips('tema',['Stock','Precios','Cajas','Créditos','Reportes','Otro'])+
      f('Tu consulta')+'<textarea class="bz-ta big" oninput="BUZON.set(\'detalle\',this.value)" placeholder="Escribe libremente: ¿dónde encuentro el stock de un producto? ¿desde qué pantalla? ¿qué ya intentaste?…"></textarea>'; },
    form:function(){ return banner('🎓','Dime el tema y las personas. Si necesitas horario, propón día y hora — el Master confirma.')+
      f('Tema de la capacitación')+'<input class="bz-in" oninput="BUZON.set(\'tema\',this.value)" placeholder="Ej: Cierre de caja para cajeros nuevos">'+
      '<div class="bz-two"><div>'+f('¿Cuántas personas?')+'<input class="bz-in" inputmode="numeric" oninput="BUZON.set(\'personas\',this.value)" placeholder="3"></div><div>'+f('Rol / puesto')+'<input class="bz-in" oninput="BUZON.set(\'rol\',this.value)" placeholder="Cajeros"></div></div>'+
      f('¿Necesitas un horario específico?')+'<div class="bz-tg"><button class="on" onclick="BUZON.hor(false,this)">El Master coordina</button><button onclick="BUZON.hor(true,this)">Propongo día y hora</button></div>'+
      '<div class="bz-rev" id="bz-rev"><div class="bz-two"><div>'+f('Día tentativo')+'<input class="bz-in" type="date" oninput="BUZON.set(\'dia\',this.value)"></div><div>'+f('Hora')+'<input class="bz-in" type="time" oninput="BUZON.set(\'hora\',this.value)"></div></div></div>'; }
  };
  var REQ={ rep:function(){return form.app&&(form.modulo||'').trim()&&(form.detalle||'').trim();},
            ope:function(){return form.tipo&&(form.detalle||'').trim();},
            con:function(){return (form.detalle||'').trim().length>3;},
            form:function(){return (form.tema||'').trim() && (!form.horario || ((form.dia||'')&&(form.hora||'')));} };
  function f(l){ return '<label class="bz-fld">'+esc(l)+'</label>'; }
  function banner(e,h){ return '<div class="bz-note" style="display:flex;gap:8px;background:#e9a72c1a;border:1px solid #e9a72c55;border-radius:11px;padding:10px 12px;margin-bottom:2px;color:inherit"><span>'+e+'</span><span>'+h+'</span></div>'; }
  function chips(key,arr){ return '<div class="bz-chips" data-k="'+key+'">'+arr.map(function(a){ return '<button class="bz-chip" onclick="BUZON.chip(\''+key+'\',\''+esc(a).replace(/'/g,"\\'")+'\',this)">'+esc(a)+'</button>'; }).join('')+'</div>'; }

  function nuevo(){ step=1;cat=null;form={};media=[]; drawCompose(); }
  B.nuevo=nuevo;
  function drawCompose(){
    var titulo = step===1?'Nuevo reporte':(CAT[cat].e+' '+CAT[cat].n);
    var body;
    if(step===1){ body='<h3 style="margin:0 0 3px">¿Qué necesitas reportar?</h3><div class="bz-note" style="margin-bottom:14px">Según lo que elijas, te pido justo lo necesario.</div><div class="bz-cats">'+
      Object.keys(CAT).map(function(k){ var C=CAT[k]; return '<button class="bz-cat'+(cat===k?' sel':'')+'" onclick="BUZON.cat(\''+k+'\')"><div class="ci" style="background:'+C.c+'22;color:'+C.c+'">'+C.e+'</div><b>'+esc(C.n)+'</b><span>'+({rep:'Un error o algo que debería tener una regla',ope:'Mal conteo, descuadre, comercial',con:'Una duda puntual',form:'Formación grupal'}[k])+'</span></button>'; }).join('')+'</div>'; }
    else if(step===2){ body='<h3 style="margin:0 0 12px">'+ (cat==='con'?'Tu consulta':cat==='form'?'La capacitación':'Cuéntame') +'</h3>'+
      f('Título')+'<input class="bz-in" value="'+esc(form.titulo||'')+'" oninput="BUZON.set(\'titulo\',this.value)" placeholder="'+esc(ph())+'">'+FORMS[cat](); }
    else { body='<h3 style="margin:0 0 3px">Fotos y video <span style="color:#8888;font-weight:400;font-size:14px">(opcional)</span></h3><div class="bz-note" style="margin-bottom:12px">Sube una o varias, de galería o cámara. Puedes explicar cada una.</div><div class="bz-media" id="bz-media"></div>'+
      '<div class="bz-addb"><button onclick="BUZON.pick(\'img\',false)">🖼️ Galería</button><button onclick="BUZON.pick(\'img\',true)">📷 Cámara</button><button onclick="BUZON.pick(\'vid\',false)">🎥 Video</button></div><div class="bz-note">🗜️ Se comprime al subir para no ocupar espacio.</div>'; }
    var nextTxt = step===1?(cat?'Siguiente →':'Elige un tipo'):step===2?'Siguiente →':'📮 Enviar al Master';
    panel(head('Reportar','Como '+esc(nombre()||'admin')+(zona()?' · '+esc(zona()):''))+
      '<div class="bz-steps"><i class="done"></i><i class="'+(step>=2?'done':'')+'"></i><i class="'+(step>=3?'done':'')+'"></i></div>'+
      '<div class="bz-body">'+body+'</div>'+
      '<div class="bz-f">'+(step>1?'<button class="bz-btn ghost" onclick="BUZON.prev()">Atrás</button>':'')+'<button class="bz-btn go" id="bz-next" onclick="BUZON.next()" '+(canNext()?'':'disabled')+'>'+nextTxt+'</button></div>');
    if(step===3) renderMedia();
  }
  function ph(){ return {rep:'Ej: “Rotar” no responde en MosExpress',ope:'Ej: Descuadre de S/40 en cierre Zona 3',con:'Ej: ¿Dónde veo el stock de un producto?',form:'Ej: Capacitación de cierre para 3 cajeros'}[cat]||''; }
  function canNext(){ if(step===1)return !!cat; if(step===2)return (form.titulo||'').trim() && REQ[cat](); return true; }
  function syncNext(){ var b=document.getElementById('bz-next'); if(b)b.disabled=!canNext(); }
  B.cat=function(k){ cat=k; form={}; sfx.pick(); drawCompose(); };
  B.set=function(k,v){ form[k]=v; syncNext(); };
  B.chip=function(key,val,el){ form[key]=val; var box=el.parentNode; [].forEach.call(box.querySelectorAll('.bz-chip'),function(c){c.classList.remove('on');}); el.classList.add('on'); sfx.tick(); syncNext(); };
  B.hor=function(on,el){ form.horario=on; [].forEach.call(el.parentNode.querySelectorAll('button'),function(b){b.classList.remove('on');}); el.classList.add('on'); var r=document.getElementById('bz-rev'); if(r)r.classList.toggle('on',on); sfx.tick(); syncNext(); };
  B.prev=function(){ if(step>1){step--;sfx.tick();drawCompose();} };
  B.next=function(){ if(!canNext())return; if(step<3){step++;sfx.tick();drawCompose();} else enviar(); };

  /* ── media ── */
  function renderMedia(){ var g=document.getElementById('bz-media'); if(!g)return;
    g.innerHTML=media.map(function(m,i){ var inner = m.up?'<div class="up">subiendo…</div>' : (m.tipo==='video'?'<video src="'+esc(m.url)+'" muted></video><div class="pl">▶</div>':'<img src="'+esc(m.url)+'">');
      return '<div class="bz-ph">'+inner+'<button class="rm" onclick="BUZON.rmMedia('+i+')">✕</button><input class="ci" value="'+esc(m.cap||'')+'" oninput="BUZON.cap('+i+',this.value)" placeholder="explicar…"></div>'; }).join('')
      + (media.length<8?'<button class="bz-ph add" onclick="BUZON.pick(\'img\',false)">＋</button>':'');
  }
  B.rmMedia=function(i){ media.splice(i,1); renderMedia(); };
  B.cap=function(i,v){ if(media[i])media[i].cap=v; };
  B.pick=function(kind,cam){ if(media.length>=8){toast('Máximo 8 archivos');return;} pickTo(kind,cam,media,renderMedia); };
  /* [2.44.28] adjuntos TAMBIÉN en las respuestas del hilo (master y admin): mismo pipeline
     de compresión/subida que el compose, con su propio arreglo por-respuesta. */
  var rMedia=[];
  B.pickR=function(kind,cam){ if(rMedia.length>=8){toast('Máximo 8 archivos');return;} pickTo(kind,cam,rMedia,renderRMedia); };
  function pickTo(kind,cam,arr,rerender){
    var inp=document.createElement('input'); inp.type='file'; inp.accept=kind==='vid'?'video/*':'image/*'; if(cam)inp.capture='environment';
    inp.onchange=function(){ var file=inp.files&&inp.files[0]; if(file)subirTo(arr,rerender,file,kind==='vid'?'video':'foto'); };
    inp.click();
  }
  function subirTo(arr,rerender,file,tipo){
    if(tipo==='video' && file.size>25*1024*1024){ toast('El video es muy pesado (máx 25MB). Grábalo más corto.'); return; }
    var slot={tipo:tipo,cap:'',up:true,url:''}; arr.push(slot); rerender(); sfx.tick();
    prep(file,tipo).then(function(o){
      return api('buzonRepSubir',{base64:o.b64,mimeType:o.mime}).then(function(r){ var d=r&&(r.data||r);
        if(!d||d.ok===false||!d.url){ throw new Error((d&&d.error)||'no se pudo subir'); }
        slot.up=false; slot.url=d.url; slot.path=d.path; rerender();
      });
    }).catch(function(e){ var i=arr.indexOf(slot); if(i>=0)arr.splice(i,1); rerender(); toast('No se pudo subir: '+(e.message||e)); });
  }
  function renderRMedia(){ var g=document.getElementById('bz-rmedia'); if(!g)return;
    g.style.display=rMedia.length?'grid':'none';
    g.innerHTML=rMedia.map(function(m,i){ var inner = m.up?'<div class="up">subiendo…</div>' : (m.tipo==='video'?'<video src="'+esc(m.url)+'" muted></video><div class="pl">▶</div>':'<img src="'+esc(m.url)+'">');
      return '<div class="bz-ph">'+inner+'<button class="rm" onclick="BUZON.rmMediaR('+i+')">✕</button><input class="ci" value="'+esc(m.cap||'')+'" oninput="BUZON.capR('+i+',this.value)" placeholder="explicar…"></div>'; }).join('');
  }
  B.rmMediaR=function(i){ rMedia.splice(i,1); renderRMedia(); };
  B.capR=function(i,v){ if(rMedia[i])rMedia[i].cap=v; };
  function prep(file,tipo){ return new Promise(function(res,rej){
    if(tipo!=='foto'){ var fr=new FileReader(); fr.onload=function(){ res({b64:fr.result,mime:file.type||'video/mp4'}); }; fr.onerror=rej; fr.readAsDataURL(file); return; }
    var img=new Image(); var url=URL.createObjectURL(file);
    img.onload=function(){ try{ var max=1280; var w=img.width,h=img.height; if(w>max||h>max){ if(w>h){h=Math.round(h*max/w);w=max;} else {w=Math.round(w*max/h);h=max;} }
      var cv=document.createElement('canvas'); cv.width=w; cv.height=h; cv.getContext('2d').drawImage(img,0,0,w,h);
      var b64=cv.toDataURL('image/jpeg',.72); URL.revokeObjectURL(url); res({b64:b64,mime:'image/jpeg'}); }catch(e){ rej(e); } };
    img.onerror=function(){ URL.revokeObjectURL(url); rej(new Error('imagen inválida')); }; img.src=url;
  }); }

  function enviar(){ if(media.some(function(m){return m.up;})){ toast('Espera a que terminen de subir las fotos'); return; }
    var campos={}; ['app','modulo','tipo','zona','monto','tema','personas','rol','dia','hora','horario'].forEach(function(k){ if(form[k]!=null&&form[k]!=='')campos[k]=form[k]; });
    var b=document.getElementById('bz-next'); if(b){b.disabled=true;b.textContent='Enviando…';}
    api('buzonCrear',{ categoria:cat, titulo:(form.titulo||'').trim(), campos:campos,
      texto:(form.detalle||form.tema||'').trim(), media:media.map(function(m){return {tipo:m.tipo,url:m.url,path:m.path,cap:m.cap||''};}),
      autorNombre:nombre(), autorZona:zona(), autorRol:String(ses().rol||'') })
    .then(function(r){ var d=r&&(r.data||r); if(!d||d.ok===false)throw new Error((d&&d.error)||'no se pudo');
      sfx.send(); enviado((d.data&&d.data.codigo)||''); poll();
    }).catch(function(e){ toast('No se pudo enviar: '+(e.message||e)); var b=document.getElementById('bz-next'); if(b){b.disabled=false;b.textContent='📮 Enviar al Master';} });
  }
  function enviado(cod){ panel('<div class="bz-body" style="text-align:center;padding:40px 22px"><div style="width:88px;height:88px;border-radius:50%;margin:0 auto 16px;display:grid;place-items:center;font-size:42px;background:#12a87722;color:#12a877;animation:bzu .5s">✓</div><h3 style="margin:0;font-size:22px">¡Enviado al Master!</h3><p style="color:#8888;margin:8px auto 0;max-width:32ch">Tu ticket <b>'+esc(cod)+'</b> quedó en el buzón. Recibirás un aviso cuando el Master responda.</p></div><div class="bz-f"><button class="bz-btn ghost" onclick="BUZON.cerrar()">Cerrar</button><button class="bz-btn go" onclick="BUZON.open()">Ver mis reportes</button></div>'); }

  /* ══ DETALLE + CHAT ══ */
  var _cur=null;
  function abrir(id){ _cur=id; sfx.pop();
    panel(head('Cargando…','')+'<div class="bz-body"><div class="bz-empty">Cargando…</div></div>');
    api('buzonTicket',{idTicket:id}).then(function(r){ var d=(r&&(r.data||r))||{}; var t=d.ticket||{}; var ms=d.mensajes||[];
      var C=CAT[t.categoria]||CAT.rep; var soyMaster=esMaster();
      var facts=factsOf(t);
      var body='<div class="bz-facts">'+facts+'</div><div class="bz-thread" id="bz-thread">'+ms.map(function(m){return msgHtml(m,soyMaster);}).join('')+'</div>';
      var acts = soyMaster? '<div class="bz-acts"><button id="bz-sug" onclick="BUZON.sugerir()" style="border-color:#7c5cff88">🤖 Sugerir respuesta</button><button onclick="BUZON.estado(\'PROCESO\')">▶ En proceso</button><button onclick="BUZON.estado(\'RESUELTO\')">✓ Resolver</button></div>' : '';
      rMedia=[];   // [2.44.28] adjuntos por-respuesta: limpio al abrir el hilo
      var reply='<div style="padding:0 14px"><div class="bz-media" id="bz-rmedia" style="display:none;margin:6px 0"></div>'+
        '<div class="bz-addb" style="margin:4px 0 6px"><button onclick="BUZON.pickR(\'img\',false)">🖼️ Galería</button><button onclick="BUZON.pickR(\'img\',true)">📷 Cámara</button><button onclick="BUZON.pickR(\'vid\',false)">🎥 Video</button><button onclick="BUZON.recorte()">✂️ Recorte</button></div></div>'+
        '<div class="bz-reply"><textarea class="bz-ta" id="bz-rta" placeholder="'+(soyMaster?'Responde… (solo esa persona recibe el aviso)':'Escribe un mensaje…')+'"></textarea><button class="snd" onclick="BUZON.responder()">➤</button></div>';
      panel('<div class="bz-h"><div class="mbx" style="background:'+C.c+'">'+C.e+'</div><div style="min-width:0"><b>'+esc(t.titulo)+'</b><div class="sub">'+esc(t.autor)+(t.zona?' · '+esc(t.zona):'')+' · '+esc(t.codigo)+'</div></div><span class="bz-est" style="margin-left:auto">'+estLabel(t.estado)+'</span><button class="bz-x" onclick="BUZON.volver()" style="margin-left:8px">✕</button></div>'+
        '<div class="bz-body">'+body+'</div>'+acts+reply);
      var th=document.getElementById('bz-thread'); if(th)th.scrollTop=th.scrollHeight;
      api('buzonVisto',{idTicket:id,quien:soyMaster?'master':'autor'}).then(poll).catch(function(){});
      var ta=document.getElementById('bz-rta'); if(ta)ta.addEventListener('keydown',function(e){ if(e.key==='Enter'&&!e.shiftKey){ e.preventDefault(); B.responder(); } });
    }).catch(function(){ toast('No pude abrir el ticket'); });
  }
  B.abrir=abrir;
  B.volver=function(){ if(esMaster())bandeja(); else mis(); };
  function factsOf(t){ var c=t.campos||{}; var out=[];
    if(t.categoria==='rep'){ if(c.app)out.push('App: <b>'+esc(c.app)+'</b>'); if(c.modulo)out.push('Módulo: <b>'+esc(c.modulo)+'</b>'); }
    if(t.categoria==='ope'){ if(c.tipo)out.push('Tipo: <b>'+esc(c.tipo)+'</b>'); if(c.zona)out.push('Zona: <b>'+esc(c.zona)+'</b>'); if(c.monto)out.push('Monto: <b>S/ '+esc(c.monto)+'</b>'); }
    if(t.categoria==='con'){ if(c.tema)out.push('Sobre: <b>'+esc(c.tema)+'</b>'); }
    if(t.categoria==='form'){ if(c.tema)out.push('Tema: <b>'+esc(c.tema)+'</b>'); if(c.personas)out.push('Personas: <b>'+esc(c.personas)+'</b>'); if(c.dia)out.push('Propuesta: <b>'+esc(c.dia)+(c.hora?' '+esc(c.hora):'')+'</b>'); }
    out.push('Estado: <b>'+esc(estLabel(t.estado))+'</b>');
    return out.map(function(x){return '<span class="bz-fact">'+x+'</span>';}).join('');
  }
  function estLabel(e){ return {NUEVO:'● Nuevo',VISTO:'● Visto',PROCESO:'▶ En proceso',RESUELTO:'✓ Resuelto'}[e]||e; }
  function msgHtml(m,soyMaster){ if(m.tipo==='sistema')return '<div class="bz-sys">— '+esc(m.texto)+' —</div>';
    var mine = soyMaster ? (m.tipo==='master') : (m.tipo!=='master');
    var shots = (m.media&&m.media.length)?'<div class="bz-shots">'+m.media.map(function(s){ var v=s.tipo==='video';
      return '<div class="bz-shot" onclick="BUZON.lit(\''+esc(s.url)+'\','+(v?1:0)+')">'+(v?'<video src="'+esc(s.url)+'" muted></video><div class="pl">▶</div>':'<img src="'+esc(s.url)+'">')+(s.cap?'<div class="cap">'+esc(s.cap)+'</div>':'')+'</div>'; }).join('')+'</div>':'';
    var bub = (m.texto?'<div class="bub">'+esc(m.texto)+'</div>':'') + shots;
    var quien = m.tipo==='master'?'Master':(esc(m.nombre)||'—');
    return '<div class="bz-msg '+(mine?'me':'them')+'">'+bub+'<div class="mt">'+quien+' · '+esc(m.hora)+'</div></div>';
  }
  B.responder=function(){ var ta=document.getElementById('bz-rta'); var v=ta?ta.value.trim():'';
    // [2.44.28] se puede responder solo con adjuntos (el backend ya lo acepta: push "📎 archivo")
    if(!v && !rMedia.length)return;
    if(rMedia.some(function(m){return m.up;})){ toast('Espera a que terminen de subir los archivos'); return; }
    var med=rMedia.map(function(m){return {tipo:m.tipo,url:m.url,path:m.path,cap:m.cap||''};});
    ta.value=''; ta.disabled=true;
    api('buzonResponder',{idTicket:_cur,autorTipo:esMaster()?'master':'admin',autorNombre:nombre(),texto:v,media:med})
    .then(function(r){ var d=r&&(r.data||r); if(!d||d.ok===false)throw new Error((d&&d.error)||'no'); rMedia=[]; sfx.send();
      // [2.44.29 · SQL 1009] cada respuesta del Master ENSEÑA a la IA (fire-and-forget; lee también las capturas)
      if(esMaster()){ try{ edgeIA({op:'indexar_qa',idTicket:_cur}).catch(function(){}); }catch(_){} }
      abrir(_cur); })
    .catch(function(e){ if(ta){ta.disabled=false;ta.value=v;} toast('No se envió: '+(e.message||e)); });
  };
  B.estado=function(e){ api('buzonEstado',{idTicket:_cur,estado:e}).then(function(r){ var d=r&&(r.data||r); if(!d||d.ok===false)throw new Error((d&&d.error)||'no'); sfx.pick(); toast('Estado: '+estLabel(e)); abrir(_cur); poll(); }).catch(function(err){ toast('No se pudo: '+(err.message||err)); }); };

  /* ══ IA del buzón + Recorte de pantalla [2.44.29 · SQL 1009 · Edge buzon-ia] ══ */
  var ANON='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k';
  function edgeIA(body){ var A=apiRef(); if(!A||!A._sb||!A._sb.mintToken) return Promise.reject(new Error('API sin mintToken'));
    return A._sb.mintToken().then(function(tk){ if(!tk) throw new Error('sin token MOS');
      return fetch('https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/buzon-ia',{ method:'POST',
        headers:{ 'apikey':ANON, 'Authorization':'Bearer '+tk, 'Content-Type':'application/json' },
        body: JSON.stringify(body) }).then(function(r){ return r.json(); }); }); }
  B.sugerir=function(){ var b=document.getElementById('bz-sug'); if(b&&b.disabled)return; if(b){b.disabled=true;b.textContent='🤖 pensando…';}
    function fin(){ var b2=document.getElementById('bz-sug'); if(b2){b2.disabled=false;b2.textContent='🤖 Sugerir respuesta';} }
    edgeIA({op:'sugerir',idTicket:_cur}).then(function(d){ fin();
      if(!d||d.ok!==true){ toast('IA: '+((d&&d.error)||'sin respuesta')); return; }
      var ta=document.getElementById('bz-rta'); if(ta){ ta.value=d.borrador||''; ta.focus(); }
      var f=(d.fuentes||[]).map(function(x){return x.seccion;}).slice(0,2).join(' · ');
      toast('🤖 Borrador listo — EDÍTALO antes de enviar'+(d.qaUsadas?' · usé '+d.qaUsadas+' respuesta(s) tuyas':'')+(f?' · Manual: '+f:''));
      sfx.pick();
    }).catch(function(e){ fin(); toast('IA: '+(e.message||e)); }); };
  /* Recorte: esconde el buzón, marcas un área del panel MOS y se adjunta como captura a la respuesta */
  var _h2cP=null;
  function h2c(){ if(window.html2canvas)return Promise.resolve(window.html2canvas); if(_h2cP)return _h2cP;
    _h2cP=new Promise(function(res,rej){ var s=document.createElement('script');
      s.src='https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js';
      s.onload=function(){res(window.html2canvas);}; s.onerror=function(){_h2cP=null;rej(new Error('no cargó html2canvas (¿sin internet?)'));};
      document.head.appendChild(s); }); return _h2cP; }
  B.recorte=function(){
    h2c().then(function(){ if(ov)ov.classList.remove('on');
      var sel=document.createElement('div');
      sel.style.cssText='position:fixed;inset:0;z-index:2147483005;cursor:crosshair;background:rgba(10,8,15,.12);touch-action:none';
      sel.innerHTML='<div style="position:fixed;top:14px;left:50%;transform:translateX(-50%);background:#0f172aee;color:#fff;padding:8px 16px;border-radius:999px;font-size:13px;font-weight:700;pointer-events:none;white-space:nowrap">✂️ Arrastra para marcar el área · Esc cancela</div>';
      var box=document.createElement('div'); box.style.cssText='position:fixed;border:2px dashed #e9a72c;background:#e9a72c22;display:none;pointer-events:none'; sel.appendChild(box);
      var sx=0,sy=0,drag=false;
      function fin(){ try{document.removeEventListener('keydown',onEsc);}catch(_){} if(sel.parentNode)sel.parentNode.removeChild(sel); }
      function onEsc(e){ if(e.key==='Escape'){ fin(); if(ov)ov.classList.add('on'); } }
      document.addEventListener('keydown',onEsc);
      sel.addEventListener('pointerdown',function(e){ drag=true; sx=e.clientX; sy=e.clientY; try{sel.setPointerCapture(e.pointerId);}catch(_){}
        box.style.display='block'; box.style.left=sx+'px'; box.style.top=sy+'px'; box.style.width='0'; box.style.height='0'; });
      sel.addEventListener('pointermove',function(e){ if(!drag)return; box.style.left=Math.min(sx,e.clientX)+'px'; box.style.top=Math.min(sy,e.clientY)+'px'; box.style.width=Math.abs(e.clientX-sx)+'px'; box.style.height=Math.abs(e.clientY-sy)+'px'; });
      sel.addEventListener('pointerup',function(e){ if(!drag)return; drag=false;
        var x=Math.min(sx,e.clientX),y=Math.min(sy,e.clientY),w=Math.abs(e.clientX-sx),h=Math.abs(e.clientY-sy);
        fin();
        if(w<12||h<12){ if(ov)ov.classList.add('on'); return; }
        setTimeout(function(){
          window.html2canvas(document.body,{ x:x+window.scrollX, y:y+window.scrollY, width:w, height:h,
            scale:Math.min(2,window.devicePixelRatio||1), useCORS:true, logging:false,
            ignoreElements:function(el){ return /bz-fab|bz-ov|bz-toast|tfanChip|tfanPanel/.test(String(el.className||'')+' '+String(el.id||'')); } })
          .then(function(cv){
            var b64=cv.toDataURL('image/jpeg',.85);
            if(ov)ov.classList.add('on');
            var slot={tipo:'foto',cap:'recorte del panel',up:true,url:''}; rMedia.push(slot); renderRMedia(); sfx.tick();
            api('buzonRepSubir',{base64:b64,mimeType:'image/jpeg'}).then(function(r){ var d=r&&(r.data||r);
              if(!d||d.ok===false||!d.url) throw new Error((d&&d.error)||'no se pudo subir');
              slot.up=false; slot.url=d.url; slot.path=d.path; renderRMedia(); toast('✂️ Recorte adjuntado');
            }).catch(function(e2){ var i=rMedia.indexOf(slot); if(i>=0)rMedia.splice(i,1); renderRMedia(); toast('Recorte: '+(e2.message||e2)); });
          }).catch(function(e3){ if(ov)ov.classList.add('on'); toast('Recorte: '+(e3.message||e3)); });
        },60);
      });
      document.body.appendChild(sel);
    }).catch(function(e){ toast('Recorte: '+(e.message||e)); });
  };

  /* ── lightbox ── */
  var lit=null;
  B.lit=function(url,isVid){ if(!lit){ lit=document.createElement('div'); lit.className='bz-lit'; lit.onclick=function(){ lit.classList.remove('on'); lit.innerHTML=''; }; document.body.appendChild(lit); }
    lit.innerHTML = isVid?'<video src="'+esc(url)+'" controls autoplay></video>':'<img src="'+esc(url)+'">'; lit.classList.add('on'); };

  /* ── init: montar cuando haya sesión ── */
  function tryMount(){ if(nombre()) mount(); }
  var _iv=setInterval(function(){ if(nombre()){ clearInterval(_iv); mount(); } },1200);
  if(document.readyState!=='loading') tryMount(); else document.addEventListener('DOMContentLoaded',tryMount);
  window.addEventListener('focus',function(){ if(nombre()&&!document.getElementById('bz-fab'))mount(); });
})();
