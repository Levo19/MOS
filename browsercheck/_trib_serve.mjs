// Servidor estático mínimo para verificar el worktree con Playwright.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const root = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/.claude/worktrees/agent-a92f86812f5457f83';
const tipos = { '.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8',
  '.css':'text/css; charset=utf-8', '.json':'application/json; charset=utf-8',
  '.png':'image/png', '.jpg':'image/jpeg', '.svg':'image/svg+xml', '.ico':'image/x-icon',
  '.webmanifest':'application/manifest+json' };
http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p === '/') p = '/index.html';
  // path.join en Windows devuelve backslashes: se normaliza para comparar.
  const f = path.resolve(root, '.' + p);
  if (!f.replace(/\\/g, '/').startsWith(path.resolve(root).replace(/\\/g, '/'))) { res.writeHead(403).end(); return; }
  fs.readFile(f, (e, buf) => {
    if (e) { res.writeHead(404, { 'content-type': 'text/plain' }).end('404'); return; }
    res.writeHead(200, { 'content-type': tipos[path.extname(f).toLowerCase()] || 'application/octet-stream',
                         'cache-control': 'no-store' });
    res.end(buf);
  });
}).listen(8203, '127.0.0.1', () => console.log('sirviendo worktree en http://127.0.0.1:8203'));
