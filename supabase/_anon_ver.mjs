import fs from 'fs';
// simular la llamada de MosGo (anon key + Content-Profile mos) a catalogo_version
const html = fs.readFileSync('C:/Users/ISO/ecosistema MOS/MosGo/index.html','utf8');
const url = html.match(/SB_URL\s*=\s*'([^']+)'/)[1];
const anon = html.match(/SB_ANON\s*=\s*'([^']+)'/)[1];
const r = await fetch(url + '/rest/v1/rpc/catalogo_version', { method:'POST',
  headers: { 'Content-Type':'application/json', apikey: anon, Authorization:'Bearer '+anon,
    'Accept-Profile':'mos','Content-Profile':'mos' }, body: JSON.stringify({ p:{} }) });
console.log('HTTP', r.status, '→', (await r.text()).slice(0,120));
