// MOS Admin — api.js
// Thin wrapper around the MOS GAS Web App URL

const API = (() => {
  const GAS_URL = 'https://script.google.com/macros/s/AKfycbxalFhPdiVi_e4tq1f4ce6MHoLJb2_hwPts9bCttotlArIepooUwFpMl4nsX-3x4HfM/exec';

  function getUrl()      { return GAS_URL; }
  function setUrl()      { /* URL fija en código */ }
  function isConfigured(){ return true; }

  async function _fetch(method, params) {
    const url = getUrl();
    if (!url) throw new Error('GAS URL no configurada. Abre ⚙️ Configuración.');

    if (method === 'GET') {
      const qs = new URLSearchParams(params).toString();
      const res = await fetch(`${url}?${qs}`);
      const d   = await res.json();
      if (!d.ok) throw new Error(d.error || 'Error del servidor');
      return d.data;
    } else {
      // Inyectar contexto de auditoría (quién/cuándo/dónde) en cada POST
      const audit = window.__MOS_AUDIT ? Object.assign({}, window.__MOS_AUDIT, { timestamp: new Date().toISOString() }) : null;
      const body = audit && !params._audit ? Object.assign({ _audit: audit }, params) : params;
      const res = await fetch(url, {
        method:  'POST',
        body:    JSON.stringify(body),
        headers: { 'Content-Type': 'text/plain' }
      });
      const d = await res.json();
      if (!d.ok) throw new Error(d.error || 'Error del servidor');
      return d.data;
    }
  }

  return {
    getUrl,
    setUrl,
    isConfigured,
    get:  (action, p = {}) => _fetch('GET',  { action, ...p }),
    post: (action, p = {}) => _fetch('POST', { action, ...p }),
    getProductosNuevosWH: (p = {}) => _fetch('GET',  { action: 'getProductosNuevosWH', ...p }),
    lanzarProductoNuevo:  (p = {}) => _fetch('POST', { action: 'lanzarProductoNuevo',  ...p }),
  };
})();
