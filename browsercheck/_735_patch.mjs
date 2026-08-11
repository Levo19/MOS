// [735] Parche quirúrgico: botón Auditar con feedback inmediato, modal-primero,
// guard de re-entrada y dedupe del refresco. CRLF-safe (split/join por líneas).
import fs from 'fs';
const APP = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js';
const IDX = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/index.html';

// app.js es CRLF; index.html es LF. Cada archivo se abre y se cierra con SU final de línea.
const EOL = f => (fs.readFileSync(f, 'utf8').indexOf('\r\n') >= 0 ? '\r\n' : '\n');
const leer = f => fs.readFileSync(f, 'utf8').split(EOL(f));
const escribir = (f, L, eol) => fs.writeFileSync(f, L.join(eol), 'utf8');
function unico(L, ancla, ctx) {
  const idx = [];
  L.forEach((l, i) => { if (l === ancla) idx.push(i); });
  if (idx.length !== 1) throw new Error(`ancla ${ctx}: ${idx.length} coincidencias\n  → ${ancla}`);
  return idx[0];
}
function unicoInc(L, frag, ctx) {
  const idx = [];
  L.forEach((l, i) => { if (l.includes(frag)) idx.push(i); });
  if (idx.length !== 1) throw new Error(`ancla(inc) ${ctx}: ${idx.length} coincidencias de "${frag}"`);
  return idx[0];
}

// ═══════════════ 1) js/app.js — reemplazo de abrirAuditar ═══════════════
const EOL_APP = EOL(APP);
let A = leer(APP);
const iIni = unico(A, '  async function abrirAuditar(idPersonal) {', 'inicio abrirAuditar');
// El final de la función: el primer '  }' aislado tras el bloque; localizamos por el
// cierre conocido de la IIFE del prefill de bon/san.
let iFin = -1;
for (let i = iIni; i < iIni + 400; i++) {
  if (A[i] === '  }' && A[i - 1] === '    })();') { iFin = i; break; }
}
if (iFin < 0) throw new Error('no encontré el cierre de abrirAuditar');
console.log('abrirAuditar: líneas ' + (iIni + 1) + '..' + (iFin + 1));

const viejo = A.slice(iIni, iFin + 1);
// Reutilizamos TAL CUAL los dos bloques async del final (créditos del día y bon/san),
// para no reescribir lógica de dinero: los extraemos del cuerpo viejo.
const jCred = viejo.findIndex(l => l.includes('// [421] Refresco EN TIEMPO REAL de los tickets a crédito DEL DÍA'));
const jTail = viejo.findIndex(l => l.includes("// [v2.41.64] BUG FIX race condition: si abrías audit OP002"));
if (jCred < 0 || jTail < 0) throw new Error('no ubiqué los bloques async de crédito / bon-san');
const blkCred = viejo.slice(jCred, jTail).map(l => (l.trim() ? '  ' + l : l));   // +2 espacios (van dentro de otra fn)
const blkBon  = viejo.slice(jTail, viejo.length - 1).map(l => (l.trim() ? '  ' + l : l));

const nuevo = `  // [735 · perf] EL CLIC DEBE RESPONDER EN EL MISMO FRAME.
  // Antes esta función era \`async\` y su PRIMERA instrucción era
  // \`await API.get('getResumenTodosDia')\`: el modal no aparecía hasta que la red
  // contestaba y el botón NO cambiaba ni un píxel mientras tanto. Medido (localhost,
  // CPU throttling 4x): primer feedback visual = NINGUNO, modal a 519-666 ms; y con
  // la tormenta de RPC del arranque saturando la conexión las mismas RPC del modal
  // subieron a 2.4 s. Por eso el dueño lo tocaba 3 veces "porque no reacciona" — y
  // eso disparaba 3 pipelines completas (3x resumen_todos_dia + 3x creditos_personal
  // + 3x liq_dia_bon_san, medido).
  // Ahora: (1) feedback en el botón SÍNCRONO, sin ningún await por delante;
  //        (2) el modal abre YA con el resumen que ya está en memoria/cache — el
  //            MISMO objeto con el que se pintó la card que se acaba de tocar;
  //        (3) el refresco de getResumenTodosDia sigue existiendo (paridad exacta con
  //            el lápiz de Liquidaciones) pero corre DETRÁS y repinta solo lo de
  //            lectura (título, KPIs, liquidación), nunca lo que el admin escribió;
  //        (4) guard de re-entrada + dedupe: clics repetidos no duplican red.
  let _auditAbriendo = null;   // idPersonal con apertura en vuelo
  let _auditRefresco = null;   // { fecha, p } refresco compartido de getResumenTodosDia

  function _auditBtnBusy(btn, on) {
    if (!btn || !btn.classList) return;
    if (on) { btn.classList.add('btn-busy'); btn.setAttribute('aria-busy', 'true'); }
    else    { btn.classList.remove('btn-busy'); btn.removeAttribute('aria-busy'); }
  }
  // El botón que disparó el clic: las cards pasan \`this\`; para llamadas programáticas
  // (lápiz de Liquidaciones, notificaciones) lo ubicamos por su onclick.
  function _auditBtnDe(idPersonal, btnEl) {
    if (btnEl && btnEl.tagName === 'BUTTON') return btnEl;
    try {
      const esc = String(idPersonal).replace(/["\\\\]/g, '\\\\$&');
      return document.querySelector('button[onclick*="abrirAuditar(\\'' + esc + '\\'"]');
    } catch (_) { return null; }
  }
  // Estado "cargando" del modal — solo se usa cuando NO hay absolutamente nada en
  // memoria ni en cache (módulo Evaluaciones nunca abierto). Aun así el clic responde.
  function _auditPintarCargando(idPersonal) {
    const t = $('auditTitle'); if (t) t.textContent = '🎯 Auditar…';
    const s = $('auditSubtitle');
    if (s) s.innerHTML = '<span class="inline-block animate-spin">⌛</span> Cargando el día…';
    const ip = $('auditIdPersonal'); if (ip) ip.value = idPersonal;
    const k = $('auditKpis');
    if (k) k.innerHTML = '<div class="fin-skel" style="height:38px"></div>'
                       + '<div class="fin-skel" style="height:38px"></div>'
                       + '<div class="fin-skel" style="height:38px"></div>';
  }
  // Un solo getResumenTodosDia en vuelo por fecha: 3 clics = 1 request, no 3.
  function _auditRefrescarResumenes(fecha) {
    if (_auditRefresco && _auditRefresco.fecha === fecha) return _auditRefresco.p;
    const p = API.get('getResumenTodosDia', { fecha }).then(fresh => {
      if (Array.isArray(fresh) && fresh.length) {
        _evalState.resumenes = fresh;
        try { localStorage.setItem('mos_fin_resum_' + fecha, JSON.stringify({ ts: Date.now(), data: fresh })); } catch (_) {}
        return fresh;
      }
      return null;
    });
    _auditRefresco = { fecha, p };
    const soltar = () => { if (_auditRefresco && _auditRefresco.p === p) _auditRefresco = null; };
    p.then(soltar, soltar);
    return p;
  }

  function abrirAuditar(idPersonal, btnEl) {
    const btn = _auditBtnDe(idPersonal, btnEl);
    // (1) GUARD DE RE-ENTRADA — el 2º y 3er clic solo re-confirman el feedback.
    if (_auditAbriendo === idPersonal) { _auditBtnBusy(btn, true); return; }
    _auditAbriendo = idPersonal;
    // (2) FEEDBACK INMEDIATO — síncrono, no hay ningún await por delante.
    _auditBtnBusy(btn, true);

    // (3) Lo que YA tenemos: memoria → cache del día en localStorage.
    let r = (_evalState.resumenes || []).find(x => x.idPersonal === idPersonal);
    if (!r) {
      try {
        const raw = localStorage.getItem('mos_fin_resum_' + _evalState.fecha);
        if (raw) {
          const parsed = JSON.parse(raw);
          if (Array.isArray(parsed && parsed.data)) {
            _evalState.resumenes = parsed.data;
            r = parsed.data.find(x => x.idPersonal === idPersonal);
          }
        }
      } catch (_) {}
    }
    // (4) Pintar YA (mismo frame del clic).
    if (r) _auditPintarModal(r, idPersonal, false);
    else   _auditPintarCargando(idPersonal);
    openModal('modalAuditar');

    // (5) Refresco DETRÁS — mismo dato que el lápiz de Liquidaciones.
    (async () => {
      let fresh = null;
      try { if (navigator.onLine) fresh = await _auditRefrescarResumenes(_evalState.fecha); } catch (_) {}
      if (_auditAbriendo === idPersonal) _auditAbriendo = null;
      _auditBtnBusy(btn, false);
      const modal = $('modalAuditar');
      const idEl  = $('auditIdPersonal');
      // El modal pudo cerrarse o saltar a otra persona mientras la red respondía.
      if (!modal || modal.classList.contains('hidden')) return;
      if (!idEl || String(idEl.value) !== String(idPersonal)) return;
      const rf = fresh ? fresh.find(x => x.idPersonal === idPersonal) : null;
      if (rf) { _auditPintarModal(rf, idPersonal, !!r); return; }
      if (!r) { toast('Personal no encontrado', 'error'); closeModal('modalAuditar'); }
    })();
  }

  // Pinta el modal desde un resumen \`r\`.
  //   esRefresco=false → apertura: pinta TODO (incluidos los campos editables).
  //   esRefresco=true  → llegó el dato fresco con el modal ya abierto: se refresca
  //                      SOLO lo de lectura. Nunca se pisa lo que el admin escribió
  //                      (comentario, bonificación, sanción, sliders, checks).
  function _auditPintarModal(r, idPersonal, esRefresco) {
    if (!r) return;
    // [RONDA 7 · FIX bono-fecha] CONGELAR la fecha del día que se está auditando,
    // en un campo que NINGÚN proceso de fondo (polling 30s, re-render de Personal
    // del Día que es HOY) puede pisar. El bono/descuento SIEMPRE se graba a ESTE día.
    _evalState.auditFechaModal = r.fecha || _evalState.fecha;
    try {
      const card = document.querySelector(\`.eval-card[data-id="\${idPersonal}"]\`);
      const badge = card?.querySelector('.badge-rol');
      const rolReal = badge?.textContent?.trim();
      if (rolReal && rolReal !== '—' && rolReal !== '⚡ del sistema') {
        r.rol = rolReal;
      }
    } catch(_){}
    // Título contextual: emoji + área según rol
    const rolU = String(r.rol || '').toUpperCase();
    const tituloIco = (rolU === 'CAJERO' || rolU === 'VENDEDOR') ? '🛒'
                    : rolU === 'ALMACENERO' ? '🏭'
                    : rolU === 'ENVASADOR'  ? '🏷'
                    : '🎯';
    const areaApp = (rolU === 'CAJERO' || rolU === 'VENDEDOR') ? 'MosExpress · POS'
                  : (rolU === 'ALMACENERO' || rolU === 'ENVASADOR') ? 'warehouseMos · Almacén'
                  : '';
    $('auditTitle').textContent = \`\${tituloIco} Auditar \${r.rol || ''} · \${r.nombre}\`;
    const evalCount = r.evaluacionesCount || 0;
    const contexto = evalCount > 0
      ? \`\${evalCount} auditoría\${evalCount !== 1 ? 's' : ''} · continuando...\`
      : 'primera auditoría del día';
    // [v2.43.374] Día PROMINENTE: el ajuste (bono/sanción) se aplica a ESTE día. Evita
    // el bug "lo puse el lunes pero era del domingo" (la auditoría usa r.fecha del card).
    const _diaTxt = (() => {
      try { return new Date((r.fecha || _evalState.fecha) + 'T00:00:00')
              .toLocaleDateString('es-PE', { weekday: 'long', day: '2-digit', month: 'long' }); }
      catch (_) { return r.fecha || ''; }
    })();
    $('auditSubtitle').innerHTML = \`📅 <strong style="color:#fbbf24">\${_diaTxt}</strong>\`
      + (areaApp ? \` · \${areaApp}\` : '') + \` · \${contexto}\`;
    $('auditIdPersonal').value = r.idPersonal;
    $('auditRol').value = r.rol || '';
    _evalState.auditR = r;

    if (!esRefresco) {
      $('auditComentario').value = '';
      // Pre-cargar acumulado del día (MAX/OR) para que el admin continúe, no empiece de cero
      const limpAcum = Math.round(((r.manual && r.manual.limpiezaPct) || 0) / 10) * 10;
      const limpProfAcum = Math.round(((r.manual && r.manual.limpiezaProfPct) || 0) / 10) * 10;
      $('auditLimpieza').value = String(limpAcum);
      $('auditLimpiezaProf').value = String(limpProfAcum);
      updateRateSlider('auditLimpieza', 'auditLimpiezaVal');
      updateRateSlider('auditLimpiezaProf', 'auditLimpiezaProfVal');

      // Pre-marcar checks ya cumplidos en evaluaciones previas
      _evalState.auditChecks = Object.assign({}, (r.manual && r.manual.checksAcum) || {});

      $('auditTogComision').classList.add('on');
      $('auditTogMeta').classList.add('on');
      // [v2.41.60] Mostrar bonificacion/sancion ACTUALES de LIQUIDACIONES_DIA
      // como prellenado en el modal. Admin ve lo que ya está y decide mantener
      // o cambiar. Si valor previo era sanción, abrir en pestaña sanción;
      // si era bonificación, abrir en bonificación; si ambos > 0, sanción.
      // [v2.41.63] _ajusteTocado: tracker para diferenciar "admin no tocó el
      // ajuste" (preservar bon/san en LIQUIDACIONES_DIA) vs "admin lo editó
      // explícitamente a 0/vacío" (resetear). Sin esto, borrar el 44 no funcionaba.
      _evalState.auditAjusteTocado = false;
      // [v2.43.373] limpiar los dos campos independientes (se prellenan abajo con los
      // valores actuales de LIQUIDACIONES_DIA vía getLiqDiaBonSan).
      ['auditBonifMonto','auditBonifMotivoInp','auditSancionMonto','auditSancionMotivoInp'].forEach(id => {
        const el = $(id); if (el) el.value = '';
      });
    }

    _renderAuditKpis(r);
    _renderAuditChecklist(r.rol);
    _renderAuditLiquidacion();
    // En un refresco los dos fetches de abajo YA corrieron en la apertura: no se repiten.
    if (esRefresco) return;

${blkCred.join('\n')}
${blkBon.join('\n')}
  }`.split('\n');

A = A.slice(0, iIni).concat(nuevo, A.slice(iFin + 1));

// ── call sites: pasar `this` para que el feedback vaya al botón exacto ──
const c1 = unicoInc(A, `\${idForEval ? \`<button onclick="MOS.abrirAuditar('\${idForEval}')"`, 'card personal');
A[c1] = A[c1].replace(`MOS.abrirAuditar('\${idForEval}')`, `MOS.abrirAuditar('\${idForEval}', this)`);
const c2 = unicoInc(A, `<button onclick="MOS.abrirAuditar('\${r.idPersonal}')"`, 'card evaluaciones');
A[c2] = A[c2].replace(`MOS.abrirAuditar('\${r.idPersonal}')`, `MOS.abrirAuditar('\${r.idPersonal}', this)`);

escribir(APP, A, EOL_APP);
console.log('✓ app.js parchado (' + A.length + ' líneas)');

// ═══════════════ 2) index.html — CSS del feedback ═══════════════
const EOL_IDX = EOL(IDX);
let H = leer(IDX);
const anclaCss = '    .btn-primary:hover { opacity: .85; }';
const iCss = unico(H, anclaCss, 'btn-primary:hover');
const css = [
  '    /* [735 · perf] El clic SIEMPRE tiene respuesta visible, aunque el dato tarde.',
  '       :active lo pinta el navegador en el pointerdown (antes de que corra JS), así',
  '       que el botón responde incluso si el hilo principal está ocupado. .btn-busy lo',
  '       pone el handler en el mismo frame del clic y añade el spinner. */',
  '    .btn-primary:active { transform: scale(.955); opacity: .9; }',
  '    .btn-busy { position: relative; opacity: .75; pointer-events: none; }',
  '    .btn-busy::after {',
  '      content: ""; position: absolute; right: 6px; top: 50%; width: 11px; height: 11px;',
  '      margin-top: -5.5px; border: 2px solid currentColor; border-right-color: transparent;',
  '      border-radius: 50%; animation: spin .6s linear infinite;',
  '    }',
  '    .btn-busy { padding-right: 24px; }'
];
H = H.slice(0, iCss + 1).concat(css, H.slice(iCss + 1));
escribir(IDX, H, EOL_IDX);
console.log('✓ index.html parchado (' + H.length + ' líneas)');
