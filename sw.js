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

const VERSION = '1.3.61';
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
  // Siempre desde red: version.json y turno.html (se actualizan frecuentemente)
  if (url.pathname.endsWith('version.json') || url.pathname.endsWith('turno.html') || url.pathname.endsWith('liquidacion.html')) {
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
