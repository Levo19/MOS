// [879] la Edge `ia` (la que usan las apps) respondiendo con Gemini, mismo contrato: content[0].text + usage
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = 'C:/Users/ISO/ecosistema MOS/warehouseMos';
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(path.resolve(ROOT))||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8831,r));
const ok=[], bad=[]; const T=(n,c,x)=>{ (c?ok:bad).push(n); console.log((c?'  OK  ':'  --  ')+n+(x!=null?'  ·  '+x:'')); };
const b = await chromium.launch(); const p = await (await b.newContext({ viewport:{width:420,height:900} })).newPage();
await p.addInitScript(() => { try { localStorage.setItem('wh_device_id','7e57c1a0-de1c-4a7e-b0de-c47a10906475'); } catch(_){} });
await p.goto('http://127.0.0.1:8831/', { waitUntil:'domcontentloaded' });
await p.waitForTimeout(14000);
// 1) texto → JSON (como el parser de listas)
const r1 = await Promise.race([p.evaluate(async () => { try { const t0=Date.now(); const r = await API.llamarEdgeIA({ funcion: 'prueba-gemini (texto)', max_tokens: 200, system: 'Responde SOLO JSON.', messages: [{ role:'user', content: 'Devuelve {"items":[{"nombre":"ARROZ","cant":2}]}' }] }); return { ms: Date.now()-t0, model: r.model, text: (r.content||[]).map(b=>b.text).join(''), usage: r.usage }; } catch(e) { return { error: String(e) }; } }), new Promise(r=>setTimeout(()=>r({error:'timeout 70s'}),70000))]);
console.log('     texto: ' + JSON.stringify(r1).slice(0,300));
T('la Edge `ia` responde por Gemini con la MISMA forma (content[].text + usage)', !!(r1.text && r1.usage && r1.usage.input_tokens > 0), r1.model);
T('lo que llega es el JSON pedido', /"items"/.test(r1.text||'') && /ARROZ/.test(r1.text||''));
// 2) imagen (png 1×1 rojo) con model 'claude-sonnet-5' (el del parser de listas por foto) → se mapea a Gemini
const PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==';
const r2 = await Promise.race([p.evaluate(async (png) => { try { const r = await API.llamarEdgeIA({ funcion: 'prueba-gemini (foto)', model: 'claude-sonnet-5', max_tokens: 30, thinking: { type: 'disabled' }, messages: [{ role:'user', content: [ { type:'image', source:{ type:'base64', media_type:'image/png', data: png } }, { type:'text', text:'¿De qué color es la imagen? Una sola palabra.' } ] }] }); return { model: r.model, text: (r.content||[]).map(b=>b.text).join('') }; } catch(e) { return { error: String(e) }; } }, PNG), new Promise(r=>setTimeout(()=>r({error:'timeout 70s'}),70000))]);
console.log('     foto: ' + JSON.stringify(r2));
T('una imagen (bloque estilo Claude) la ve Gemini y responde', /roj|red/i.test(r2.text||''), r2.text);
await b.close(); srv.close();
console.log('\n  ' + ok.length + ' OK   ' + bad.length + ' fallos'); process.exit(bad.length ? 1 : 0);
