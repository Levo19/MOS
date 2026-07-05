(async () => {
  try {
    var app = document.getElementById('app');
    var ss = (app.__vnode || app._vnode).component.setupState;
    var s = { id: 'P-1', nombre: 'Admin', rol: 'Administrador', loginAt: Date.now() };
    localStorage.setItem('ps_session', JSON.stringify(s));
    ss.session = s;
    ss.goModule('facturacion');
    await new Promise(function (r) { setTimeout(r, 7000); });
    _facState.solicitudes = [
      { id: 'S1', serie: 'B002', numero: 45, cliente_nombre: 'Juan Perez Ramos', total: 118, solicitada: '2026-07-05 09:12', anulacion_por: 'Operador Muelle', anulacion_motivo: 'Cliente pidio factura en vez de boleta' },
      { id: 'S2', serie: 'F002', numero: 88, cliente_nombre: 'Agencia Sol del Sur SAC', total: 354, solicitada: '2026-07-05 08:40', anulacion_por: 'Cajero PS', anulacion_motivo: 'Monto equivocado, cobro doble' }
    ];
    _facRenderAlerta();
    if (__OPEN__) { window._facOpenAnulSheet(); }
    await new Promise(function (r) { setTimeout(r, 900); });
    var fab = document.querySelector('.fac-anul-fab');
    var sheet = document.getElementById('fac-anul-sheet');
    var tabbar = document.getElementById('fac-tabbar');
    var fr = fab ? fab.getBoundingClientRect() : null;
    return {
      ver: window.APP_VERSION,
      fabPresent: !!fab,
      badge: fab ? (fab.querySelector('.fac-anul-badge') || {}).textContent : null,
      fabPos: fr ? { right: Math.round(window.innerWidth - fr.right), bottom: Math.round(window.innerHeight - fr.bottom), w: Math.round(fr.width) } : null,
      tabbarHasAnular: tabbar ? tabbar.textContent.indexOf('Anular') >= 0 : null,
      sheetOpen: !!(sheet && sheet.classList.contains('visible')),
      anularBtns: document.querySelectorAll('.fac-anul-anular').length,
      overflowX: document.documentElement.scrollWidth > window.innerWidth + 1
    };
  } catch (e) { return { crash: e.message, stack: (e.stack || '').slice(0, 300) }; }
})()
