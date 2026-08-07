// [695-B] Centro de Promociones (overlay analítico + playbook) + botón de la toolbar.
import fs from 'fs';
let s = fs.readFileSync('../js/app.js', 'utf8');
const R = (a, b) => { const i = s.indexOf(a); if (i < 0) throw new Error('NO: ' + a.slice(0, 60)); if (s.indexOf(a, i + 1) >= 0) throw new Error('DUP: ' + a.slice(0, 60)); s = s.slice(0, i) + b + s.slice(i + a.length); };

const BLOQUE = `  // [695] rotación semanal (misma fuente que el chip del card: series de S.rotacion)
  function _promoRotSem(p) {
    try {
      const prods = (S.rotacion && S.rotacion.productos) || {};
      const serie = prods[String(p.codigoBarra || '').trim()] || [];
      if (!serie.length) return 0;
      let totU = 0, totKg = 0;
      serie.forEach(x => { totU += parseFloat(x.unidades) || 0; totKg += parseFloat(x.kg) || 0; });
      const esPeso = !!_UMS_PESO[String(p.unidad || p.Unidad_Medida || '').trim().toUpperCase()];
      return (esPeso && totKg > 0 ? totKg : totU) / (serie.length || 8);
    } catch (_) { return 0; }
  }
  // [695] CENTRO DE PROMOCIONES: radar con datos reales + playbook. El módulo GAS de
  // promociones queda como "módulo completo" (migrarlo a SB es paso aparte).
  async function abrirPromoCentro() {
    try { _opsBeep && _opsBeep('tac'); } catch(_){}
    try { navigator.vibrate && navigator.vibrate(10); } catch(_){}
    $('promoCentro')?.remove();
    const div = document.createElement('div');
    div.id = 'promoCentro'; div.className = 'modal-backdrop open';
    div.innerHTML = \`<div class="modal-box" style="max-width:720px;max-height:90vh;display:flex;flex-direction:column;border:1px solid rgba(99,102,241,.5);box-shadow:0 30px 80px -15px rgba(99,102,241,.4)">
      <div class="px-5 py-4 flex items-center gap-3" style="border-bottom:1px solid #1e293b;background:linear-gradient(120deg,rgba(67,56,202,.35),rgba(139,92,246,.12) 60%,transparent)">
        <span style="font-size:24px">🎯</span>
        <div class="flex-1 min-w-0">
          <h2 class="font-bold text-base text-white">Centro de Promociones</h2>
          <div style="font-size:10.5px;color:#a5b4fc">Radar de candidatos con tus datos reales + playbook del negocio</div>
        </div>
        <button onclick="document.getElementById('promoCentro').remove()" class="modal-close-x">×</button>
      </div>
      <div class="px-4 pt-3" style="display:flex;gap:6px;flex-wrap:wrap" id="pcTabs"></div>
      <div id="pcBody" class="p-4 overflow-y-auto flex-1"><div style="text-align:center;color:#64748b;padding:30px 0"><span class="inline-block animate-spin">⏳</span> Analizando catálogo…</div></div>
      <div class="px-5 py-3 flex items-center gap-3" style="border-top:1px solid #1e293b">
        <span style="font-size:10.5px;color:#64748b;flex:1">Las promos se crean en el módulo actual — este radar te dice CUÁLES conviene</span>
        <button onclick="document.getElementById('promoCentro').remove();MOS.nav('promociones')" style="background:rgba(99,102,241,.15);border:1px solid rgba(99,102,241,.45);color:#a5b4fc;border-radius:8px;padding:6px 14px;font-size:11.5px;font-weight:700;cursor:pointer">Abrir módulo de promociones →</button>
      </div>
    </div>\`;
    div.addEventListener('click', e => { if (e.target === div) div.remove(); });
    document.body.appendChild(div);

    let stockMap = null;
    try {
      const r = await API.get('getCatalogoStockResumen', { dias: 7 });
      const items = (r && r.productos) || (Array.isArray(r) ? r : []);
      if (items && items.length) {
        stockMap = {};
        items.forEach(it => {
          const cod = String(it.codigoBarra || it.codigo || it.cod || '').trim();
          const st = parseFloat(it.stock != null ? it.stock : (it.stockActual != null ? it.stockActual : it.cantidad));
          if (cod && !isNaN(st)) stockMap[cod] = st;
        });
      }
    } catch (_) {}

    const base = (S.productos || []).filter(p => {
      const esPres = !p.codigoProductoBase && parseFloat(p.factorConversion) > 1;
      return String(p.estado) === '1' && !esPres && String(p.esInsumo) !== '1' && (parseFloat(p.precioVenta) || 0) > 0;
    }).map(p => {
      const pv = parseFloat(p.precioVenta) || 0, pc = parseFloat(p.precioCosto) || 0;
      const rot = _promoRotSem(p);
      const stock = stockMap ? stockMap[String(p.codigoBarra || '').trim()] : null;
      const margen = (pv > 0 && pc > 0) ? ((pv - pc) / pv) * 100 : null;
      const mesesInv = (stock != null && rot > 0) ? (stock / (rot * 4.33)) : null;
      return { p, pv, pc, rot, stock, margen, mesesInv };
    });

    const chip = (txt, color) => \`<span style="background:\${color}22;color:\${color};border:1px solid \${color}44;border-radius:99px;padding:1px 8px;font-weight:700">\${txt}</span>\`;
    const fmtRow = (x, extraChips) => {
      const cia = (x.p.categoriaIa && typeof x.p.categoriaIa === 'object') ? x.p.categoriaIa : null;
      const hu = _taxHue(cia ? cia.categoria : (x.p.idCategoria || ''));
      const descMax = x.margen != null ? Math.max(0, Math.floor(x.margen - 12)) : null;
      const tip = (descMax != null && descMax >= 5)
        ? \`2ª unidad hasta <b>-\${Math.min(descMax, 50)}%</b> sin bajar de 12% de margen\`
        : 'combínalo de gancho junto a un producto estrella de su subcategoría';
      return \`<div style="display:flex;gap:10px;align-items:center;background:#0d1526;border:1px solid #22314f;border-left:3px solid hsl(\${hu} 65% 55% / .8);border-radius:11px;padding:9px 12px;margin-bottom:7px">
        <div style="flex:1;min-width:0">
          <div style="font-size:12.5px;font-weight:700;color:#e2e8f0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">\${_TAX_EMOJI[cia ? cia.categoria : ''] || '🏷️'} \${_escapeHtml(x.p.descripcion || '')}</div>
          <div style="display:flex;gap:5px;flex-wrap:wrap;margin-top:4px;font-size:9.5px">\${extraChips(x)}</div>
          <div style="font-size:10px;color:#7c8db1;margin-top:4px">💡 \${tip}</div>
        </div>
        <div style="text-align:right;flex:none">
          <div style="font-size:13px;font-weight:800;color:#e2e8f0" class="tnum">S/ \${x.pv.toFixed(2)}</div>
          \${x.margen != null ? \`<div style="font-size:9.5px;color:\${x.margen >= 30 ? '#34d399' : '#94a3b8'}" class="tnum">mg \${x.margen.toFixed(0)}%</div>\` : ''}
        </div>
      </div>\`;
    };

    const TABS = {
      lentos: { lbl: '🐌 Baja rotación', arma: () => {
        const l = base.filter(x => x.rot <= 0.5).sort((a, b) => (b.margen || 0) - (a.margen || 0)).slice(0, 25);
        return { intro: 'Casi no rotan (≤0.5/sem en 8 semanas). Cada semana en estante es capital dormido — mejor un descuento que un producto eterno.',
          html: l.map(x => fmtRow(x, y => chip(y.rot > 0 ? y.rot.toFixed(1) + '/sem' : 'sin mov.', '#f87171') + (y.stock != null ? chip('stock ' + y.stock, '#94a3b8') : ''))).join('') || '<div style="color:#64748b;text-align:center;padding:20px 0">Nada lento — catálogo sano 🎉</div>' };
      }},
      margen: { lbl: '💎 Margen alto y lento', arma: () => {
        const l = base.filter(x => (x.margen || 0) >= 30 && x.rot < 1).sort((a, b) => b.margen - a.margen).slice(0, 25);
        return { intro: 'Margen ≥30% pero rotación <1/sem: hay ESPACIO para descuento agresivo sin perder plata — los candidatos más rentables a promo.',
          html: l.map(x => fmtRow(x, y => chip('mg ' + y.margen.toFixed(0) + '%', '#34d399') + chip(y.rot > 0 ? y.rot.toFixed(1) + '/sem' : 'sin mov.', '#f87171'))).join('') || '<div style="color:#64748b;text-align:center;padding:20px 0">Sin candidatos ahora</div>' };
      }},
      stockAlto: { lbl: '📦 Sobre-stock', arma: () => {
        if (!stockMap) return { intro: '', html: '<div style="color:#64748b;text-align:center;padding:20px 0">No pude leer el stock de WH ahora — reintenta en un momento</div>' };
        const l = base.filter(x => x.mesesInv != null && x.mesesInv >= 3 && x.stock > 0).sort((a, b) => b.mesesInv - a.mesesInv).slice(0, 25);
        return { intro: 'Al ritmo de venta actual este stock dura ≥3 MESES. Antes de que se vuelva merma: pack familiar, 2×, o descuento por volumen.',
          html: l.map(x => fmtRow(x, y => chip((y.mesesInv >= 12 ? '+12' : y.mesesInv.toFixed(1)) + ' meses de stock', '#f59e0b') + chip('stock ' + y.stock, '#94a3b8') + chip((y.rot || 0).toFixed(1) + '/sem', '#7c8db1'))).join('') || '<div style="color:#64748b;text-align:center;padding:20px 0">Sin sobre-stock detectable 🎉</div>' };
      }},
      vencer: { lbl: '⏳ Por vencer', arma: () => ({ intro: '',
        html: \`<div style="background:#101a2e;border:1px dashed #f59e0b66;border-radius:12px;padding:16px;color:#b6c2dd;font-size:12px;line-height:1.6">
          <b style="color:#fcd34d">Tu regla, lista para automatizarse:</b><br>
          · A <b>4 meses</b> del vencimiento → entra a promoción (con 1 mes de empuje basta).<br>
          · A <b>3 meses</b> → REMATE sí o sí (la meta es no llegar nunca a ese extremo).<br><br>
          ⚠ Aún no capturamos <b>fecha de vencimiento por lote</b> en las guías de ingreso de WH.
          Cuando la capturemos, esta pestaña se llena SOLA con lo que entra a zona amarilla/roja.
          Pídemelo y lo conecto.
        </div>\` }) },
      playbook: { lbl: '📚 Playbook', arma: () => ({ intro: '',
        html: [
          ['🐌→⭐ Ancla con el líder', 'El lento se promociona JUNTO al más vendido de su subcategoría (la taxonomía te lo da): "lleva X y el Y a -30%". El estrella arrastra.'],
          ['🔁 Cruce con sustitutos', 'Ya mapeamos sustitutos internos: cuando piden algo sin stock, ofrecer el sustituto CON un descuento pequeño convierte el "no hay" en venta.'],
          ['2️⃣ 2ª unidad al %', 'Mejor que bajar el precio de lista: protege el margen de la 1ª unidad y sube el ticket. Ideal para sobre-stock.'],
          ['🧺 Pack familiar', 'Sobre-stock grande → pack de 3-6 con precio de etiqueta único (como el saco de Nakamito). Mueve volumen sin re-etiquetar unidad por unidad.'],
          ['⏰ Horas valle', 'Promos que solo viven en horarios muertos de ME/MosGo — mueven inventario sin canibalizar la venta fuerte.'],
          ['🎉 Estacionalidad', 'Repostería/decorativos pican en fiestas: promociona el sobre-stock ANTES de la temporada, no después.'],
          ['🛡 Jamás el top-seller', 'El que rota solo no se descuenta: pierde margen sin ganar clientes. El descuento es medicina para lentos.'],
          ['🏷 Precio psicológico', 'Remates en .90/.50 — y el cartel dice el % ("-40%"), no solo el precio: el cerebro compra el descuento.'],
          ['📉 Escalera de remate', 'Si en 2 semanas no movió: sube el descuento un escalón (20→30→40%). El peor descuento es la merma al 100%.']
        ].map(([t, d]) => \`<div style="background:#0d1526;border:1px solid #22314f;border-radius:11px;padding:10px 13px;margin-bottom:7px"><div style="font-size:12px;font-weight:800;color:#c7d2fe">\${t}</div><div style="font-size:11px;color:#94a3b8;margin-top:3px;line-height:1.5">\${d}</div></div>\`).join('') }) }
    };
    let cur = 'lentos';
    const pinta = () => {
      const tabs = $('pcTabs'), body = $('pcBody');
      if (!tabs || !body) return;
      tabs.innerHTML = Object.entries(TABS).map(([k, t]) =>
        \`<button data-tab="\${k}" style="background:\${cur === k ? 'rgba(99,102,241,.25)' : '#0d1526'};border:1px solid \${cur === k ? '#6366f1' : '#22314f'};color:\${cur === k ? '#c7d2fe' : '#94a3b8'};border-radius:99px;padding:5px 13px;font-size:11px;font-weight:700;cursor:pointer">\${t.lbl}</button>\`).join('');
      tabs.querySelectorAll('button').forEach(b => b.addEventListener('click', () => { cur = b.dataset.tab; try { navigator.vibrate && navigator.vibrate(6); } catch(_){} pinta(); }));
      const r = TABS[cur].arma();
      body.innerHTML = (r.intro ? \`<div style="font-size:11px;color:#7c8db1;margin-bottom:10px;line-height:1.5">\${r.intro}</div>\` : '') + r.html;
    };
    pinta();
  }

  function _fpPill(on, hu) {`;

R('  function _fpPill(on, hu) {', BLOQUE);
R('    togglePNBanner, abrirPNDesdeToolbar, fpAbrir, openImagePreview, closeImagePreview,',
  '    togglePNBanner, abrirPNDesdeToolbar, fpAbrir, abrirPromoCentro, openImagePreview, closeImagePreview,');
fs.writeFileSync('../js/app.js', s);

let h = fs.readFileSync('../index.html', 'utf8');
h = h.replace(`<button class="ct2-btn" onclick="MOS.nav('promociones')" title="Gestionar promociones">`,
              `<button class="ct2-btn" onclick="MOS.abrirPromoCentro()" title="Centro de promociones: radar de candidatos + playbook">`);
fs.writeFileSync('../index.html', h);
console.log('promo centro ok · botón:', h.includes('MOS.abrirPromoCentro()'));
