// ============================================================
// MOS Admin — Service Worker
// Cambia VERSION en cada deploy para invalidar caché
// ============================================================

// ── Firebase Cloud Messaging (background push) ───────────────
importScripts('https://www.gstatic.com/firebasejs/10.12.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.12.0/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey:            'AIzaSyA_gfynRxAmlbGgHWoioaj5aeaxnnywP88',
  projectId:         'proyectomos-push',
  messagingSenderId: '328735199478',
  appId:             '1:328735199478:web:947f338ae9716a7c049cd7'
});

const _fcmMsg = firebase.messaging();
_fcmMsg.onBackgroundMessage(payload => {
  const title = payload.notification?.title || 'MOS';
  const body  = payload.notification?.body  || '';
  self.registration.showNotification(title, {
    body,
    icon:    'https://levo19.github.io/MOS/icon-192.png',
    badge:   'https://levo19.github.io/MOS/icon-192.png',
    tag:     'mos-push',
    vibrate: [200, 100, 200]
  });
});

const VERSION = '2.41.46';
const CACHE   = 'mos-v' + VERSION;
const ASSETS  = [
  './',
  './index.html',
  './turno.html',
  './liquidacion.html',
  './js/app.js',
  './js/api.js',
  './manifest.json',
  './version.json'
];

// ── Instalar: cachear secuencial con reporte de progreso ──
// postMessage al cliente por cada asset → banner muestra barra real.
// 🔥 SKIP_WAITING AUTOMÁTICO: la nueva versión activa inmediatamente
// sin esperar clic del usuario. El banner se mantiene visible (informa
// al user que va a recargar) y el cliente reacciona a controllerchange
// para hacer el reload suave.
self.addEventListener('install', e => {
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    const total = ASSETS.length;
    let done = 0;
    async function _broadcast(payload) {
      const cs = await self.clients.matchAll({ includeUncontrolled: true, type: 'window' });
      cs.forEach(c => { try { c.postMessage(payload); } catch(_){} });
    }
    await _broadcast({ type: 'sw-install-progress', done: 0, total, version: VERSION });
    for (const url of ASSETS) {
      try {
        await cache.add(new Request(url, { cache: 'no-store' }));
      } catch (err) { console.warn('[SW MOS] No se pudo cachear:', url, err); }
      done++;
      await _broadcast({ type: 'sw-install-progress', done, total, version: VERSION });
    }
    await _broadcast({ type: 'sw-install-done', total, version: VERSION });
    // Activar inmediato — toma el control al recargar
    self.skipWaiting();
  })());
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

// ── Fetch: estrategia híbrida ─────────────────────────────────
//   - Network-first (con timeout 2.5s y fallback cache): HTML, app.js,
//     api.js, version.json. Garantiza versión fresca SIEMPRE que haya
//     red. Si red lenta o offline → cache.
//   - Cache-first: el resto (imágenes, fonts, manifest, etc.).
// Esto resuelve el "veo versión vieja aunque haya deployado nueva":
// la próxima vez que abras la app, los archivos críticos vienen frescos.
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin) return;

  const path = url.pathname;
  const esCritico =
    path === '/' ||
    path.endsWith('/') ||
    path.endsWith('.html') ||
    path.endsWith('app.js') ||
    path.endsWith('api.js') ||
    path.endsWith('version.json');

  if (esCritico) {
    // Network-first con timeout 2.5s → cache fallback
    e.respondWith((async () => {
      try {
        const netPromise = fetch(e.request);
        const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 2500));
        const res = await Promise.race([netPromise, timeout]);
        if (res && res.status === 200 && res.type !== 'opaque') {
          const clone = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, clone)).catch(()=>{});
        }
        return res;
      } catch(_) {
        const cached = await caches.match(e.request);
        if (cached) return cached;
        // Último recurso: intentar red sin timeout
        return fetch(e.request);
      }
    })());
    return;
  }

  // Cache-first para assets estáticos
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
