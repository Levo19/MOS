(async () => {
  try {
    var app = document.getElementById('app');
    var ss = (app.__vnode || app._vnode).component.setupState;
    var s = { id: 'P-1', nombre: 'Admin', rol: 'Administrador', loginAt: Date.now() };
    localStorage.setItem('ps_session', JSON.stringify(s));
    ss.session = s;
    ss.goModule('facturacion');
    await new Promise(function (r) { setTimeout(r, 7000); });
    var comp = __COMP__;
    _facState.comprobantes = [comp];
    window._facAbrirPDF(comp);
    try { await _facEnsureQR(); } catch (e) {}
    var st = document.querySelector('#fac-pdf-modal .fpdf-stage');
    if (st) st.innerHTML = _facPdfPreviewHTML(comp, '__FMT__');
    await new Promise(function (r) { setTimeout(r, 1500); });
    var stage = document.querySelector('#fac-pdf-modal .fpdf-stage');
    var h = stage ? stage.innerHTML : '';
    return {
      ver: window.APP_VERSION,
      titulo: document.querySelector('#fac-pdf-modal .fac-emit-title').textContent,
      hasQRimg: !!stage.querySelector('img[alt="QR"]'),
      hasSON: h.indexOf('SON:') >= 0,
      hasDom: h.indexOf('San Mart') >= 0,
      hasActividad: h.indexOf('7912') >= 0,
      overflowX: document.documentElement.scrollWidth > window.innerWidth + 1,
      sonTxt: (h.match(/SON:[^<]{0,60}/) || [''])[0]
    };
  } catch (e) { return { crash: e.message, stack: (e.stack || '').slice(0, 300) }; }
})()
