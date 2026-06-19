// ============================================================
// MOS Admin — Service Worker
// Cambia VERSION en cada deploy para invalidar caché
// ============================================================

// ── Firebase Cloud Messaging (background push) ───────────────
// 🛡️ Envuelto en try/catch: si gstatic falla al cargar (blip de red durante
//    install), el SW NO debe quedar sin instalar. Sin esto, un importScripts
//    fallido aborta TODO el SW → el dispositivo se queda pegado en la versión
//    vieja (el activate/skipWaiting nuevo nunca corre). Si FCM falla, perdemos
//    push en background pero la app SÍ actualiza y opera offline.
try {
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
      icon:    'https://levo19.github.io/MOS/icons/icon-192.png',
      badge:   'https://levo19.github.io/MOS/icons/icon-192.png',
      tag:     'mos-push',
      vibrate: [200, 100, 200]
    });
  });
} catch (err) {
  // FCM no disponible — la app sigue actualizándose y operando.
  console.warn('[SW MOS] FCM no se pudo inicializar (push background off):', err);
}

const VERSION = '2.43.284';
const CACHE   = 'mos-v' + VERSION;
// ⚠️ Los assets propios versionados (app.js/api.js) DEBEN cachearse con EL MISMO
// `?v=` que index.html usa en su <script src>, o el match offline falla por
// query-string distinto (cache-first/fallback compara la URL completa, query
// incluida). Mantener este `?v=` == VERSION y == el de index.html en cada bump.
const ASSETS  = [
  './',
  './index.html',
  './turno.html',
  './liquidacion.html',
  './js/app.js?v=' + VERSION,
  './js/api.js?v=' + VERSION,
  './manifest.json',
  './version.json',
  // [v2.43.149] Cachear módulos centralizados también — con cache-buster
  // para forzar download nuevo. Sin esto el HTTP cache podía servir versión
  // vieja del archivo (los bumps de sw.js no invalidan recursos no-listados).
  './assets/membrete/membrete-modal.js?v=2.43.149',
  './assets/seguridad/seguridad-modal.js?v=2.43.149'
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
//
// 🛡️ CONTRATO: TODA rama de respondWith resuelve a un Response válido.
//   El error "Failed to convert value to 'Response'" se produce cuando
//   respondWith recibe una promesa que cumple con undefined/no-Response.
//   El bug anterior usaba `Promise.race([fetch, timeoutQueRECHAZA])`:
//   si fetch fallaba/rechazaba antes y no había caché, el `return fetch()`
//   del catch volvía a rechazar → respondWith con promesa rechazada
//   (error de red), y bajo ciertos timings podía colar valores no-Response.
//   Ahora: timeout que RESUELVE a null (no rechaza), guards explícitos,
//   y un Response de fallback 504 si todo falla → nunca undefined, nunca
//   rechazo sin manejar.

// Response de último recurso — garantiza que respondWith jamás vea undefined.
function _respFallback(msg) {
  return new Response(msg || 'Sin conexión y sin caché disponible.', {
    status: 504,
    statusText: 'Gateway Timeout',
    headers: { 'Content-Type': 'text/plain; charset=utf-8' }
  });
}

// Cachea en background sin bloquear la respuesta. Solo respuestas 200 'basic'.
function _putEnCache(req, res) {
  try {
    if (res && res.status === 200 && res.type === 'basic') {
      const clone = res.clone();
      caches.open(CACHE).then(c => c.put(req, clone)).catch(() => {});
    }
  } catch (_) {}
}

self.addEventListener('fetch', e => {
  // No-GET (POST a supabase rpc/get_flags, etc.) → passthrough nativo del
  // navegador: NO llamamos respondWith, el browser maneja la request.
  if (e.request.method !== 'GET') return;

  let url;
  try { url = new URL(e.request.url); } catch (_) { return; }

  // Cross-origin (firebase CDN, supabase, gstatic, etc.) → passthrough nativo.
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
    // ── Network-first con timeout 2.5s → cache fallback ──
    // El timeout RESUELVE a null (no rechaza) para no convertir un
    // "lento" en un "error". Cada paso devuelve un Response real.
    e.respondWith((async () => {
      // 1) Intentar red con tope de 2.5s. fetch puede rechazar (offline);
      //    lo envolvemos para que devuelva null en vez de propagar.
      const netPromise = fetch(e.request).catch(() => null);
      const timeout = new Promise(resolve => setTimeout(() => resolve(null), 2500));
      const res = await Promise.race([netPromise, timeout]);

      if (res) {
        _putEnCache(e.request, res);
        return res;
      }

      // 2) Red lenta/caída → caché.
      const cached = await caches.match(e.request);
      if (cached) return cached;

      // 3) Sin caché → esperar a la red completa (sin timeout) por si
      //    solo fue lentitud. Envuelto: si falla, no rechazamos.
      const netFull = await netPromise.catch(() => null)
        || await fetch(e.request).catch(() => null);
      if (netFull) {
        _putEnCache(e.request, netFull);
        return netFull;
      }

      // 4) Todo falló (offline real sin caché) → Response de fallback.
      //    Garantiza que respondWith NUNCA reciba undefined ni rechazo.
      return _respFallback('Recurso no disponible offline: ' + path);
    })());
    return;
  }

  // ── Cache-first para assets estáticos (imágenes, fonts, manifest…) ──
  e.respondWith((async () => {
    const cached = await caches.match(e.request);
    if (cached) return cached;
    const res = await fetch(e.request).catch(() => null);
    if (res) {
      _putEnCache(e.request, res);
      return res;
    }
    return _respFallback('Asset no disponible offline: ' + path);
  })());
});

// ── Mensaje SKIP_WAITING desde la app ───────────────────────
self.addEventListener('message', e => {
  if (e.data === 'SKIP_WAITING') self.skipWaiting();
});
