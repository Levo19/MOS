const fs = require('fs');
const { chromium } = require('playwright');
const { pathToFileURL } = require('url');

const dias = [
  { d: 'lun 20', aud: 0, base: 80, env: 0, envC: 0, cons: 9.60, colab: '', vet: 0 },
  { d: 'mar 21', aud: 0, base: 80, env: 0, envC: 0, cons: 1.00, colab: '', vet: 0 },
  { d: 'mié 22', aud: 1, base: 80, env: 19.90, envC: 1, cons: 4.00, colab: 'Luis', vet: 0 },
  { d: 'jue 23', aud: 0, base: 80, env: 0, envC: 0, cons: 0, colab: '', vet: 1 }, // ejemplo VETADO
  { d: 'vie 24', aud: 1, base: 80, env: 6.15, envC: 1, cons: 6.80, colab: 'Luis', vet: 0 },
  { d: 'sáb 25', aud: 0, base: 80, env: 0, envC: 0, cons: 21.40, colab: '', vet: 0 },
  { d: 'dom 26', aud: 0, base: 80, env: 0, envC: 0, cons: 0, colab: '', vet: 0 },
];
const m = n => 'S/' + n.toFixed(2);
const tot = d => d.base + d.env;
const neto = d => Math.round((tot(d) - d.cons) * 100) / 100;
const chip = (t, c, b, dim) => '<span style="display:inline-block;padding:2px 7px;border-radius:6px;font-size:10px;font-weight:600;color:' + c + ';background:' + b + ';white-space:nowrap;' + (dim ? 'opacity:.45' : '') + '">' + t + '</span>';
// botones estilo Personal del día
const btnAud = '<button style="background:#3f8cff;color:#fff;border-radius:8px;padding:5px 12px;font-size:11px;font-weight:600;border:none">Auditar</button>';
const btnVet = '<button style="background:transparent;color:#f87171;border:1px solid rgba(248,113,113,.4);border-radius:8px;padding:5px 12px;font-size:11px;font-weight:600">Vetar</button>';
const btnDesvet = '<button style="background:transparent;color:#93c5fd;border:1px solid rgba(59,130,246,.45);border-radius:8px;padding:5px 12px;font-size:11px;font-weight:600">🔓 Desvetar</button>';

const dayCard = (d, sel) => {
  if (d.vet) {
    return '<div style="display:flex;align-items:center;gap:10px;padding:11px 12px;border-radius:10px;background:#0a0f18;border:1px dashed #3a2436;margin-bottom:7px;opacity:.85">'
      + '<div style="width:20px;height:20px;border-radius:6px;background:#1a1220;border:2px solid #7f1d1d;flex-shrink:0;display:flex;align-items:center;justify-content:center;font-size:11px">🚫</div>'
      + '<div style="flex:1;min-width:0"><div style="display:flex;align-items:center;gap:7px"><span style="font-size:12.5px;font-weight:600;color:#94a3b8;text-decoration:line-through;text-transform:capitalize">' + d.d + ' jul</span>'
      + '<span style="font-size:8px;font-weight:800;letter-spacing:.5px;padding:1px 6px;border-radius:5px;background:rgba(127,29,29,.3);color:#fca5a5">VETADO · NO SE PAGA</span></div>'
      + '<div style="margin-top:5px;display:flex;flex-wrap:wrap;gap:4px">' + chip('jornal 80.00', '#93c5fd', 'rgba(59,130,246,.12)', 1) + '</div></div>'
      + '<div style="text-align:right;flex-shrink:0"><div style="font-size:12px;color:#64748b;text-decoration:line-through">' + m(80) + '</div></div>'
      + '<div style="flex-shrink:0">' + btnDesvet + '</div></div>';
  }
  const ing = [chip('jornal ' + d.base.toFixed(2), '#93c5fd', 'rgba(59,130,246,.12)')];
  if (d.env > 0) ing.push(chip('+envasar ' + d.env.toFixed(2) + (d.envC ? ' 🤝' : ''), '#c4b5fd', 'rgba(139,92,246,.14)'));
  const des = [];
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
    + '<div style="display:flex;gap:6px;flex-shrink:0">' + btnAud + btnVet + '</div></div>';
};

const payDays = dias.filter(d => !d.vet);
const brutoSel = payDays.reduce((a, d) => a + tot(d), 0);
const consSel = payDays.reduce((a, d) => a + d.cons, 0);
const netoSel = Math.round((brutoSel - consSel) * 100) / 100;

const tabs = (active) => ['📋 Pendientes', '💰 Pagadas'].map((t, i) => '<span style="font-size:12.5px;padding:8px 16px;border-radius:10px;background:' + ((i == 0) === (active == 'pend') ? '#1e3a5f' : '#0b1220') + ';color:' + ((i == 0) === (active == 'pend') ? '#fff' : '#64748b') + ';border:1px solid ' + ((i == 0) === (active == 'pend') ? '#2f7fed' : '#1a2436') + ';font-weight:600">' + t + '</span>').join('');

const pend = '<div style="width:580px">'
  + '<div style="display:flex;gap:6px;margin-bottom:14px">' + tabs('pend') + '</div>'
  + '<div style="background:#0b1220;border:1px solid #1a2436;border-radius:16px;padding:16px">'
  + '<div style="display:flex;align-items:center;gap:12px;margin-bottom:12px">'
  + '<div style="width:44px;height:44px;border-radius:12px;background:linear-gradient(135deg,#1e3a5f,#2f7fed);display:flex;align-items:center;justify-content:center;font-size:22px">🏭</div>'
  + '<div style="flex:1"><div style="font-size:15px;font-weight:700;color:#f1f5f9">Jorgenis González <span style="font-size:10px;color:#64748b;font-weight:500">· ALMACENERO</span></div>'
  + '<div style="font-size:11px;color:#64748b;margin-top:2px">6 días por pagar · <b style="color:#34d399">6 seleccionados</b> · 1 vetado</div></div>'
  + '<div style="text-align:right"><div style="font-size:9px;text-transform:uppercase;letter-spacing:1px;color:#64748b;font-weight:700">Neto</div>'
  + '<div style="font-size:19px;font-weight:900;color:#34d399">' + m(netoSel) + '</div>'
  + '<div style="font-size:10px;color:#fbbf24">−' + m(consSel) + ' consumo · de ' + m(brutoSel) + '</div></div></div>'
  + '<label style="display:flex;align-items:center;gap:8px;font-size:11.5px;color:#94a3b8;margin-bottom:10px;padding-bottom:10px;border-bottom:1px solid #1a2436"><input type=checkbox checked style="width:15px;height:15px"> Marcar todos los pagables (6)</label>'
  + dias.map(d => dayCard(d, !d.vet)).join('')
  + '</div>'
  + '<div style="margin-top:14px;background:linear-gradient(135deg,#0f2a1e,#0b1220);border:1px solid rgba(52,211,153,.3);border-radius:14px;padding:14px 16px;display:flex;align-items:center;justify-content:space-between">'
  + '<div><div style="font-size:10px;text-transform:uppercase;letter-spacing:1px;color:#64748b;font-weight:700">💵 Seleccionado · 6 días</div>'
  + '<div style="font-size:22px;font-weight:900;color:#34d399">' + m(netoSel) + '</div></div>'
  + '<button style="padding:14px 24px;border-radius:12px;background:#10b981;color:#fff;font-weight:800;font-size:15px;border:none">💸 Pagar →</button></div>'
  + '<div style="text-align:center;color:#475569;font-size:11px;margin-top:12px">Cuando todo está pagado, esta lista queda vacía. Solo muestra lo que FALTA.</div></div>';

// PAGADAS
const batch = (nom, id, dias2, fecha, quien, total, anul) => '<div style="position:relative;background:#0b1220;border:1px solid ' + (anul ? 'rgba(248,113,113,.25)' : '#1a2436') + ';border-radius:12px;padding:13px;margin-bottom:9px;' + (anul ? 'opacity:.7' : '') + '">'
  + '<span style="position:absolute;top:10px;right:12px;font-size:8px;font-weight:900;letter-spacing:1px;padding:2px 8px;border-radius:5px;transform:rotate(4deg);background:' + (anul ? 'rgba(248,113,113,.15);color:#fca5a5' : 'rgba(52,211,153,.15);color:#34d399') + '">' + (anul ? 'ANULADO' : 'PAGADO') + '</span>'
  + '<div style="display:flex;align-items:center;gap:11px"><span style="font-size:18px">🏭</span>'
  + '<div style="flex:1"><div style="display:flex;gap:8px;align-items:center"><span style="font-size:13px;font-weight:700;color:#e2e8f0">' + nom + '</span><span style="font-size:9px;font-family:monospace;color:#64748b">' + id + '</span></div>'
  + '<div style="font-size:10px;color:#64748b;margin-top:2px">' + dias2 + ' día(s) · ' + fecha + ' · pagó <b style="color:#cbd5e1">' + quien + '</b></div></div>'
  + '<div style="font-size:15px;font-weight:800;color:' + (anul ? '#64748b' : '#34d399') + ';' + (anul ? 'text-decoration:line-through' : '') + '">' + m(total) + '</div></div></div>';
const pagadas = '<div style="width:440px">'
  + '<div style="display:flex;gap:6px;margin-bottom:14px">' + tabs('pag') + '</div>'
  + '<div style="background:#0b1220;border:1px solid #1a2436;border-radius:16px;padding:16px">'
  + '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;padding-bottom:10px;border-bottom:1px solid #1a2436">'
  + '<div style="font-size:12px;color:#94a3b8"><b style="color:#34d399">4</b> pago(s) registrados</div>'
  + '<div style="text-align:right"><div style="font-size:9px;text-transform:uppercase;color:#64748b;letter-spacing:1px">Total pagado</div><div style="font-size:17px;font-weight:800;color:#34d399">S/1,341.60</div></div></div>'
  + batch('Jorgenis González', 'LIQ-4a3922ed', 6, '27 jul 3:15pm', 'Javier', 543.25, 0)
  + batch('SERGIO Bailón', 'LIQ-282af6da', 6, '27 jul 3:10pm', 'Javier', 358.70, 0)
  + batch('Mia', 'LIQ-ac468892', 3, '27 jul 2:55pm', 'Javier', 208.18, 0)
  + batch('Jorgenis González', 'LIQ-9c142a77', 7, '26 jul 7:33pm', 'Javier', 517.20, 1)
  + '</div>'
  + '<div style="text-align:center;color:#475569;font-size:11px;margin-top:12px">Toca un pago → ver detalle · reimprimir · anular. El anulado revierte todo (retroactivo).</div></div>';

const html = '<!doctype html><meta charset=utf8><body style="background:#020617;padding:26px;font-family:-apple-system,Segoe UI,Roboto,sans-serif">'
  + '<div style="color:#f1f5f9;font-size:20px;font-weight:800;margin-bottom:4px">Rediseño Liquidaciones v2 <span style="color:#64748b;font-size:13px;font-weight:400">— sin filtros ni Resumen · botones = Personal del día · Pagadas · ciclo Vetar↔Desvetar</span></div>'
  + '<div style="display:flex;gap:26px;align-items:flex-start;flex-wrap:wrap;margin-top:16px">'
  + '<div>' + pend + '</div>'
  + '<div>' + pagadas + '</div></div>'
  + '<div style="color:#64748b;font-size:12px;margin-top:22px;max-width:900px;line-height:1.6">'
  + '<b style="color:#93c5fd">Notas:</b> ① Botones <b>Auditar</b> (azul) y <b>Vetar</b> idénticos a Personal del día — llaman el MISMO flujo (abrirAuditar / vetar por clave). ② Solo 2 pestañas: <b>Pendientes</b> + <b>Pagadas</b> (fuera Resumen). ③ Sin filtros de días: siempre muestra solo lo que FALTA pagar. ④ Día <b>jue 23 = VETADO</b>: tachado, no seleccionable, no suma al total, con <b>🔓 Desvetar</b> (retroactivo, vuelve a pendientes) — es un ciclo reversible. ⑤ El preview-imagen y el ticket profesional (ya aprobados) salen al pagar.</div>'
  + '</body>';
fs.writeFileSync(__dirname + '/redis2.html', html);
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1120, height: 900 }, deviceScaleFactor: 2 });
  await p.goto(pathToFileURL(__dirname + '/redis2.html').href);
  await p.waitForTimeout(350);
  await p.screenshot({ path: __dirname + '/redis2.png', fullPage: true });
  await b.close();
  console.log('=> redis2.png · neto', netoSel);
})();
