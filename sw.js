// ============================================================
// MOS Admin — Service Worker
// Cambia VERSION en cada deploy para invalidar caché
// ============================================================
const VERSION = '1.0.4';
const CACHE   = 'mos-v' + VERSION;
const ASSETS  = [
  './',
  './index.html',
  './js/app.js',
  './js/api.js',
  './manifest.json',
  './version.json'
];

// ── Instalar: cachear todos los assets (no-cache para ignorar CDN) ──
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(
        ASSETS.map(url => new Request(url, { cache: 'no-store' }))
      ))
      .then(() => self.skipWaiting())
  );
});

// ── Activar: borrar cachés viejos y reclamar clientes ───────
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k !== CACHE).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

// ── Fetch: caché primero, red como fallback ──────────────────
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  // No cachear llamadas externas (GAS, etc.)
  if (url.origin !== self.location.origin) return;
  // No cachear version.json — siempre desde red para detectar cambios
  if (url.pathname.endsWith('version.json')) {
    e.respondWith(fetch(e.request).catch(() => caches.match(e.request)));
    return;
  }
  e.respondWith(
    caches.match(e.request).then(cached => {
      if (cached) return cached;
      return fetch(e.request).then(res => {
        if (!res || res.status !== 200 || res.type === 'opaque') return res;
        const clone = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, clone));
        return res;
      });
    })
  );
});

// ── Mensaje SKIP_WAITING desde la app ───────────────────────
self.addEventListener('message', e => {
  if (e.data === 'SKIP_WAITING') self.skipWaiting();
});
