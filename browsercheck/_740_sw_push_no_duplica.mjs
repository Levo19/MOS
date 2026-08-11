// [740] El SW de MOS NO debe mostrar notificaciones desde onBackgroundMessage.
//
// Por qué: firebase-messaging-compat 10.12.0, al recibir un push cuyo payload trae
// `notification`, la muestra ÉL y recién después invoca onBackgroundMessage. Verificado
// leyendo el bundle que carga el SW (offset ~33242):
//     if (clients.some(visible)) return postMessage(...)      // foreground
//     n.notification && await showNotification(...)           // ← el SDK la muestra
//     t && t.onBackgroundMessageHandler && (... handler ...)  // ← y ADEMÁS llama al handler
// Con el handler mostrando otra, la misma notificación llegaba DOS veces.
//
// Este harness carga el sw.js REAL en un entorno simulado y comprueba el contrato:
//   1) aviso visible (con notification) → 0 showNotification desde el handler
//   2) comando data-only (con data.action) → 0 showNotification, 1 postMessage al cliente
//   3) push silencioso sin action → no inventa una notificación "MOS" vacía
import fs from 'fs';
import vm from 'vm';

const SW = fs.readFileSync(new URL('../sw.js', import.meta.url), 'utf8');

async function correr(payload) {
  const llamadas = { showNotification: [], postMessage: [] };
  let handler = null;
  const clienteFalso = { postMessage: m => llamadas.postMessage.push(m) };

  const self = {
    registration: {
      showNotification: (title, opts) => llamadas.showNotification.push({ title, opts }),
    },
    clients: { matchAll: async () => [clienteFalso] },
    addEventListener: () => {},
    skipWaiting: () => {},
    caches: undefined,
  };
  const ctx = {
    self,
    importScripts: () => {},                 // el SDK real no se descarga aquí
    firebase: {
      initializeApp: () => {},
      messaging: () => ({ onBackgroundMessage: h => { handler = h; } }),
    },
    console: { warn: () => {}, log: () => {}, error: () => {} },
    caches: { open: async () => ({ addAll: async () => {}, put: async () => {}, match: async () => undefined }), keys: async () => [], delete: async () => {} },
    fetch: async () => ({ ok: true }),
    Response: class {},
    Request: class {},
    URL,
    setTimeout, clearTimeout,
  };
  ctx.self.caches = ctx.caches;
  vm.createContext(ctx);
  // El SW registra listeners y termina; solo nos interesa capturar el handler de FCM.
  vm.runInContext(SW, ctx, { timeout: 5000 });

  if (!handler) return { error: 'el SW no registró onBackgroundMessage' };
  await handler(payload);
  await new Promise(r => setImmediate(r));   // matchAll() es asíncrono: dejar resolver el postMessage
  return llamadas;
}

const T = [];
const ok = (c, n, extra) => T.push((c ? 'PASS' : 'FAIL') + ' · ' + n + (extra !== undefined ? ' — ' + extra : ''));

// 1) Aviso visible: el SDK ya lo mostró, el handler no debe mostrar nada
const visible = await correr({
  notification: { title: '📦 Preingreso nuevo', body: 'SABINA · S/ 60.00 · SERGIO BAILON' },
  data: { tipo: 'wh_preingreso' },
});
ok(!visible.error, 'el SW registra onBackgroundMessage', visible.error || 'ok');
ok(visible.showNotification?.length === 0,
   'aviso visible → el handler NO muestra (evita el duplicado)',
   (visible.showNotification || []).length + ' llamadas');

// 2) Comando data-only → se reenvía al cliente, sin notificación
const cmd = await correr({ data: { action: 'gps_locate', device: 'X' } });
ok(cmd.showNotification?.length === 0, 'comando data-only → sin notificación', (cmd.showNotification || []).length);
ok(cmd.postMessage?.length === 1 && cmd.postMessage[0].type === 'mos_command',
   'comando data-only → se reenvía al cliente', JSON.stringify(cmd.postMessage));

// 3) Silencioso sin action → no inventa una notificación vacía "MOS"
const mudo = await correr({ data: { tipo: 'ping' } });
ok(mudo.showNotification?.length === 0, 'silencioso → no aparece una notificación vacía "MOS"', (mudo.showNotification || []).length);

console.log(T.join('\n'));
const fails = T.filter(x => x.startsWith('FAIL')).length;
console.log(`\nRESULTADO: ${T.length - fails} PASS / ${fails} FAIL`);
process.exit(fails ? 1 : 0);
