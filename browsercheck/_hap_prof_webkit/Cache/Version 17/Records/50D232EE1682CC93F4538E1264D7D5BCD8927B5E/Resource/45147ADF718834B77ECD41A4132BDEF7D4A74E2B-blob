// ════════════════════════════════════════════════════════════════════
// ExtensorHorario — módulo compartido de extensión de horario in-situ
// v1.0.2 — 2026-07-03 — CERO-GAS: _confirmar llama la RPC directa
//          mos.extender_horario_dispositivo (vía DeviceAuth.rpc), no más POST a GAS
//          extenderHorarioDispositivo. mosGasUrl ya no es requerido en abrir().
// v1.0.1 — 2026-06-05 — Senior review fixes:
//          - XSS fix: _esc() para aprobadoPor (admin nombre con HTML/JS).
//          - Tiempo restante badge actualizado en tiempo real cada 15s.
//          - Texto vigente corregido ("se mantiene el mayor") tras backend
//            Math.max — el operador no pierde tiempo si admin elige menos.
//          - Limpieza: userAgent inútil del body removido.
//          - onSuccess error ya no se silencia: logguea para debug.
//          - Multi-tab: dispatch CustomEvent 'extensor-horario:changed' al
//            recibir storage event (otras pestañas detectan al instante).
//          - UX: muestra advertencia si backend preservó extensión mayor.
// v1.0.0 — 2026-06-05
//
// Lo cargan ME y WH vía CDN MOS pages. Centraliza el modal de extensión
// de horario para que admin/master con clave 8 dig pueda habilitar
// operación pasada la hora de cierre por un tiempo limitado.
//
// Reglas:
//   - In-situ (clave admin presencial), NO remoto
//   - Por dispositivo (UUID), no por operador
//   - Opciones de tiempo: 20 min · 1 hora · 2 horas
//   - Persiste en backend (DISPOSITIVOS.Desbloqueo_Temporal_Hasta)
//   - Auditoría automática en AUDITORIA_ADMIN (tier 2)
//   - Es única — sobrescribir reemplaza al timestamp anterior
//
// Uso:
//   ExtensorHorario.abrir({
//     mosGasUrl: 'https://script.google.com/macros/s/.../exec',
//     app:       'mosExpress' | 'warehouseMos',
//     deviceId:  '<UUID>',
//     onSuccess: (data) => void   // data = { hastaTs, minutos, aprobadoPor }
//   });
//   ExtensorHorario.vigente() → number  // ms restantes (0 si no vigente)
//   ExtensorHorario.guardarLocal(hastaTs) → void
//   ExtensorHorario.limpiar() → void
// ════════════════════════════════════════════════════════════════════
(function() {
  'use strict';
  if (window.ExtensorHorario) return;  // dedupe

  var STORAGE_KEY = 'ext_horario_hasta';  // localStorage key (igual ME/WH)
  var MODAL_ID    = 'extHorarioModal';
  var CSS_ID      = 'ext-horario-css';

  // ── Helpers ──────────────────────────────────────────────────────────
  function _lsGet(k) { try { return localStorage.getItem(k); } catch(_) { return null; } }
  function _lsSet(k, v) { try { localStorage.setItem(k, v); } catch(_){} }
  function _lsRm(k)  { try { localStorage.removeItem(k); } catch(_){} }
  // [v1.0.1] Escape HTML — usado para nombres venidos del backend.
  // Sin esto, un admin con nombre "Luis<script>alert(1)</script>" ejecuta XSS.
  function _esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
      return { '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c];
    });
  }

  function _vigente() {
    var raw = _lsGet(STORAGE_KEY);
    if (!raw) return 0;
    var ts = Date.parse(raw);
    if (isNaN(ts)) return 0;
    var ms = ts - Date.now();
    return ms > 0 ? ms : 0;
  }
  function _guardarLocal(hastaIso) {
    if (!hastaIso) return;
    _lsSet(STORAGE_KEY, String(hastaIso));
  }
  function _limpiar() { _lsRm(STORAGE_KEY); }

  // ── Sonidos ──────────────────────────────────────────────────────────
  function _sonidoOpen() {
    try {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      var ctx = new Ctx();
      var osc = ctx.createOscillator();
      var gain = ctx.createGain();
      osc.type = 'sine';
      osc.frequency.value = 880;
      osc.connect(gain); gain.connect(ctx.destination);
      var t = ctx.currentTime;
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.18, t + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.25);
      osc.start(t); osc.stop(t + 0.28);
    } catch(_){}
  }
  function _sonidoTick() {
    try {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      var ctx = new Ctx();
      var osc = ctx.createOscillator();
      var gain = ctx.createGain();
      osc.type = 'square';
      osc.frequency.value = 1200;
      osc.connect(gain); gain.connect(ctx.destination);
      var t = ctx.currentTime;
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.10, t + 0.005);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.08);
      osc.start(t); osc.stop(t + 0.1);
    } catch(_){}
  }
  function _sonidoSuccess() {
    try {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      var ctx = new Ctx();
      [659, 784, 1047].forEach(function(freq, i) {
        var osc = ctx.createOscillator();
        var gain = ctx.createGain();
        osc.type = 'sine';
        osc.frequency.value = freq;
        osc.connect(gain); gain.connect(ctx.destination);
        var t = ctx.currentTime + i * 0.12;
        gain.gain.setValueAtTime(0.0001, t);
        gain.gain.exponentialRampToValueAtTime(0.30, t + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.32);
        osc.start(t); osc.stop(t + 0.35);
      });
    } catch(_){}
  }
  function _sonidoError() {
    try {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      var ctx = new Ctx();
      [311, 233].forEach(function(freq, i) {
        var osc = ctx.createOscillator();
        var gain = ctx.createGain();
        osc.type = 'square';
        osc.frequency.value = freq;
        osc.connect(gain); gain.connect(ctx.destination);
        var t = ctx.currentTime + i * 0.16;
        gain.gain.setValueAtTime(0.0001, t);
        gain.gain.exponentialRampToValueAtTime(0.22, t + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.15);
        osc.start(t); osc.stop(t + 0.18);
      });
    } catch(_){}
  }
  function _vibrar(p) { try { if (navigator.vibrate) navigator.vibrate(p); } catch(_){} }

  // ── CSS injection ────────────────────────────────────────────────────
  function _injectCss() {
    if (document.getElementById(CSS_ID)) return;
    var s = document.createElement('style');
    s.id = CSS_ID;
    s.textContent = [
      '#' + MODAL_ID + '{position:fixed;inset:0;z-index:99996;background:rgba(2,6,23,.88);backdrop-filter:blur(10px);display:flex;align-items:center;justify-content:center;padding:16px;animation:eh-fadein .2s ease-out;font-family:system-ui,-apple-system,sans-serif}',
      '#' + MODAL_ID + ' .eh-card{width:100%;max-width:460px;background:linear-gradient(135deg,#0c1f2e,#0a1424);border:1px solid rgba(34,197,94,.4);border-radius:20px;padding:26px;box-shadow:0 30px 90px rgba(34,197,94,.18),0 0 0 1px rgba(255,255,255,.04) inset;animation:eh-pop .35s cubic-bezier(.34,1.56,.64,1)}',
      '#' + MODAL_ID + ' .eh-emoji{font-size:54px;text-align:center;margin-bottom:8px;animation:eh-pulse 2s ease-in-out infinite}',
      '#' + MODAL_ID + ' .eh-title{font-size:20px;font-weight:900;color:#86efac;text-align:center;margin:0 0 4px;letter-spacing:.5px}',
      '#' + MODAL_ID + ' .eh-sub{font-size:12px;color:#94a3b8;text-align:center;margin:0 0 18px;line-height:1.5}',
      '#' + MODAL_ID + ' .eh-vigente{background:rgba(34,197,94,.12);border:1px solid rgba(34,197,94,.35);border-radius:12px;padding:10px 14px;margin-bottom:14px;text-align:center;font-size:13px;color:#86efac;font-weight:700}',
      '#' + MODAL_ID + ' .eh-vigente-min{font-family:ui-monospace,Menlo,monospace;font-size:18px;letter-spacing:1px}',
      '#' + MODAL_ID + ' .eh-label{display:block;font-size:11px;font-weight:800;text-transform:uppercase;letter-spacing:.6px;color:#cbd5e1;margin-bottom:8px;margin-top:6px}',
      '#' + MODAL_ID + ' .eh-opciones{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:14px}',
      '#' + MODAL_ID + ' .eh-opt{position:relative;background:#0a1322;border:2px solid #1e293b;border-radius:14px;padding:14px 6px;cursor:pointer;transition:all .18s;text-align:center;color:#cbd5e1;font-family:inherit}',
      '#' + MODAL_ID + ' .eh-opt:hover{border-color:#22c55e;background:rgba(34,197,94,.08);transform:translateY(-2px);box-shadow:0 6px 18px rgba(34,197,94,.18)}',
      '#' + MODAL_ID + ' .eh-opt.eh-sel{border-color:#22c55e;background:linear-gradient(135deg,rgba(34,197,94,.22),rgba(34,197,94,.08));box-shadow:0 0 0 3px rgba(34,197,94,.25),0 8px 22px rgba(34,197,94,.25);transform:translateY(-2px)}',
      '#' + MODAL_ID + ' .eh-opt-emoji{font-size:24px;display:block;margin-bottom:4px}',
      '#' + MODAL_ID + ' .eh-opt-min{font-size:16px;font-weight:900;letter-spacing:.5px}',
      '#' + MODAL_ID + ' .eh-opt-hint{font-size:9px;color:#64748b;margin-top:2px;text-transform:uppercase;letter-spacing:.5px}',
      '#' + MODAL_ID + ' .eh-opt.eh-sel .eh-opt-min{color:#86efac}',
      '#' + MODAL_ID + ' .eh-input{width:100%;box-sizing:border-box;padding:13px 16px;background:#070d18;border:1px solid #334155;border-radius:12px;color:#f1f5f9;font-family:ui-monospace,Menlo,monospace;font-size:18px;letter-spacing:.18em;text-align:center;outline:none;transition:border .15s}',
      '#' + MODAL_ID + ' .eh-input:focus{border-color:#22c55e;box-shadow:0 0 0 3px rgba(34,197,94,.18)}',
      '#' + MODAL_ID + ' .eh-err{font-size:12px;color:#fca5a5;min-height:18px;margin-top:8px;text-align:center;font-weight:600}',
      '#' + MODAL_ID + ' .eh-acciones{display:flex;gap:9px;margin-top:18px}',
      '#' + MODAL_ID + ' .eh-btn{flex:1;padding:13px;border-radius:12px;font-weight:800;font-size:14px;border:0;cursor:pointer;letter-spacing:.05em;transition:all .15s;font-family:inherit}',
      '#' + MODAL_ID + ' .eh-btn:active{transform:scale(.96)}',
      '#' + MODAL_ID + ' .eh-btn-cancel{background:transparent;border:1px solid #334155;color:#94a3b8}',
      '#' + MODAL_ID + ' .eh-btn-cancel:hover{background:#1e293b;color:#cbd5e1}',
      '#' + MODAL_ID + ' .eh-btn-ok{background:linear-gradient(135deg,#15803d,#22c55e);color:#fff;box-shadow:0 6px 18px rgba(34,197,94,.35);flex:1.6}',
      '#' + MODAL_ID + ' .eh-btn-ok:hover{box-shadow:0 8px 24px rgba(34,197,94,.5)}',
      '#' + MODAL_ID + ' .eh-btn-ok:disabled{opacity:.6;cursor:not-allowed;box-shadow:none}',
      '#' + MODAL_ID + ' .eh-hint{font-size:10px;color:#64748b;text-align:center;margin-top:12px;line-height:1.45}',
      '#' + MODAL_ID + ' .eh-success{text-align:center;padding:24px 12px}',
      '#' + MODAL_ID + ' .eh-success-ico{font-size:72px;animation:eh-pop .5s ease-out;margin-bottom:14px}',
      '#' + MODAL_ID + ' .eh-success-title{font-size:22px;font-weight:900;color:#22c55e;margin:0 0 10px}',
      '#' + MODAL_ID + ' .eh-success-sub{font-size:14px;color:#cbd5e1;margin:0 0 4px}',
      '#' + MODAL_ID + ' .eh-success-detail{font-size:12px;color:#94a3b8;margin:0}',
      '@keyframes eh-fadein{from{opacity:0}to{opacity:1}}',
      '@keyframes eh-pop{from{opacity:0;transform:scale(.85) translateY(20px)}to{opacity:1;transform:scale(1) translateY(0)}}',
      '@keyframes eh-pulse{0%,100%{transform:scale(1)}50%{transform:scale(.92)}}'
    ].join('\n');
    document.head.appendChild(s);
  }

  // ── Render del modal ─────────────────────────────────────────────────
  function _cerrarModal() {
    var m = document.getElementById(MODAL_ID);
    if (m) m.remove();
  }

  function _abrir(opts) {
    if (!opts || !opts.app || !opts.deviceId) {
      console.error('[ExtensorHorario] abrir() requiere { app, deviceId }');
      return;
    }
    if (document.getElementById(MODAL_ID)) return;  // ya abierto
    _injectCss();
    _sonidoOpen();
    _vibrar([30, 20, 30]);

    var ov = document.createElement('div');
    ov.id = MODAL_ID;

    // Si hay extensión vigente, mostrar tiempo restante (actualizado live)
    var ms = _vigente();
    var vigenteHtml = '';
    if (ms > 0) {
      var mins = Math.ceil(ms / 60000);
      vigenteHtml = '<div class="eh-vigente" id="ehVigenteBox">⏱ Vigente · <span class="eh-vigente-min" id="ehVigenteMins">' + mins + '</span> min restantes <span style="font-size:10px;color:#94a3b8;display:block;margin-top:4px">Se mantiene el tiempo <strong>mayor</strong> entre actual y nuevo</span></div>';
    }

    ov.innerHTML = ''
      + '<div class="eh-card">'
      +   '<div class="eh-emoji">⏰</div>'
      +   '<h3 class="eh-title">Extender horario operativo</h3>'
      +   '<p class="eh-sub">Permite usar la app pasado el horario de cierre.<br>Solo admin o master · clave 8 dígitos</p>'
      +   vigenteHtml
      // [511] Extensión FIJA de 1 hora (in-situ y remoto). Sin selector de tiempo.
      +   '<div class="eh-opt eh-sel" style="grid-column:1/-1;cursor:default;pointer-events:none;margin-bottom:14px">'
      +     '<span class="eh-opt-emoji">🕐</span>'
      +     '<span class="eh-opt-min">1 hora</span>'
      +     '<span class="eh-opt-hint">se concede 1 hora extra a este equipo</span>'
      +   '</div>'
      +   '<label class="eh-label">Clave admin (8 dígitos)</label>'
      +   '<input type="password" class="eh-input" id="ehClave" inputmode="numeric" maxlength="8" autocomplete="off" placeholder="••••••••">'
      +   '<p class="eh-err" id="ehErr"></p>'
      +   '<div class="eh-acciones">'
      +     '<button class="eh-btn eh-btn-cancel" id="ehCancel">Cancelar</button>'
      +     '<button class="eh-btn eh-btn-ok" id="ehOk" disabled>🔓 Extender</button>'
      +   '</div>'
      +   '<p class="eh-hint">Esta acción queda registrada en auditoría de admins. La extensión aplica únicamente a este dispositivo y vence al cumplir el tiempo escogido.</p>'
      + '</div>';
    document.body.appendChild(ov);

    var minSel = 60;   // [511] extensión FIJA de 1 hora — sin selector
    var clave = document.getElementById('ehClave');
    var btnOk = document.getElementById('ehOk');
    var err = document.getElementById('ehErr');

    function _updateOkState() {
      btnOk.disabled = !/^\d{8}$/.test(clave.value);   // solo depende de la clave (tiempo fijo)
    }

    // Trimear input al pegar para evitar el caso "12345678 " con espacio
    clave.addEventListener('input', function() {
      var trimmed = clave.value.replace(/\D/g, '').substring(0, 8);
      if (trimmed !== clave.value) clave.value = trimmed;
      _updateOkState();
    });
    clave.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' && !btnOk.disabled) _confirmar();
    });
    document.getElementById('ehCancel').onclick = function() {
      _cerrarModal();
      _vibrar([15]);
    };
    btnOk.onclick = _confirmar;

    setTimeout(function(){ if (clave) clave.focus(); }, 80);

    // [v1.0.1] Actualizar tiempo restante en tiempo real cada 15s.
    // Si vence durante la sesión del modal, el badge desaparece.
    // Cleared cuando el modal se cierra (remove() lo limpia naturalmente,
    // pero por defensa adicional guardamos timer en el nodo).
    var vigenteMinsEl = document.getElementById('ehVigenteMins');
    var vigenteBoxEl  = document.getElementById('ehVigenteBox');
    if (vigenteMinsEl) {
      var vigenteTimer = setInterval(function() {
        // Si el modal fue cerrado, parar
        if (!document.body.contains(ov)) { clearInterval(vigenteTimer); return; }
        var msNow = _vigente();
        if (msNow > 0) {
          vigenteMinsEl.textContent = String(Math.ceil(msNow / 60000));
        } else if (vigenteBoxEl) {
          vigenteBoxEl.remove();
          clearInterval(vigenteTimer);
        }
      }, 15000);
    }

    function _confirmar() {
      if (btnOk.disabled) return;
      err.textContent = '';
      if (!minSel) { err.textContent = 'Selecciona un tiempo'; return; }
      if (!/^\d{8}$/.test(clave.value)) {
        err.textContent = 'La clave debe ser 8 dígitos';
        _sonidoError(); _vibrar([40, 30, 40]);
        return;
      }
      btnOk.disabled = true;
      btnOk.textContent = 'Validando...';

      // [v1.0.2 CERO-GAS] Antes POST a GAS extenderHorarioDispositivo; ahora RPC directa
      // mos.extender_horario_dispositivo vía DeviceAuth.rpc (Content-Profile mos, anon-callable,
      // gate real = bcrypt de la clave). Mismo shape de respuesta { data:{ autorizado, hastaTs,
      // aprobadoPor, preservoExistente, error } }. Sin fallback a GAS.
      var _rpc = (window.DeviceAuth && typeof DeviceAuth.rpc === 'function') ? DeviceAuth.rpc : null;
      if (!_rpc) {
        err.textContent = 'Módulo auth no disponible — recarga la app';
        _sonidoError(); _vibrar([40, 30, 40]);
        btnOk.disabled = false; btnOk.textContent = '🔓 Extender';
        return;
      }
      _rpc('extender_horario_dispositivo', {
        deviceId:   opts.deviceId,
        claveAdmin: clave.value,
        app:        opts.app,
        minutos:    minSel
      })
      .then(function(j) {
        var d = j && j.data;
        if (!d || !d.autorizado) {
          err.textContent = (d && d.error) || (j && j.error) || 'Clave incorrecta';
          _sonidoError(); _vibrar([40, 30, 40]);
          btnOk.disabled = false;
          btnOk.textContent = '🔓 Extender';
          return;
        }
        // Éxito
        _guardarLocal(d.hastaTs);
        _sonidoSuccess();
        _vibrar([100, 50, 100, 50, 100]);
        var card = ov.querySelector('.eh-card');
        if (card) {
          // [v1.0.1 XSS FIX] Escapar aprobadoPor — admin podría tener un nombre
          // con HTML/JS en sheet ("Luis<script>alert(1)</script>"). Sin escape
          // se ejecutaba en innerHTML. _esc cubre & < > " '.
          // [v1.0.1 UX] Si backend preservó extensión existente más larga,
          // explicar al admin para evitar confusión.
          var minRealMs = Date.parse(d.hastaTs || '') - Date.now();
          var minRealMins = (!isNaN(minRealMs) && minRealMs > 0) ? Math.ceil(minRealMs / 60000) : minSel;
          var preservoMsg = d.preservoExistente
            ? '<p class="eh-success-detail" style="color:#fbbf24;margin-top:6px">⚠ Ya había extensión vigente más larga · se mantuvo (' + minRealMins + ' min)</p>'
            : '';
          card.innerHTML = ''
            + '<div class="eh-success">'
            +   '<div class="eh-success-ico">✅</div>'
            +   '<h3 class="eh-success-title">¡Extensión activada!</h3>'
            +   '<p class="eh-success-sub">+' + minSel + ' min concedidos por <strong>' + _esc(d.aprobadoPor || 'admin') + '</strong></p>'
            +   '<p class="eh-success-detail">Vence en ~' + minRealMins + ' min. La app continuará operativa.</p>'
            +   preservoMsg
            + '</div>';
        }
        setTimeout(function() {
          _cerrarModal();
          if (typeof opts.onSuccess === 'function') {
            try { opts.onSuccess(d); } catch(eOk) {
              // No silenciar — logguear para debug
              console.warn('[ExtensorHorario] onSuccess threw:', eOk);
            }
          }
        }, 1600);
      })
      .catch(function(e) {
        err.textContent = 'Sin conexión: ' + (e && e.message || 'reintenta');
        _sonidoError(); _vibrar([40, 30, 40]);
        btnOk.disabled = false;
        btnOk.textContent = '🔓 Extender';
      });
    }
  }

  // ── Multi-tab sync ───────────────────────────────────────────────────
  // [v1.0.1] Si admin extiende horario en una pestaña, otra pestaña abierta
  // en el mismo dispositivo se entera al instante via storage event sin
  // esperar al heartbeat de 10 min. La pestaña que dispara el setItem no
  // recibe su propio storage event (spec) — solo otras pestañas.
  try {
    window.addEventListener('storage', function(e) {
      if (e.key !== STORAGE_KEY) return;
      // Disparar evento custom para que la app pueda reaccionar (ej. cerrar
      // modal fuera-horario si ahora hay extensión vigente).
      try {
        window.dispatchEvent(new CustomEvent('extensor-horario:changed', {
          detail: { vigente: _vigente() }
        }));
      } catch(_){}
    });
  } catch(_){}

  // ── API pública ──────────────────────────────────────────────────────
  window.ExtensorHorario = {
    abrir:        _abrir,
    vigente:      _vigente,           // ms restantes (0 si no vigente)
    guardarLocal: _guardarLocal,      // util si backend retorna desbloqueo_temporal_hasta en otro endpoint
    limpiar:      _limpiar,
    cerrar:       _cerrarModal
  };
})();
