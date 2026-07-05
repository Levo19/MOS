(async()=>{
  var app=document.getElementById('app');
  var ss=(app.__vnode||app._vnode).component.setupState;
  var s={id:'P-1',nombre:'Admin',rol:'Administrador',loginAt:Date.now()};
  localStorage.setItem('ps_session',JSON.stringify(s));
  ss.session=s;
  ss.goModule('facturacion');
  await new Promise(r=>setTimeout(r,9000));
  var bal1=document.getElementById('fac-balanza-panel');
  var slotB=document.getElementById('fac-slot');
  var slotHtmlB=slotB?slotB.innerHTML.slice(0,90):null;
  var hasBar=!!document.getElementById('facb-bar');
  var hasTabbar=!!document.getElementById('fac-tabbar');
  window._facTab && window._facTab('historial');
  await new Promise(r=>setTimeout(r,1400));
  var bal2=document.getElementById('fac-balanza-panel');
  var slotA=document.getElementById('fac-slot');
  var slotHtmlA=slotA?slotA.innerHTML.slice(0,90):null;
  window._facTab && window._facTab('emitir');
  await new Promise(r=>setTimeout(r,900));
  return {
    hasBalanzaFina:hasBar,
    hasTabbar:hasTabbar,
    sameBalanzaNode:bal1===bal2,
    slotChanged:slotHtmlB!==slotHtmlA,
    docWidth:document.documentElement.scrollWidth,
    winWidth:window.innerWidth,
    overflowX:document.documentElement.scrollWidth>window.innerWidth+1
  };
})()
