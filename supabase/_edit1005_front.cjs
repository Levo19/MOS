// Ediciones front [1005-UX]: dock XL + badge Log + boton Compras en Almacen. Strings exactos + assert unicidad.
const fs = require('fs'); const path = require('path');
const ROOT = path.join(__dirname, '..');
function apply(file, pairs) {
  const fp = path.join(ROOT, file);
  let s = fs.readFileSync(fp, 'utf8'); let n = 0;
  for (const [oldS, newS] of pairs) {
    const c = s.split(oldS).length - 1;
    if (c !== 1) { console.error(`FAIL ${file}: "${oldS.slice(0, 70)}..." aparece ${c} veces (esperaba 1)`); process.exit(1); }
    s = s.replace(oldS, newS); n++;
  }
  fs.writeFileSync(fp, s);
  console.log(`OK ${file}: ${n} ediciones`);
}
const IC = (ic, lbl) => `<span class="zbs-ic">${ic}</span><span class="zbs-lbl">${lbl}</span>`;

apply('index.html', [
  // ── dock: icono arriba + etiqueta abajo (XL) ──
  [`title="Pickup acumulado de la zona + historial por día (en vivo)">🛒 Pickup</button>`,
   `title="Pickup acumulado de la zona + historial por día (en vivo)">${IC('🛒','Pickup')}</button>`],
  [`+ descargar Excel/XML/PDF">📒 Kardex</button>`,
   `+ descargar Excel/XML/PDF">${IC('📒','Kardex')}</button>`],
  [`decide si se manda o se descarta">🎯 Considerados<span id="zonaConsidBadge"`,
   `decide si se manda o se descarta">${IC('🎯','Considerados')}<span id="zonaConsidBadge"`],
  [`title="Guías de traslado por verificar / verificadas">🚚 Guías<span id="zonaGuiasBadge"`,
   `title="Guías de traslado por verificar / verificadas">${IC('🚚','Guías')}<span id="zonaGuiasBadge"`],
  [`title="Guías de las zonas (zona1 / zona2) en pestañas">🚚 Guías por zona</button>`,
   `title="Guías de las zonas (zona1 / zona2) en pestañas">${IC('🚚','Guías por zona')}</button>`],
  [`title="Abrir el módulo Almacén (stock, operaciones, mermas, vencimientos)">🏠 Abrir Almacén</button>`,
   `title="Abrir el módulo Almacén (stock, operaciones, mermas, vencimientos)">${IC('🏠','Abrir Almacén')}</button>`],
  [`(Almacén y Zonas ven reglas distintas)">💡 Insights</button>`,
   `(Almacén y Zonas ven reglas distintas)">${IC('💡','Insights')}</button>`],
  [`su pago del día y su envasado/ventas">🫡 Personal del día</button>`,
   `su pago del día y su envasado/ventas">${IC('🫡','Personal del día')}</button>`],
  [`prueba de escaneo real (solo admins)">🎯 Sorpresas</button>`,
   `prueba de escaneo real (solo admins)">${IC('🎯','Sorpresas')}</button>`],
  [`title="Tratamiento de mermas: cesta, SLA y auditoría">♻️ Mermas<span id="zonaMermasBadge"`,
   `title="Tratamiento de mermas: cesta, SLA y auditoría">${IC('♻️','Mermas')}<span id="zonaMermasBadge"`],
  [`zona = libro de la zona)">📅 Por vencer<span id="zonaVencBadge"`,
   `zona = libro de la zona)">${IC('📅','Por vencer')}<span id="zonaVencBadge"`],
  // ── Log de errores: clase badge-able + badge avisador ──
  [`<button id="zonaBtnLogErrores" class="zona-btn-sec hidden" style="border-color:#7f1d1d;color:#fca5a5" onclick="MOS.zonaAbrirLogErrores()" title="Diferencias de stock detectadas (real vs teórico)">⚠ Log de errores</button>`,
   `<button id="zonaBtnLogErrores" class="zona-btn-sec zona-guias-btn hidden" style="border-color:#7f1d1d;color:#fca5a5" onclick="MOS.zonaAbrirLogErrores()" title="Diferencias de stock detectadas (real vs teórico)">${IC('⚠','Log de errores')}<span id="zonaLogBadge" class="zona-guias-badge" style="display:none">0</span></button>`],
  // ── NUEVO: 🧾 Compras (mesa de compras) en el dock del Almacén — solo admins ──
  [`<button id="zonaBtnGuiasAlm" class="zona-btn-sec zona-guias-btn hidden" onclick="MOS.zonaAbrirGuiasAlmacen()" title="Guías de las zonas (zona1 / zona2) en pestañas">`,
   `<button id="zonaBtnCompras" class="zona-btn-sec zona-guias-btn hidden" style="border-color:rgba(52,211,153,.5);color:#6ee7b7" onclick="MOS.abrirMesaCompras()" title="Procesar compras: costos → precios de cada guía de proveedor">${IC('🧾','Compras')}<span class="bmc-n zona-guias-badge" style="display:none">0</span></button>
              <button id="zonaBtnGuiasAlm" class="zona-btn-sec zona-guias-btn hidden" onclick="MOS.zonaAbrirGuiasAlmacen()" title="Guías de las zonas (zona1 / zona2) en pestañas">`],
  // ── CSS dock XL + badge nunca recortado ──
  [`    .zhb-gbtns .zona-btn-sec:active { transform:translateY(0) scale(.97); }`,
   `    .zhb-gbtns .zona-btn-sec:active { transform:translateY(0) scale(.97); }
    /* [1005-UX] Dock XL: botones grandes (icono arriba + etiqueta), háptico visual; badge JAMÁS recortado
       (el overflow:hidden base del .zona-btn-sec cortaba el círculo rojo → aquí overflow:visible + z-index). */
    .zhb-gbtns .zona-btn-sec { overflow:visible; display:inline-flex; flex-direction:column; align-items:center; justify-content:center; gap:.24rem;
      min-height:62px; min-width:84px; padding:.55rem .85rem .5rem; border-radius:.85rem; }
    .zhb-gbtns .zona-btn-sec .zbs-ic { font-size:1.45rem; line-height:1; filter:drop-shadow(0 2px 6px rgba(0,0,0,.45)); transition:transform .18s; }
    .zhb-gbtns .zona-btn-sec:hover .zbs-ic { transform:scale(1.12) translateY(-1px); }
    .zhb-gbtns .zona-btn-sec:active .zbs-ic { transform:scale(.9); }
    .zhb-gbtns .zona-btn-sec .zbs-lbl { font-size:.67rem; font-weight:800; letter-spacing:.01em; line-height:1.05; white-space:nowrap; }
    .zhb-gbtns .zona-guias-badge { top:-7px; right:-7px; min-width:20px; height:20px; line-height:20px; font-size:11px; border-radius:10px; z-index:5; }`],
]);

apply('js/api.js', [
  [`  async function _zonaDiferencias(params)       { const r = await _sbRpcMOS('stock_diferencias_listar', { p: _zonaParams(params || {}) }, 'mos'); return r; }`,
   `  async function _zonaDiferencias(params)       { const r = await _sbRpcMOS('stock_diferencias_listar', { p: _zonaParams(params || {}) }, 'mos'); return r; }
  async function _zonaDiferenciasResumen()      { const r = await _sbRpcMOS('stock_diferencias_resumen', { p: {} }, 'mos'); return r; }`],
  [`      diferencias:     _zonaDiferencias,`,
   `      diferencias:     _zonaDiferencias,
      diferenciasResumen: _zonaDiferenciasResumen, // mos.stock_diferencias_resumen → {ok,data:{sis,ope,cfg,total}} (badge avisador)`],
]);

apply('js/app.js', [
  // toggle visibilidad + refrescos
  [`    if (bv) bv.classList.remove('hidden');
    if (bs) bs.classList.toggle('hidden', !esAlm || !_esAdminSesion());
    if (esAlm) _mermasBadgeRefrescar();
    _vencBadgeRefrescar(esAlm ? null : S.zonaActual);`,
   `    if (bv) bv.classList.remove('hidden');
    if (bs) bs.classList.toggle('hidden', !esAlm || !_esAdminSesion());
    // [1005-UX] 🧾 Compras (mesa de compras del catálogo) también en el dock del puesto Almacén — solo admins.
    const bco = $('zonaBtnCompras');
    if (bco) bco.classList.toggle('hidden', !esAlm || !_esAdminSesion());
    if (bco && esAlm) { try { _mesaComprasSyncBadge(); } catch (_) {} }
    if (esAlm) _mermasBadgeRefrescar();
    _vencBadgeRefrescar(esAlm ? null : S.zonaActual);
    _logBadgeRefrescar();`],
  // avisador: badge del Log de errores
  [`  // ── ♻️ MERMAS · panel auditoría (historial completo alcance=mos) ──`,
   `  // [1005-UX · AVISADOR] Badge rojo del "⚠ Log de errores" = diferencias SISTÉMICAS abiertas (tipos 1/2/3:
  //   stock congelado / kardex inconsistente / salida sin descuento). Son las que persigue el master y no deben
  //   reincidir → si el número sube, algo volvió a fallar en el código. RPC barata (solo cuenta, SQL 1005-B).
  async function _logBadgeRefrescar() {
    try {
      const esMaster = (S.session && (S.session.rol || '').toLowerCase() === 'master');
      const b = $('zonaLogBadge');
      if (!b || !esMaster) { if (b) b.style.display = 'none'; return; }
      const r = await API.zona.diferenciasResumen();
      const n = (r && r.ok && r.data && (r.data.sis | 0)) || 0;
      b.textContent = String(n); b.style.display = n > 0 ? '' : 'none';
    } catch (_) {}
  }

  // ── ♻️ MERMAS · panel auditoría (historial completo alcance=mos) ──`],
  // haptico del dock (delegado unico, no rompe onclicks)
  [`    cont.addEventListener('pointerdown', (ev) => {
      try {
        const t = ev.target && ev.target.closest('.zona-btn-pedir,.zona-btn-sec,.zona-card');
        if (t && !t.disabled) _zonaRipple(ev, t);
      } catch (_) {}
    }, { passive: true });
  }`,
   `    cont.addEventListener('pointerdown', (ev) => {
      try {
        const t = ev.target && ev.target.closest('.zona-btn-pedir,.zona-btn-sec,.zona-card');
        if (t && !t.disabled) _zonaRipple(ev, t);
      } catch (_) {}
    }, { passive: true });
    // [1005-UX] Dock háptico: pop + vibración corta al presionar cualquier botón del dock (delegado único).
    const dock = document.querySelector('.zhb-groups');
    if (dock && !dock._hapticOn) {
      dock._hapticOn = true;
      dock.addEventListener('pointerdown', (ev) => {
        try {
          const t = ev.target && ev.target.closest('.zona-btn-sec');
          if (t && !t.disabled) { _zonaSfx('pop'); _zonaVibrar([14]); }
        } catch (_) {}
      }, { passive: true });
    }
  }`],
  // abrir mesa de compras: sfx + vibracion
  [`  function abrirMesaCompras(filtro) {
    _opsInyectarKeyframes();
    _mesaComprasInyectarCSS();`,
   `  function abrirMesaCompras(filtro) {
    _opsInyectarKeyframes();
    _mesaComprasInyectarCSS();
    try { _zonaSfx('pop'); _zonaVibrar([20, 12, 20]); } catch (_) {}`],
  // badge de compras: tambien el boton del dock
  [`      document.querySelectorAll('.btn-mesa-compras .bmc-n').forEach(el => {`,
   `      document.querySelectorAll('.btn-mesa-compras .bmc-n, #zonaBtnCompras .bmc-n').forEach(el => {`],
]);

console.log('TODAS las ediciones aplicadas.');
