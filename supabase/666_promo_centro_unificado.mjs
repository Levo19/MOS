// [666] FUSIÓN de los dos espacios de promociones en UN overlay (🎯 Centro de Promociones).
//   · app.js  : nuevo overlay (Mis promociones · Sugerencias del día · Playbook) + form ampliado
//   · index.html: muere la vista #view-promociones; el form gana paso cero (estrategia),
//                 presets de vigencia, horario y panel de margen en vivo. + CSS.
import fs from 'fs';

const APP = '../js/app.js', IDX = '../index.html';
let s = fs.readFileSync(APP, 'utf8');
let h = fs.readFileSync(IDX, 'utf8');
const n0 = s.length, m0 = h.length;

const R = (str, a, b, tag) => {
  const i = str.indexOf(a);
  if (i < 0) throw new Error('ANCLA NO ENCONTRADA [' + tag + ']: ' + a.slice(0, 70));
  if (str.indexOf(a, i + 1) >= 0) throw new Error('ANCLA DUPLICADA [' + tag + ']: ' + a.slice(0, 70));
  return str.slice(0, i) + b + str.slice(i + a.length);
};

if (s.includes('[666] CENTRO DE PROMOCIONES')) { console.log('ya aplicado (app.js)'); process.exit(0); }

// ── 1. overlay unificado reemplaza al radar viejo ───────────────────
const OVER = fs.readFileSync('666_promo_centro_unificado.js.txt', 'utf8');
const ini = s.indexOf('  // [695] rotación semanal (misma fuente que el chip del card: series de S.rotacion)');
const finM = '  function _fpPill(on, hu) {';
const fin = s.indexOf(finM);
if (ini < 0 || fin < 0 || fin < ini) throw new Error('no ubico el bloque del promo-centro viejo');
s = s.slice(0, ini) + OVER + '\n' + s.slice(fin);

// ── 2. bloque de form (estrategias, presets, margen) ────────────────
const FORM = fs.readFileSync('666_promo_form.js.txt', 'utf8');
s = R(s, '  function promoNuevoForm() {', FORM + '\n  function promoNuevoForm() {', 'form-block');

// ── 3. _renderPromoLista ahora repinta el overlay (la vista murió) ──
const oldRender = s.indexOf('  function _renderPromoLista() {');
const oldRenderEnd = s.indexOf('  // Toggle inline: activar/desactivar promoción sin abrir form (optimista)');
if (oldRender < 0 || oldRenderEnd < 0) throw new Error('no ubico _renderPromoLista');
s = s.slice(0, oldRender)
  + '  // [666] la vista aparte murió: pintar la lista = repintar el overlay único.\n'
  + '  function _renderPromoLista() { if (document.getElementById(\'promoCentro\')) _pcPinta(); }\n\n'
  + s.slice(oldRenderEnd);

// ── 4. loadPromociones sin la vista muerta + nav redirige al overlay ─
s = R(s, "    $('promoListView').classList.remove('hidden');",
       "    // [666] la vista #view-promociones ya no existe: esto solo refresca datos.", 'loadPromo-view');
s = R(s, "  function _promoForzarRefresh() {",
       "  function _promoForzarRefresh() {", 'noop');
s = R(s, "        case 'promociones':  await loadPromociones();  break;",
       "        // [666] el módulo aparte murió: 'promociones' abre el overlay único 🎯\n" +
       "        case 'promociones':  abrirPromoCentro('mis');  break;", 'nav-case');

// ── 5. promoNuevoForm: resetear los campos nuevos ───────────────────
s = R(s, "    $('promoTogActiva').classList.add('on');\n    $('promoError').style.display = 'none';\n  }",
`    $('promoTogActiva').classList.add('on');
    $('promoError').style.display = 'none';
    // [666] campos nuevos: jugada, horario y notas de la sugerencia
    _promoState.estrategia = '';
    _promoState.sugRef = null;
    $('promoSugNota')?.classList.add('hidden');
    const mb = $('promoMargenBox'); if (mb) mb.innerHTML = '';
    promoPresetHora('todo');
    promoPresetVig(30);
    promoPintaEstrategias();
  }`, 'nuevoForm-reset');

// ── 6. promoEditar: cargar estrategia + horario ─────────────────────
s = R(s, "    $('promoTogActiva').classList.toggle('on', !!p.activa);\n    promoActualizarEjemplo();",
`    $('promoTogActiva').classList.toggle('on', !!p.activa);
    // [666] jugada guardada + ventana horaria
    _promoState.estrategia = p.estrategia || '';
    promoPintaEstrategias();
    $('promoEstrGrid')?.classList.add('hidden');
    if (p.horaDesde && p.horaHasta) promoPresetHora('custom', p.horaDesde, p.horaHasta);
    else promoPresetHora('todo');
    promoActualizarEjemplo();
    promoRecalcMargen();`, 'editar-extra');

// ── 7. promoActualizarEjemplo repinta el margen en vivo ─────────────
s = R(s, "      ej.textContent = `Ejemplo: comprando ${cant}+ unidades, ${val}% de descuento sobre el subtotal`;\n    }\n  }",
`      ej.textContent = \`Ejemplo: comprando \${cant}+ unidades, \${val}% de descuento sobre el subtotal\`;
    }
    promoRecalcMargen();   // [666] margen en vivo junto al ejemplo
  }`, 'ejemplo-margen');

// ── 8. al elegir producto: sugerir valor por margen + repintar ──────
s = R(s, "    $('promoBuscarRes').style.display = 'none';\n    $('promoBuscar').value = descripcion;\n  }",
`    $('promoBuscarRes').style.display = 'none';
    $('promoBuscar').value = descripcion;
    promoSugerirValor();   // [666] descuento sugerido según el margen real
    promoRecalcMargen();
  }`, 'seleccionar-base');

// ── 9. promoGuardar: horario + estrategia + doble confirmación a pérdida ─
s = R(s, `    const isEdit = !!_promoState.editando;
    if (isEdit) params.idPromo = _promoState.editando;`,
`    // [666] ventana horaria (null = todo el día) + jugada del playbook
    const _hd = ($('promoHDesde') || {}).value || '';
    const _hh = ($('promoHHasta') || {}).value || '';
    if ((!!_hd) !== (!!_hh)) { errEl.textContent = 'Horario incompleto: define hora de inicio y de fin'; errEl.style.display = 'block'; return; }
    if (_hd && _hd === _hh) { errEl.textContent = 'El horario de inicio y fin no pueden ser iguales'; errEl.style.display = 'block'; return; }
    params.horaDesde = _hd;
    params.horaHasta = _hh;
    if (_promoState.estrategia) params.estrategia = _promoState.estrategia;

    // [666] jamás por debajo del costo sin que el dueño lo confirme dos veces
    if (_promoPierdePlata(params)) {
      const ok = await _modalConfirm('El precio queda POR DEBAJO de tu costo: cada unidad vendida te resta plata. Solo tiene sentido si es un remate a propósito.',
        { danger: true, titulo: '⚠ Vas a vender a pérdida', okText: 'Sí, es un remate' });
      if (!ok) return;
      const ok2 = await _modalConfirm('Confirmación final: la promo se publica al POS a pérdida.',
        { danger: true, titulo: '¿Seguro?', okText: 'Publicar igual' });
      if (!ok2) return;
    }

    const isEdit = !!_promoState.editando;
    if (isEdit) params.idPromo = _promoState.editando;`, 'guardar-extra');

// ── 10. helper de pérdida + persistir estrategia/horas en el optimista ─
s = R(s, '  async function promoGuardar() {',
`  // [666] ¿el precio propuesto queda bajo el costo del producto (o del combo)?
  function _promoPierdePlata(params) {
    try {
      if (params.tipo === 'COMBO') {
        let costo = 0, ok = false;
        (params.items || []).forEach(it => {
          const pr = (S.productos || []).find(x => (x.skuBase || x.idProducto) === it.skuBase);
          const pc = pr ? (parseFloat(pr.precioCosto) || 0) : 0;
          if (pc > 0) { costo += pc * (parseFloat(it.cantidad) || 1); ok = true; }
        });
        return ok && costo > 0 && (parseFloat(params.valorPromo) || 0) < costo;
      }
      const pr = (S.productos || []).find(x => (x.skuBase || x.idProducto) === params.skuBase);
      if (!pr) return false;
      const pc = parseFloat(pr.precioCosto) || 0, pv = parseFloat(pr.precioVenta) || 0;
      if (pc <= 0) return false;
      const n = Math.max(1, parseFloat(params.cantMin) || 1);
      let unit;
      if (params.tipo === 'PORCENTAJE') unit = pv * (1 - (parseFloat(params.valorPromo) || 0) / 100);
      else unit = (String(params.valorModo).toUpperCase() === 'TOTAL')
                  ? (parseFloat(params.valorPromo) || 0) / n
                  : (parseFloat(params.valorPromo) || 0);
      return unit < pc;
    } catch (_) { return false; }
  }

  async function promoGuardar() {`, 'perdida-helper');

s = R(s, `      activa:        !!params.activa,
      notas:         '',
      _tmp:          !isEdit
    };`,
`      activa:        !!params.activa,
      horaDesde:     params.horaDesde || null,
      horaHasta:     params.horaHasta || null,
      estrategia:    params.estrategia || (_promoState.sugRef && _promoState.sugRef.estrategia) || '',
      actualizado:   new Date().toISOString().slice(0, 16).replace('T', ' '),
      notas:         '',
      _tmp:          !isEdit
    };`, 'optimista-campos');

// ── 11. exports ────────────────────────────────────────────────────
s = R(s, '    loadPromociones, promoNuevoForm, promoEditar, promoVolverLista, promoToggleActiva, _promoForzarRefresh,',
`    loadPromociones, promoNuevoForm, promoEditar, promoVolverLista, promoToggleActiva, _promoForzarRefresh,
    // [666] centro de promociones unificado
    _pcCargarPromos, _pcCargarSugerencias, _pcIr, _pcTogglePasadas, _pcWhy, _pcOtrasIdeas,
    pcUsarJugada, promoDesdeSugerencia, promoDescartarSug, promoReactivar, promoEliminarDirecto,
    promoAbrirNueva, promoSetEstrategia, promoPintaEstrategias, promoVerJugadas,
    promoPresetVig, promoPresetHora, promoRecalcMargen, promoSugerirValor, promoPrefill,`, 'exports');

fs.writeFileSync(APP, s);

// ═══════════════ index.html ═══════════════
// A. muere la vista aparte
const vIni = h.indexOf('    <section id="view-promociones" class="view hidden">');
const vFin = h.indexOf('</section><!-- /view-promociones -->');
if (vIni < 0 || vFin < 0) throw new Error('no ubico view-promociones');
h = h.slice(0, vIni)
  + '    <!-- [666] La vista aparte de Promociones MURIÓ: todo vive en el overlay único 🎯\n'
  + '         (MOS.abrirPromoCentro). MOS.nav(\'promociones\') redirige allí. -->\n'
  + h.slice(vFin + '</section><!-- /view-promociones -->'.length + 1);

// B. paso cero (estrategia) + nota de sugerencia
h = R(h, '        <input type="hidden" id="promoIdEdit">',
`        <input type="hidden" id="promoIdEdit">

        <!-- [666] PASO CERO: ¿desde qué jugada del playbook la armamos? -->
        <div>
          <div class="text-xs font-bold text-slate-400 uppercase tracking-wider mb-2">Estrategia <span class="text-slate-600 normal-case font-normal">· elige una jugada o ve libre</span></div>
          <div id="promoEstrChip" class="mb-2"></div>
          <div id="promoEstrGrid" class="promo-estr-grid"></div>
        </div>
        <div id="promoSugNota" class="hidden" style="background:rgba(99,102,241,.08);border:1px solid rgba(99,102,241,.28);border-radius:10px;padding:9px 11px"></div>`, 'paso-cero');

// C. vigencia con presets + horario
h = R(h, `        <div class="grid grid-cols-2 gap-3">
          <div>
            <label class="lbl">Vigencia desde</label>
            <input id="promoFDesde" type="date" class="inp">
          </div>
          <div>
            <label class="lbl">Vigencia hasta</label>
            <input id="promoFHasta" type="date" class="inp">
          </div>
        </div>`,
`        <div>
          <label class="lbl">Vigencia</label>
          <div id="promoVigPresets" class="flex gap-1.5 text-xs mb-2 flex-wrap">
            <button type="button" class="promo-modo-btn" data-d="7"  onclick="MOS.promoPresetVig(7)">1 semana</button>
            <button type="button" class="promo-modo-btn" data-d="14" onclick="MOS.promoPresetVig(14)">2 semanas</button>
            <button type="button" class="promo-modo-btn active" data-d="30" onclick="MOS.promoPresetVig(30)">1 mes</button>
          </div>
          <div class="grid grid-cols-2 gap-3">
            <div><label class="lbl">Desde</label><input id="promoFDesde" type="date" class="inp"></div>
            <div><label class="lbl">Hasta</label><input id="promoFHasta" type="date" class="inp"></div>
          </div>
        </div>

        <!-- [666] ⏰ Horario (jugada "horas valle"): vacío = todo el día -->
        <div>
          <label class="lbl">⏰ Horario <span class="text-slate-600">· vacío = todo el día</span></label>
          <div id="promoHoraPresets" class="flex gap-1.5 text-xs mb-2 flex-wrap">
            <button type="button" class="promo-modo-btn active" data-h="todo"   onclick="MOS.promoPresetHora('todo')">Todo el día</button>
            <button type="button" class="promo-modo-btn" data-h="manana" onclick="MOS.promoPresetHora('manana')">Mañana 6-12</button>
            <button type="button" class="promo-modo-btn" data-h="tarde"  onclick="MOS.promoPresetHora('tarde')">Tarde 14-18</button>
            <button type="button" class="promo-modo-btn" data-h="custom" onclick="MOS.promoPresetHora('custom')">Personalizado</button>
          </div>
          <div id="promoHoraCustom" class="grid grid-cols-2 gap-3 hidden">
            <div><label class="lbl">Desde</label><input id="promoHDesde" type="time" class="inp"></div>
            <div><label class="lbl">Hasta</label><input id="promoHHasta" type="time" class="inp"></div>
          </div>
        </div>`, 'vigencia-horario');

// D. panel de margen en vivo
h = R(h, '        <div id="promoError" class="text-red-400 text-xs" style="display:none"></div>',
`        <!-- [666] margen en vivo: precio normal → promo → margen % y en S/ -->
        <div id="promoMargenBox"></div>

        <div id="promoError" class="text-red-400 text-xs" style="display:none"></div>`, 'margen-box');

// E. CSS
h = R(h, '    /* ── Quick chips para descripción de promo ──────────── */',
`    /* [666] ── Centro de Promociones unificado ─────────────── */
    .pc-chip { display:inline-block; border:1px solid; border-radius:99px; padding:1.5px 8px; font-size:9.5px; font-weight:700; line-height:1.5; white-space:nowrap; }
    .pc-card { background:#0d1526; border:1px solid #22314f; border-radius:12px; padding:11px 13px; margin-bottom:8px; transition:border-color .15s, transform .15s; }
    .pc-card:hover { border-color:#3b4d78; }
    .pc-card-name { font-size:12.5px; font-weight:700; color:#e2e8f0; line-height:1.35; }
    .pc-sug { background:linear-gradient(160deg,#101a30,#0d1526 60%); }
    .pc-mini { background:#16233c; border:1px solid #2c3f66; color:#cbd5e1; border-radius:8px; padding:5px 10px; font-size:10.5px; font-weight:700; cursor:pointer; transition:filter .15s, transform .1s; }
    .pc-mini:hover { filter:brightness(1.25); }
    .pc-mini:active { transform:scale(.96); }
    .pc-mini[disabled] { opacity:.45; cursor:default; }
    .pc-mini-ok { background:rgba(52,211,153,.14); border-color:rgba(52,211,153,.45); color:#6ee7b7; }
    .pc-mini-bad { background:rgba(248,113,113,.12); border-color:rgba(248,113,113,.4); color:#fca5a5; }
    .pc-btn-nueva { flex:1; background:linear-gradient(135deg,#a855f7,#ec4899); border:1px solid #c084fc; color:#fff; border-radius:10px; padding:9px 14px; font-size:12.5px; font-weight:800; cursor:pointer; transition:filter .15s, transform .1s; }
    .pc-btn-nueva:hover { filter:brightness(1.1); }
    .pc-btn-nueva:active { transform:scale(.985); }
    .pc-acc { width:100%; margin-top:10px; background:#0b1220; border:1px dashed #2c3f66; color:#94a3b8; border-radius:10px; padding:9px 12px; font-size:11.5px; font-weight:700; cursor:pointer; display:flex; justify-content:space-between; align-items:center; }
    .pc-acc:hover { border-color:#3b4d78; color:#cbd5e1; }
    .pc-empty { text-align:center; padding:28px 16px; background:#0b1220; border:1px dashed #22314f; border-radius:14px; }
    .pc-skel { height:96px; border-radius:12px; margin-bottom:8px; background:linear-gradient(100deg,#0d1526 30%,#16233c 50%,#0d1526 70%); background-size:220% 100%; animation:pcsk 1.2s linear infinite; }
    @keyframes pcsk { to { background-position:-220% 0; } }
    .pc-precio { display:flex; align-items:center; gap:10px; margin-top:9px; background:#0a1120; border:1px solid #1c2b48; border-radius:10px; padding:8px 11px; flex-wrap:wrap; }
    .pc-precio-lbl { font-size:9px; color:#64748b; text-transform:uppercase; letter-spacing:.04em; }
    .pc-precio-old { font-size:12px; color:#94a3b8; text-decoration:line-through; font-variant-numeric:tabular-nums; }
    .pc-precio-new { font-size:16px; font-weight:800; color:#e2e8f0; font-variant-numeric:tabular-nums; }
    .pc-why { margin-top:9px; background:#0a1120; border-left:3px solid #6366f1; border-radius:0 10px 10px 0; padding:9px 12px; font-size:11px; color:#a8b6d1; line-height:1.6; animation:pcwhy .18s ease-out; }
    @keyframes pcwhy { from { opacity:0; transform:translateY(-4px); } to { opacity:1; transform:none; } }
    .pc-play-ej { margin-top:6px; font-size:10.5px; color:#7c8db1; background:#0a1120; border-radius:8px; padding:6px 9px; line-height:1.5; }
    .pc-play-ej b { color:#c7d2fe; }
    .promo-estr-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); gap:7px; }
    .promo-estr { text-align:left; background:#0d1526; border:1px solid #22314f; border-radius:10px; padding:8px 10px; cursor:pointer; display:flex; flex-direction:column; gap:2px; transition:border-color .15s, background .15s; }
    .promo-estr:hover { border-color:#4c5f8f; }
    .promo-estr.on { border-color:#6366f1; background:rgba(99,102,241,.14); }
    .promo-estr .pe-ico { font-size:14px; }
    .promo-estr .pe-nom { font-size:11.5px; font-weight:800; color:#c7d2fe; }
    .promo-estr .pe-cua { font-size:9.5px; color:#7c8db1; line-height:1.4; }
    .promo-mg { margin-top:2px; background:#0a1120; border:1px solid #1c2b48; border-radius:10px; padding:9px 11px; }
    .promo-mg.bad { border-color:rgba(248,113,113,.5); background:rgba(248,113,113,.06); }
    @media (max-width:430px) {
      .pc-precio-new { font-size:15px; }
      .promo-estr-grid { grid-template-columns:1fr 1fr; }
      .pc-mini { padding:7px 10px; }
    }

    /* ── Quick chips para descripción de promo ──────────── */`, 'css');

fs.writeFileSync(IDX, h);
console.log('app.js  ', n0, '->', s.length);
console.log('index   ', m0, '->', h.length);
console.log('APLICADO ✓');
