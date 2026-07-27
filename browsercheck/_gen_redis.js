const fs = require('fs');
const { chromium } = require('playwright');
const { pathToFileURL } = require('url');

// datos reales Jorgenis (lun 20 -> dom 26)
const dias = [
  { d: 'lun 20', aud: 0, base: 80, env: 0,     envC: 0, meta: 0, bono: 0, san: 0, cons: 9.60,  colab: '' },
  { d: 'mar 21', aud: 0, base: 80, env: 0,     envC: 0, meta: 0, bono: 0, san: 0, cons: 1.00,  colab: '' },
  { d: 'mié 22', aud: 1, base: 80, env: 19.90, envC: 1, meta: 0, bono: 0, san: 0, cons: 4.00,  colab: 'Luis' },
  { d: 'jue 23', aud: 0, base: 80, env: 0,     envC: 0, meta: 0, bono: 0, san: 0, cons: 0,     colab: '' },
  { d: 'vie 24', aud: 1, base: 80, env: 6.15,  envC: 1, meta: 0, bono: 0, san: 0, cons: 6.80,  colab: 'Luis' },
  { d: 'sáb 25', aud: 0, base: 80, env: 0,     envC: 0, meta: 0, bono: 0, san: 0, cons: 21.40, colab: '' },
  { d: 'dom 26', aud: 0, base: 80, env: 0,     envC: 0, meta: 0, bono: 0, san: 0, cons: 0,     colab: '' },
];
const m = n => 'S/' + n.toFixed(2);
const tot = d => d.base + d.env + d.meta + d.bono - d.san;
const neto = d => Math.round((tot(d) - d.cons) * 100) / 100;
const chip = (t, c, b, ti) => '<span ' + (ti ? 'title="' + ti + '"' : '') + ' style="display:inline-block;padding:2px 7px;border-radius:6px;font-size:10px;font-weight:600;color:' + c + ';background:' + b + ';white-space:nowrap">' + t + '</span>';

const dayCard = (d, sel) => {
  const ing = [chip('jornal ' + d.base.toFixed(2), '#93c5fd', 'rgba(59,130,246,.12)')];
  if (d.env > 0) ing.push(chip('+envasar ' + d.env.toFixed(2) + (d.envC ? ' 🤝' : ''), '#c4b5fd', 'rgba(139,92,246,.14)', d.colab ? 'compartido con ' + d.colab : ''));
  if (d.meta > 0) ing.push(chip('+meta ' + d.meta.toFixed(2), '#6ee7b7', 'rgba(16,185,129,.14)'));
  if (d.bono > 0) ing.push(chip('+bono ' + d.bono.toFixed(2), '#6ee7b7', 'rgba(16,185,129,.14)'));
  const des = [];
  if (d.san > 0) des.push(chip('−sanción ' + d.san.toFixed(2), '#fca5a5', 'rgba(239,68,68,.14)'));
  if (d.cons > 0) des.push(chip('−consumo ' + d.cons.toFixed(2) + ' 🤖', '#fcd34d', 'rgba(245,158,11,.14)'));
  const right = des.length
    ? '<div style="font-size:14px;font-weight:800;color:#34d399">' + m(neto(d)) + '</div><div style="font-size:9px;color:#64748b">de ' + m(tot(d)) + '</div>'
    : '<div style="font-size:14px;font-weight:800;color:#fbbf24">' + m(tot(d)) + '</div>';
  return '<div style="display:flex;align-items:center;gap:10px;padding:11px 12px;border-radius:10px;background:' + (sel ? 'rgba(52,211,153,.06)' : '#0a1220') + ';border:1px solid ' + (sel ? 'rgba(52,211,153,.35)' : '#1a2436') + ';margin-bottom:7px">'
    + '<div style="width:20px;height:20px;border-radius:6px;border:2px solid ' + (sel ? '#34d399' : '#475569') + ';background:' + (sel ? '#34d399' : 'transparent') + ';flex-shrink:0;display:flex;align-items:center;justify-content:center;color:#04121a;font-weight:900;font-size:12px">' + (sel ? '✓' : '') + '</div>'
    + '<div style="flex:1;min-width:0"><div style="display:flex;align-items:center;gap:7px"><span style="font-size:12.5px;font-weight:600;color:#e2e8f0;text-transform:capitalize">' + d.d + ' jul</span>'
    + (d.aud ? '<span style="font-size:9px;color:#34d399">✓ auditado</span>' : '<span style="font-size:9px;color:#fbbf24">⚠ sin auditar</span>') + '</div>'
    + '<div style="margin-top:5px;display:flex;flex-wrap:wrap;gap:4px">' + ing.concat(des).join('') + '</div></div>'
    + '<div style="text-align:right;flex-shrink:0">' + right + '</div>'
    + '<div style="display:flex;flex-direction:column;gap:4px;flex-shrink:0">'
    + '<button title="Auditar: registrar bonos/descuentos y ver progreso" style="font-size:10px;padding:4px 7px;border-radius:6px;background:rgba(99,102,241,.14);color:#a5b4fc;border:1px solid rgba(99,102,241,.35);font-weight:600">📋 Auditar</button>'
    + '<button title="Vetar: marcar este día NO pagable (reversible)" style="font-size:10px;padding:4px 7px;border-radius:6px;background:rgba(239,68,68,.1);color:#fca5a5;border:1px solid rgba(239,68,68,.3);font-weight:600">🚫 Vetar</button></div></div>';
};

const brutoSel = dias.reduce((a, d) => a + tot(d), 0);
const consSel = dias.reduce((a, d) => a + d.cons, 0);
const netoSel = Math.round((brutoSel - consSel) * 100) / 100;

const tabs = ['📋 Pendientes', '💰 Pagadas', '📊 Resumen'].map((t, i) => '<span style="font-size:12px;padding:7px 14px;border-radius:10px;background:' + (i == 0 ? '#1e3a5f' : '#0b1220') + ';color:' + (i == 0 ? '#fff' : '#64748b') + ';border:1px solid ' + (i == 0 ? '#2f7fed' : '#1a2436') + ';font-weight:600">' + t + '</span>').join('');
const filtros = ['Hoy', 'Semana', '15 días', '30 días', 'Mes'].map((t, i) => '<span style="font-size:11px;padding:5px 11px;border-radius:8px;background:' + (i == 1 ? 'rgba(47,127,237,.15)' : '#0b1220') + ';color:' + (i == 1 ? '#93c5fd' : '#64748b') + ';border:1px solid ' + (i == 1 ? 'rgba(47,127,237,.4)' : '#1a2436') + '">' + t + '</span>').join('');

const vista = '<div style="width:560px">'
  + '<div style="display:flex;gap:6px;margin-bottom:12px">' + tabs + '</div>'
  + '<div style="display:flex;gap:6px;margin-bottom:14px;flex-wrap:wrap">' + filtros + '</div>'
  + '<div style="background:#0b1220;border:1px solid #1a2436;border-radius:16px;padding:16px">'
  + '<div style="display:flex;align-items:center;gap:12px;margin-bottom:12px">'
  + '<div style="width:44px;height:44px;border-radius:12px;background:linear-gradient(135deg,#1e3a5f,#2f7fed);display:flex;align-items:center;justify-content:center;font-size:22px">🏭</div>'
  + '<div style="flex:1"><div style="font-size:15px;font-weight:700;color:#f1f5f9">Jorgenis González <span style="font-size:10px;color:#64748b;font-weight:500">· ALMACENERO</span></div>'
  + '<div style="font-size:11px;color:#64748b;margin-top:2px">7 días sin pagar · <b style="color:#34d399">7 seleccionados</b></div></div>'
  + '<div style="text-align:right"><div style="font-size:9px;text-transform:uppercase;letter-spacing:1px;color:#64748b;font-weight:700">Neto</div>'
  + '<div style="font-size:19px;font-weight:900;color:#34d399">' + m(netoSel) + '</div>'
  + '<div style="font-size:10px;color:#fbbf24">−' + m(consSel) + ' consumo · de ' + m(brutoSel) + '</div></div></div>'
  + '<label style="display:flex;align-items:center;gap:8px;font-size:11.5px;color:#94a3b8;margin-bottom:10px;padding-bottom:10px;border-bottom:1px solid #1a2436"><input type=checkbox checked style="width:15px;height:15px"> Marcar todos los días (7)</label>'
  + dias.map(d => dayCard(d, true)).join('')
  + '</div>'
  + '<div style="margin-top:14px;background:linear-gradient(135deg,#0f2a1e,#0b1220);border:1px solid rgba(52,211,153,.3);border-radius:14px;padding:14px 16px;display:flex;align-items:center;justify-content:space-between">'
  + '<div><div style="font-size:10px;text-transform:uppercase;letter-spacing:1px;color:#64748b;font-weight:700">💵 Seleccionado · 7 días</div>'
  + '<div style="font-size:22px;font-weight:900;color:#34d399">' + m(netoSel) + '</div></div>'
  + '<button style="padding:14px 24px;border-radius:12px;background:#10b981;color:#fff;font-weight:800;font-size:15px;border:none">💸 Pagar →</button></div></div>';

// preview imagen
const rowsPrev = dias.map(d => {
  const parts = ['base ' + d.base];
  if (d.env > 0) parts.push('env ' + d.env + (d.envC ? '🤝' : ''));
  const desc = d.cons > 0 ? ' · <span style="color:#d97706">cons −' + d.cons + '</span>' : '';
  return '<div style="display:flex;justify-content:space-between;font-size:11px;padding:5px 0;border-bottom:1px dashed rgba(0,0,0,.08)"><div><b style="color:#1e293b">' + d.d + '</b> <span style="color:#64748b">' + parts.join(' · ') + '</span>' + desc + '</div><b style="color:#0f766e">' + m(neto(d)) + '</b></div>';
}).join('');
const preview = '<div style="width:400px;background:linear-gradient(160deg,#ffffff,#f0fdf9);border-radius:18px;padding:22px;box-shadow:0 10px 40px rgba(0,0,0,.5);color:#1e293b">'
  + '<div style="text-align:center;border-bottom:2px solid #0f766e;padding-bottom:12px;margin-bottom:12px"><div style="font-size:18px;font-weight:900;color:#0f766e;letter-spacing:.5px">INVERSIONES MOS</div><div style="font-size:11px;color:#64748b;font-weight:600">Comprobante de liquidación</div></div>'
  + '<div style="display:flex;justify-content:space-between;font-size:12px;margin-bottom:12px"><div><div style="font-weight:800;font-size:14px">Jorgenis González</div><div style="color:#64748b">Almacenero</div></div><div style="text-align:right"><div style="color:#64748b">20 – 26 jul 2026</div><div style="font-weight:700">7 días</div></div></div>'
  + '<div style="font-size:9px;text-transform:uppercase;letter-spacing:1px;color:#94a3b8;font-weight:800;margin-bottom:4px">Detalle por día</div>' + rowsPrev
  + '<div style="margin-top:12px;padding-top:10px;border-top:1px solid #cbd5e1;font-size:12px">'
  + '<div style="display:flex;justify-content:space-between;padding:2px 0"><span style="color:#64748b">Jornal + bonos + envasado</span><b>' + m(brutoSel) + '</b></div>'
  + '<div style="display:flex;justify-content:space-between;padding:2px 0"><span style="color:#d97706">− Consumos a crédito (8)</span><b style="color:#d97706">−' + m(consSel) + '</b></div></div>'
  + '<div style="margin-top:10px;background:#0f766e;border-radius:12px;padding:12px 16px;display:flex;justify-content:space-between;align-items:center;color:#fff"><div style="font-size:11px;font-weight:700;opacity:.85">NETO PAGADO</div><div style="font-size:26px;font-weight:900">' + m(netoSel) + '</div></div>'
  + '<div style="display:flex;justify-content:space-between;align-items:flex-end;margin-top:12px"><div style="font-size:10px;color:#64748b">Pagó: <b style="color:#1e293b">Javier</b><br>27/07/2026 · 3:15pm</div><div style="width:56px;height:56px;background:repeating-linear-gradient(45deg,#1e293b,#1e293b 2px,#fff 2px,#fff 4px);border-radius:6px"></div></div></div>';

// ticket ESC/POS
const W = 42;
const cen = s => { const p = Math.max(0, Math.floor((W - s.length) / 2)); return ' '.repeat(p) + s; };
const dc = (l, r) => l + ' '.repeat(Math.max(1, W - l.length - r.length)) + r;
let tk = '';
tk += cen('INVERSIONES MOS') + '\n' + cen('Comprobante de pago') + '\n' + '='.repeat(W) + '\n';
tk += dc('Persona:', 'Jorgenis Gonzalez') + '\n' + dc('Rol:', 'ALMACENERO') + '\n' + dc('Periodo:', '20-26 jul 2026') + '\n' + dc('Pagado por:', 'Javier') + '\n' + '-'.repeat(W) + '\n';
tk += 'DETALLE POR DIA:\n';
dias.forEach(d => {
  tk += '\n' + dc(d.d.toUpperCase() + ' jul', m(tot(d))) + '\n';
  tk += dc('  Base diaria', 'S/' + d.base.toFixed(2)) + '\n';
  if (d.env > 0) tk += dc('  Envasado' + (d.envC ? ' (comp. Luis)' : ''), 'S/' + d.env.toFixed(2)) + '\n';
  if (d.cons > 0) { tk += dc('  Consumo credito', '-S/' + d.cons.toFixed(2)) + '\n'; tk += dc('  Subneto dia', 'S/' + neto(d).toFixed(2)) + '\n'; }
});
tk += '='.repeat(W) + '\n' + dc('Total jornal', 'S/' + brutoSel.toFixed(2)) + '\n' + dc('Descuento consumos', '-S/' + consSel.toFixed(2)) + '\n' + '-'.repeat(W) + '\n';
tk += cen('NETO A PAGAR  S/' + netoSel.toFixed(2)) + '\n' + '='.repeat(W) + '\n' + cen('Gracias') + '\n';
const ticket = '<div style="width:340px"><div style="font-size:11px;color:#94a3b8;margin-bottom:8px;font-weight:600">🖨 Ticket profesional (si marcás imprimir)</div>'
  + '<pre style="background:#fdfdfb;color:#1a1a1a;padding:18px 14px;border-radius:8px;font-family:Courier New,monospace;font-size:11px;line-height:1.35;white-space:pre;box-shadow:0 6px 24px rgba(0,0,0,.4);margin:0">' + tk + '</pre></div>';

const html = '<!doctype html><meta charset=utf8><body style="background:#020617;padding:26px;font-family:-apple-system,Segoe UI,Roboto,sans-serif">'
  + '<div style="color:#f1f5f9;font-size:20px;font-weight:800;margin-bottom:4px">Rediseño · Liquidaciones <span style="color:#64748b;font-size:13px;font-weight:400">— mockup, datos reales de Jorgenis</span></div>'
  + '<div style="color:#64748b;font-size:12.5px;margin-bottom:20px">Vista limpia con detalle + Auditar/Vetar por día · preview elegante al pagar · ticket profesional</div>'
  + '<div style="display:flex;gap:26px;align-items:flex-start;flex-wrap:wrap"><div>' + vista + '</div>'
  + '<div style="display:flex;flex-direction:column;gap:22px"><div><div style="color:#94a3b8;font-size:12px;font-weight:700;margin-bottom:8px">📲 Preview al liquidar (imagen tipo guía WH)</div>' + preview + '</div>' + ticket + '</div></div></body>';
fs.writeFileSync(__dirname + '/redis.html', html);
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1080, height: 1400 }, deviceScaleFactor: 2 });
  await p.goto(pathToFileURL(__dirname + '/redis.html').href);
  await p.waitForTimeout(350);
  await p.screenshot({ path: __dirname + '/redis.png', fullPage: true });
  await b.close();
  console.log('=> redis.png · neto', netoSel);
})();
