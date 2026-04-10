// MOS Admin — api.js
// Thin wrapper around the MOS GAS Web App URL

const API = (() => {
  const URL_KEY = 'MOS_GAS_URL';

  function getUrl()      { return localStorage.getItem(URL_KEY) || ''; }
  function setUrl(url)   { localStorage.setItem(URL_KEY, url.trim()); }
  function isConfigured(){ return !!getUrl(); }

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
      const res = await fetch(url, {
        method:  'POST',
        body:    JSON.stringify(params),
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
    post: (action, p = {}) => _fetch('POST', { action, ...p })
  };
})();
