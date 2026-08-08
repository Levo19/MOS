// PURGANTE · test de purga simulada en navegador real (Playwright · Chromium)
//
//   node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_purgante_check.mjs"
//   node ... _purgante_check.mjs mos|me|mosgo        (una sola app)
//
// QUÉ HACE, por app:
//   1. sirve la app REAL desde disco (los archivos que se van a desplegar) en un
//      puerto local, con Service Workers HABILITADOS (sin eso no hay nada que probar);
//   2. arranca con el purgante DESARMADO (get_flags interceptado devuelve
//      purganteToken '0') → la app registra su SW y sus cachés de verdad;
//   3. ensucia el equipo: claves basura en localStorage, las claves de la LISTA
//      BLANCA con valores reconocibles byte a byte, cachés falsas, 'da-device-cache'
//      con la réplica del deviceId y (en ME) la IndexedDB con catálogo + snapshot;
//   4. ARMA el token SOLO en esta sesión (page.route: el flag real del servidor NO se
//      toca) y recarga → la purga debe correr UNA vez;
//   5. verifica: lista blanca intacta byte a byte, basura muerta, cachés muertas,
//      da-device-cache viva, SW re-registrado fresco, ?pv=<token> en la URL, la app
//      arranca, y un SEGUNDO load NO vuelve a purgar.
//
// La telemetría se deja llegar a la BD de VERDAD con los dispositivos TEST-CLAUDE
// (regla: los equipos de prueba se activan in-situ, jamás dejan solicitudes) y se
// borra al final con purgante_log_limpiar.
import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const APPS = {
  mos:   { dir: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS', puerto: 4141, app: 'MOS',
           done: 'mos_purgante_done', dev: 'mos_device_id',
           deviceId: '7e57c1a0-de1c-4a7e-b0de-c47a10906474' },
  me:    { dir: 'C:/Users/ISO/ecosistema MOS/MosExpress',  puerto: 4142, app: 'mosExpress',
           done: 'mosexpress_purgante_done', dev: 'mosexpress_deviceId',
           deviceId: '7e57c1a0-de1c-4a7e-b0de-c47a10906476' },
  mosgo: { dir: 'C:/Users/ISO/ecosistema MOS/MosGo',       puerto: 4143, app: 'mosGo',
           done: 'mosgo_purgante_done', dev: 'mosgo_deviceId',
           deviceId: '7e57c1a0-de00-4c1a-9de0-7e57c1a0de00' },
};

// ── LISTA BLANCA que se siembra y que DEBE sobrevivir byte a byte ─────────────
const SAGRADO = {
  mos: {
    mos_device_id: APPS.mos.deviceId,
    mos_device_auth_date_lima: '2026-08-07',
    mos_device_verify_version: '1',
    mos_device_auth_devid: APPS.mos.deviceId,
    mos_device_auth_ts: '1786100000000',
    mos_device_auth_directo: '1',
    da_optimista_ts: '1786100000000',
    MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
    mos_prov_carritos: JSON.stringify({ 'PROV-9': { items: [{ cod: '7501', qty: 12, precio: 3.5 }] } }),
    mos_prov_carrito_activo: 'PROV-9',
    // eda2_borrador / eda_borrador NO van: editor.js los borra siempre al cargar por
    // regla del dueño, así que no son datos que el purgante deba proteger.
    mos_proy_estado_v1: '{"mes":"2026-08","meta":12345.67}',
    mos_liq_seleccion: '["LIQ-1","LIQ-2"]',
    ext_horario_hasta: '1786200000000',
    seg_fuera_cache_MOS: '{"veredicto":"DENTRO","ts":1786100000000}',
    seg_badge_pos: '{"left":37,"top":412}',
    'mos_p2_draft_G-2026-001': '{"canon":[{"cod":"7501","qty":4}]}',
    mos_membrete_cola_MEMBRETE_ME: '[{"cod":"7501","n":3}]',
    'mos_jefa_aplicada_G-2026-001': '1786100000000|jefa',
    'mos_costos_aplicada_G-2026-001': '1786100000000',
  },
  me: {
    mosexpress_deviceId: APPS.me.deviceId,
    mosexpress_device_auth_date: '1786100000000',
    mosexpress_device_auth_id: APPS.me.deviceId,
    mosexpress_device_auth_date_lima: '2026-08-07',
    mosexpress_device_verify_version: '1',
    mos_device_auth_directo: '1',
    pending_sales: JSON.stringify([{ id: 'LOC-1', raw_data: { total: 88.5, items: 3 } }, { id: 'LOC-2', raw_data: { total: 12 } }]),
    mosexpress_pendingSales: '[{"id":"LEGACY-1"}]',
    mosexpress_ventas_fantasma: '[{"id":"F-1","motivo":"CAJA_CERRADA_AL_SINCRONIZAR","total":45.9}]',
    mosexpress_mut_dinero_pend: '[{"op":"COBRO","monto":30}]',
    mosexpress_ventas_hoy: '[{"id":"V-1","syncStatus":"pending","total":15}]',
    _mos_syncing: '1786100000000',
    mosexpress_carrito: '[{"cod":"7501","qty":2,"precio":5.5}]',
    mosexpress_carrito_locked: '{"carrito":[],"fecha":"2026-08-07"}',
    mosexpress_config: JSON.stringify({ completado: true, vendedor: 'PRUEBA CLAUDE', zona: 'ZONA-QA', esCajero: true }),
    mosexpress_caja_activa: '{"idCaja":"CAJA-LOCAL-9","monto":200,"fecha":"2026-08-07"}',
    mosexpress_caja_payload: '{"montoInicial":200}',
    mosexpress_session_date: 'Fri Aug 07 2026',
    mosexpress_session_dia: '2026-08-07',
    mosexpress_session_start: '1786100000000',
    mosexpress_cobrados_sesion: '[{"id":"C-1","monto":88.5}]',
    mosexpress_extras_sesion: '[{"tipo":"EGRESO","monto":10}]',
    mosexpress_es_extension: '{"idDia":"2026-08-07"}',
    mosexpress_no_recovery: '1',
    mosexpress_boot_es_login: '1',
    ext_horario_hasta: '1786200000000',
    seg_fuera_cache_mosExpress: '{"veredicto":"DENTRO"}',
    me_desbloqueo_hasta: '1786200000000',
    mosexpress_ultimos_users: '["PRUEBA CLAUDE"]',
    me_academy_v1: '{"leccion":7,"puntos":420}',
    'mosexpress_guias_ZONA-QA': '[{"id":"G-LOCAL-77","estado":"OPTIMISTA"}]',
    'mosexpress_audit_registros_PRUEBA CLAUDE': '{"fecha":"2026-08-07","items":[{"cod":"7501","guardado":false}]}',
    mos_membrete_cola_MEMBRETE_ME: '[{"cod":"7501","n":2}]',
    'mos_jefa_aplicada_G-77': '1786100000000|jefa',
  },
  mosgo: {
    mosgo_deviceId: APPS.mosgo.deviceId,
    mosgo_device_auth_date_lima: '2026-08-07',
    mosgo_device_verify_version: '1',
    mosgo_device_auth_id: APPS.mosgo.deviceId,
    mos_device_auth_directo: '1',
    da_optimista_ts: '1786100000000',
    mosgo_cola: JSON.stringify([
      { fn: 'ruta_pedido_crear', p: { local_id: 'LOC-1', total: 240.5 }, ts: 1786100000000 },
      { fn: 'ruta_cobro_registrar', p: { local_id: 'LOC-2', monto: 120 }, ts: 1786100001000 },
    ]),
    mosgo_venta: '{"cart":[{"id":"7501","c":3}],"cli":"12345678","nota":"deja en la puerta"}',
    mosgo_session: '{"nombre":"PRUEBA CLAUDE","id_personal":"TEST-CLAUDE","rol":"VENDEDOR","ts":1786100000000}',
    catv_pedido_v1: '{"items":[{"id":"abc123","ei":0,"c":2}],"nombre":"Cliente QA","tel":"999888777"}',
  },
};

// ── BASURA que DEBE morir ────────────────────────────────────────────────────
const BASURA = {
  mos: {
    MOS_CAT_CACHE: '{"ts":1,"data":[1,2,3]}', MOS_CAT_VERSION: '99',
    mos_pn_cache: '[]', mos_printers_cache: '[]',
    mos_fin_resum_2026_08_07: '{}', mos_alm_stock: '{}', mos_cfg_zonas: '{}',
    mos_liq2_pendientes: '[]', mos_prov_cache: '[]', mos_prov_prods_cache: '[]',
    mos_admin_auth_cache_v1: '{"clave":"37591219","expires":9999999999999}',
    mos_cat_filtros_v1: '{}', mosZonaLogTab: 'SIS', mos_perms_done_v1: '1',
    mos_install_dismissed_v1: '1', mos_audio_tested_v1: '1', mos_sound_off: '1',
    mos_catalogo_directo: '1', mos_proveedores_lectura: '1',
    basura_de_una_version_de_hace_un_ano: 'x',
  },
  me: {
    mosexpress_db: '{"PRODUCTO_BASE":[1,2,3]}', mosexpress_stock_zonas: '{}',
    mosexpress_cat_version: '99', mosexpress_last_autosync: '1',
    mosexpress_ultima_sync: '1', mosexpress_mos_config: '{}',
    mosexpress_meta_diaria: '{}', mosexpress_empresa_fiscal: '{}',
    mosexpress_medios_cobro: '[]', mosexpress_caja_zona_cache: '{}',
    mosexpress_clima_v1: '{}', mosexpress_pn_cache: '[]',
    mosexpress_darkmode: '1', mosexpress_streak: '9',
    me_perms_done_v1: '1', me_modo_pro: '1', me_escritura_directa: '1',
    mosexpress_ventas_ultimo_cierre: '{}', mos_turno_token: 'jwt.viejo.pegado',
    basura_de_una_version_de_hace_un_ano: 'x',
  },
  mosgo: { mosgo_snd: '0', mosgo_test: '1', basura_de_una_version_de_hace_un_ano: 'x' },
};

const TOK = String(Math.floor(Date.now() / 1000));
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };

function servir(dir, puerto) {
  const srv = http.createServer((req, res) => {
    let rel = decodeURIComponent(String(req.url).split('?')[0]);
    if (rel === '/' || rel.endsWith('/')) rel += 'index.html';
    const f = path.join(dir, rel);
    if (!f.startsWith(path.resolve(dir))) { res.writeHead(403); return res.end(); }
    fs.readFile(f, (e, b) => {
      if (e) { res.writeHead(404, { 'content-type': 'text/plain' }); return res.end('404'); }
      res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-store' });
      res.end(b);
    });
  });
  return new Promise(r => srv.listen(puerto, '127.0.0.1', () => r(srv)));
}

const w = ms => new Promise(r => setTimeout(r, ms));

async function probar(clave) {
  const A = APPS[clave], sag = SAGRADO[clave], bas = BASURA[clave];
  const T = []; const chk = (n, c, x) => { T.push([c ? '✅' : '❌', `[${clave}] ${n}`, x === undefined ? '' : String(x)]); return c; };

  // ── 0 · ASERCIÓN ESTÁTICA sobre el código que se va a desplegar ──────────────
  // La prueba de navegador demuestra el comportamiento; esta demuestra la INTENCIÓN.
  // Es la red que atrapa el error más caro posible: que alguien, meses después, saque
  // una clave de dinero de la lista blanca. Cada clave sembrada como sagrada tiene que
  // estar literalmente escrita en el BLANCA/BLANCA_PFX del index.html real.
  {
    const src = fs.readFileSync(path.join(A.dir, 'index.html'), 'utf8');
    const ini = src.indexOf('var BLANCA = ['), fin = src.indexOf('function g(k)', ini > -1 ? ini : 0);
    const blk = ini > -1 && fin > ini ? src.slice(ini, fin) : '';
    const fuera = Object.keys(sag).filter(k => {
      if (blk.indexOf("'" + k + "'") > -1) return false;
      // claves con prefijo: basta con que el prefijo esté declarado
      return !/^(mos_p2_draft_|mos_membrete_cola_|mos_jefa_aplicada_|mos_costos_aplicada_|mosexpress_guias_|mosexpress_audit_registros_)/.test(k)
        || !blk.includes("'" + k.replace(/^(mos_p2_draft_|mos_membrete_cola_|mos_jefa_aplicada_|mos_costos_aplicada_|mosexpress_guias_|mosexpress_audit_registros_).*$/, '$1') + "'");
    });
    chk('CÓDIGO · las ' + Object.keys(sag).length + ' claves sagradas están declaradas en la lista blanca del index.html',
      blk.length > 200 && fuera.length === 0, fuera.length ? 'FUERA: ' + fuera.join(', ') : 'todas declaradas');
    chk('CÓDIGO · el purgante NO elimina ninguna IndexedDB de identidad',
      src.indexOf("deleteDatabase('da_device')") === -1 && !/IDB_BORRAR\s*=\s*\[[^\]]*da_device/.test(src));
    chk('CÓDIGO · da-device-cache está en los cachés intocables del sw.js',
      fs.readFileSync(path.join(A.dir, 'sw.js'), 'utf8').includes("'da-device-cache'"));
  }

  const srv = await servir(A.dir, A.puerto);
  const URL = `http://127.0.0.1:${A.puerto}/`;
  const b = await chromium.launch();
  // serviceWorkers:'allow' es obligatorio: el purgante existe para matar SW viejos.
  const ctx = await b.newContext({ viewport: { width: 430, height: 900 }, serviceWorkers: 'allow' });
  const p = await ctx.newPage();

  // La foto de la lista blanca hay que sacarla en el instante EXACTO en que el
  // navegador vuelve del location.replace, ANTES de que la app corra: MosGo drena
  // mosgo_cola y reescribe mosgo_venta en su boot, ME toca su caja, device-auth
  // caduca da_optimista_ts… mirar el storage 10 segundos después mide la app, no la
  // purga. addInitScript corre en document_start, antes que cualquier script de la
  // página, así que esto es literalmente "lo que dejó el purgante".
  await p.addInitScript(() => {
    try {
      if (String(location.search).indexOf('pv=') > -1 && !window.__POST_PURGA) {
        var o = {};
        for (var i = 0; i < localStorage.length; i++) { var k = localStorage.key(i); o[k] = localStorage.getItem(k); }
        window.__POST_PURGA = o;
      }
    } catch (_) {}
  });

  let armado = false, reportes = [];
  const errores = [];
  p.on('pageerror', e => errores.push(String(e.message || e).slice(0, 200)));

  // get_flags interceptado: el flag REAL del servidor no se toca en ningún momento.
  await ctx.route(/rpc\/get_flags/, async r => {
    await r.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ catalogoDirecto: '1', lecturaNavegador: '1', device_verify_version: '1',
                             dispositivos_revocados: [], purganteToken: armado ? TOK : '0' }) });
  });
  await ctx.route(/rpc\/purgante_reportar/, async r => {
    try { reportes.push(JSON.parse(r.request().postData() || '{}')); } catch (_) {}
    await r.continue();          // se deja llegar a la BD de verdad (device TEST-CLAUDE)
  });
  await ctx.route(/script\.google\.com/, r => r.abort());

  try {
    // ── 1 · primer arranque con el purgante DESARMADO ──────────────────────────
    await p.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await w(7000);
    const swInicial = await p.evaluate(async () => {
      try { const rs = await navigator.serviceWorker.getRegistrations(); return rs.length; } catch (_) { return -1; }
    });
    chk('la app registra su SW en el arranque normal', swInicial >= 1, 'registrations=' + swInicial);
    chk('DESARMADO · no purgó (no hay marca de hecho)',
      await p.evaluate(k => localStorage.getItem(k) === null, A.done));

    // ── 2 · ensuciar el equipo ────────────────────────────────────────────────
    await p.evaluate(async ({ sag, bas, devKey }) => {
      localStorage.clear();
      for (const [k, v] of Object.entries(sag)) localStorage.setItem(k, v);
      for (const [k, v] of Object.entries(bas)) localStorage.setItem(k, v);
      sessionStorage.setItem('basura_de_sesion', 'x');
      // cachés viejas + la réplica del deviceId que JAMÁS se debe borrar
      const c1 = await caches.open('mos-v1.0.0-PREHISTORICA'); await c1.put('/viejo', new Response('x'));
      const c2 = await caches.open('basura-suelta');            await c2.put('/otro',  new Response('x'));
      const cd = await caches.open('da-device-cache');
      await cd.put('/__da__/' + devKey, new Response(localStorage.getItem(devKey) || ''));
    }, { sag, bas, devKey: A.dev });

    // ME: la IndexedDB lleva catálogo (muere) y session_snapshot_v1 (SAGRADO)
    if (clave === 'me') {
      await p.evaluate(() => new Promise(res => {
        const rq = indexedDB.open('mosexpress_idb', 1);
        rq.onupgradeneeded = () => { try { rq.result.createObjectStore('kv'); } catch (_) {} };
        rq.onsuccess = () => {
          const db = rq.result, tx = db.transaction('kv', 'readwrite'), st = tx.objectStore('kv');
          st.put({ PRODUCTO_BASE: [1, 2, 3] }, 'mosexpress_db');
          st.put({ config: { vendedor: 'PRUEBA CLAUDE' }, caja_activa: { idCaja: 'CAJA-LOCAL-9' }, savedAt: 1 }, 'session_snapshot_v1');
          tx.oncomplete = () => { db.close(); res(); };
          tx.onerror = () => res();
        };
        rq.onerror = () => res();
      }));
    }

    // ── 3 · ARMAR el token y recargar → debe purgar ───────────────────────────
    armado = true;
    await p.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await w(11000);   // purga + location.replace + re-arranque limpio

    // ── 4 · VEREDICTO ─────────────────────────────────────────────────────────
    chk('recargó cache-busted con ?pv=<token>', p.url().includes('pv=' + TOK), p.url().split('/').pop());
    chk('quedó marcado como purgado con ESTE token',
      await p.evaluate(k => localStorage.getItem(k), A.done) === TOK);

    // 'vivas' = el storage TAL COMO LO DEJÓ el purgante (foto de document_start).
    // 'ahora' = el storage actual, ya con la app funcionando encima.
    const ahora = await p.evaluate(() => { const o = {}; for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); o[k] = localStorage.getItem(k); } return o; });
    const vivas = await p.evaluate(() => window.__POST_PURGA || null) || ahora;
    chk('foto post-purga tomada en document_start (mide la purga, no la app)',
      await p.evaluate(() => !!window.__POST_PURGA));

    // 4a · LISTA BLANCA byte a byte
    // Dos claves las administra OTRO dueño y las reescribe/borra en cada arranque, así
    // que exigirles el byte sembrado sería medir a device-auth o a seguridad-modal, no
    // al purgante:
    //   · seg_fuera_cache_*  → seguridad-modal.js reescribe su veredicto de horario;
    //   · da_optimista_ts    → device-auth.js lo BORRA cuando vence la ventana optimista.
    // Para estas dos la garantía se verifica de forma estática más abajo: que estén
    // literalmente dentro de la lista blanca del código que se va a desplegar.
    const VOLATIL = k => k.indexOf('seg_fuera_cache_') === 0 || k === 'da_optimista_ts';
    const perdidas = [], alteradas = [];
    for (const [k, v] of Object.entries(sag)) {
      if (!(k in vivas)) { if (!VOLATIL(k)) perdidas.push(k); }
      else if (vivas[k] !== v && !VOLATIL(k)) alteradas.push(k);
    }
    chk('LISTA BLANCA · sobrevive COMPLETA (' + Object.keys(sag).length + ' claves)', perdidas.length === 0,
      perdidas.length ? 'PERDIDAS: ' + perdidas.join(', ') : 'ninguna perdida');
    chk('LISTA BLANCA · sobrevive BYTE A BYTE (sin alterar un solo carácter)', alteradas.length === 0,
      alteradas.length ? 'ALTERADAS: ' + alteradas.join(', ') : 'idénticas');

    // 4b · la basura muere
    // location.replace() no congela el JS al instante: los .then() de fetches que la app
    // vieja ya tenía en vuelo alcanzan a correr antes de que el navegador se lleve el
    // documento, y alguno reescribe su caché (mos_pn_cache es el caso típico). Eso NO es
    // basura sobreviviente: el valor viejo SÍ murió y lo que quedó es un valor FRESCO
    // escrito por la app viva. La prueba de que se purgó es que el byte ya no es el
    // sembrado. Lo inaceptable sería que sobreviviera IDÉNTICO.
    const intactas = Object.keys(bas).filter(k => k in vivas && vivas[k] === bas[k]);
    const rescritas = Object.keys(bas).filter(k => k in vivas && vivas[k] !== bas[k]);
    chk('BASURA · ninguna clave vieja sobrevivió intacta (' + Object.keys(bas).length + ' sembradas)',
      intactas.length === 0, intactas.length ? 'INTACTAS: ' + intactas.join(', ') : 'todas purgadas');
    if (rescritas.length) T.push(['ℹ️', `[${clave}] la app viva reescribió con valor fresco (no es basura vieja)`, rescritas.join(', ')]);

    // 4c · cachés
    const cach = await p.evaluate(() => caches.keys());
    chk('CACHÉS · las viejas desaparecieron', !cach.includes('mos-v1.0.0-PREHISTORICA') && !cach.includes('basura-suelta'), cach.join(', '));
    chk('CACHÉS · da-device-cache (3ª réplica del deviceId) INTACTA', cach.includes('da-device-cache'));
    const rep = await p.evaluate(async k => { const c = await caches.open('da-device-cache'); const r = await c.match('/__da__/' + k); return r ? await r.text() : null; }, A.dev);
    chk('CACHÉS · la réplica del deviceId sigue leyéndose', rep === A.deviceId, rep);

    // 4d · SW re-registrado fresco
    const sw = await p.evaluate(async () => {
      try { const rs = await navigator.serviceWorker.getRegistrations(); return rs.map(r => (r.active || r.installing || r.waiting || {}).scriptURL || '?'); } catch (_) { return []; }
    });
    chk('SW · re-registrado fresco tras la purga', sw.length >= 1 && sw.some(u => /sw\.js/.test(u)), sw.join(' | '));

    // 4e · IDB de ME
    if (clave === 'me') {
      const idb = await p.evaluate(() => new Promise(res => {
        const rq = indexedDB.open('mosexpress_idb');
        rq.onsuccess = () => {
          const db = rq.result;
          if (!db.objectStoreNames.contains('kv')) { db.close(); return res({ err: 'sin store' }); }
          const st = db.transaction('kv', 'readonly').objectStore('kv');
          const a = st.get('mosexpress_db'), s = st.get('session_snapshot_v1');
          let n = 0, out = {};
          const fin = () => { if (++n === 2) { db.close(); res(out); } };
          a.onsuccess = () => { out.catalogo = a.result === undefined ? null : 'presente'; fin(); };
          s.onsuccess = () => { out.snapshot = s.result ? JSON.stringify(s.result) : null; fin(); };
          a.onerror = s.onerror = fin;
        };
        rq.onerror = () => res({ err: 'no abre' });
      }));
      chk('IDB · el catálogo re-descargable fue borrado', idb.catalogo === null, JSON.stringify(idb).slice(0, 90));
      chk('IDB · session_snapshot_v1 (red de seguridad de la caja) SOBREVIVE',
        !!idb.snapshot && idb.snapshot.includes('CAJA-LOCAL-9'));
      chk('IDB · la base NO fue eliminada (el store kv sigue existiendo)', !idb.err, idb.err || 'ok');
      chk('ME · quedó pedido el resync de catálogo', vivas.mosexpress_force_resync === '1',
        'valor=' + vivas.mosexpress_force_resync);
    }

    // 4f · la app arranca funcional
    const vivo = await p.evaluate(() => ({
      body: (document.body.innerText || '').trim().length,
      nodos: document.body.querySelectorAll('*').length,
    }));
    chk('la app ARRANCA después de purgarse (DOM con contenido)', vivo.nodos > 30, 'nodos=' + vivo.nodos + ' texto=' + vivo.body);

    // 4g · telemetría
    const r0 = reportes.find(r => r && r.p && r.p.token === TOK);
    chk('TELEMETRÍA · reportó a la BD con device + app + versión',
      !!r0 && r0.p.device === A.deviceId && r0.p.app === A.app && !!r0.p.version_antes,
      r0 ? `${r0.p.app} v${r0.p.version_antes}` : 'sin reporte');
    // El fetch con keepalive sobrevive a la recarga, pero su .then muere con la página
    // vieja: la marca *_pend queda puesta y la limpia el reintento diferido del boot
    // siguiente. Se mide sobre 'ahora' (no sobre la foto de document_start) porque es
    // justo eso lo que se quiere probar: que el reintento existe y TERMINA.
    chk('TELEMETRÍA · el reintento diferido corre y vacía la cola de reporte',
      !(A.done.replace('done', 'pend') in ahora),
      Object.keys(ahora).filter(k => k.includes('purgante')).join(', '));

    // ── 5 · SEGUNDO load: NO debe re-purgar ───────────────────────────────────
    await p.evaluate(() => localStorage.setItem('centinela_no_repurga', 'VIVO'));
    const nRep = reportes.length;
    await p.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await w(8000);
    chk('SEGUNDO LOAD · NO re-purga (el centinela sigue vivo)',
      await p.evaluate(() => localStorage.getItem('centinela_no_repurga')) === 'VIVO');
    chk('SEGUNDO LOAD · no volvió a reportar', reportes.length === nRep, `reportes=${reportes.length}`);
    chk('SEGUNDO LOAD · no se fue a ?pv= otra vez', !p.url().includes('pv='), p.url());

    chk('sin pageerrors nuevos por el purgante',
      !errores.some(e => /purgante|localStorage|caches/i.test(e)),
      errores.slice(0, 2).join(' | ') || 'ninguno');
  } finally {
    await ctx.close(); await b.close(); srv.close();
  }
  return T;
}

const cuales = process.argv[2] ? [process.argv[2]] : ['mos', 'me', 'mosgo'];
const TODO = [];
for (const k of cuales) {
  console.log('\n═══ ' + k.toUpperCase() + ' ═══');
  try { TODO.push(...await probar(k)); }
  catch (e) { TODO.push(['❌', `[${k}] el harness reventó`, String(e.message || e).slice(0, 200)]); }
}
console.log('\n' + TODO.map(t => `${t[0]} ${t[1]}${t[2] ? '  → ' + t[2] : ''}`).join('\n'));
const fail = TODO.filter(t => t[0] === '❌').length;
console.log(`\nTOKEN de prueba usado: ${TOK}  ·  ${TODO.length - fail}/${TODO.length} en verde`);
console.log('Limpia la telemetría del harness con:  node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_purgante_limpiar.mjs" ' + TOK);
process.exit(fail ? 1 : 0);
