// ════════════════════════════════════════════════════════════════════════════
// Edge `ticket-comprobante` — REPARACIÓN #9: renderer CENTRAL de tickets de venta.
// Un solo formato para NOTA DE VENTA / BOLETA / FACTURA (y a futuro NC/ND). Lo llaman
// ME (al vender), MOS (reimpresión) y la conversión CPE → siempre el MISMO ticket.
// 100% Supabase, cero GAS. Lee fac.ticket_comprobante(idVenta) (empresa + venta + items +
// QR/IGV) y arma ESC/POS (QR nativo GS ( k) → PrintNode (raw_base64).
//
// AUTORIZACIÓN: la plataforma verifica la FIRMA del JWT (verify_jwt=true). Acá exigimos
// claim app ∈ {MOS, mosExpress, warehouseMos}. Secrets: SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY
// · PRINTNODE_API_KEY.
// Body: { idVenta, printerId, soloBase64?:true }  → soloBase64 devuelve el b64 sin imprimir (test).
// ════════════════════════════════════════════════════════════════════════════

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const p = token.split('.')[1];
    const s = p.replace(/-/g, '+').replace(/_/g, '/');
    const pad = s.length % 4 ? '='.repeat(4 - (s.length % 4)) : '';
    return JSON.parse(atob(s + pad));
  } catch { return null; }
}

const SB_URL = Deno.env.get('SUPABASE_URL') || '';
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';

// deno-lint-ignore no-explicit-any
async function sbRpc(profile: string, fn: string, args: Record<string, unknown>): Promise<any> {
  const resp = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'apikey': SB_KEY, 'Authorization': 'Bearer ' + SB_KEY,
      'Content-Profile': profile, 'Accept-Profile': profile, 'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  });
  if (!resp.ok) throw new Error('rpc ' + fn + ' ' + resp.status + ': ' + (await resp.text()));
  return await resp.json();
}

const W = 48;
function _norm(s: unknown): string {
  return String(s == null ? '' : s).normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^\x20-\x7e]/g, '?');
}
function _wrap(texto: string, ancho: number): string[] {
  texto = _norm(texto).trim();
  if (!texto) return [''];
  const palabras = texto.split(/\s+/);
  const out: string[] = []; let cur = '';
  for (let p of palabras) {
    while (p.length > ancho) { if (cur) { out.push(cur); cur = ''; } out.push(p.slice(0, ancho)); p = p.slice(ancho); }
    const sep = cur ? ' ' : '';
    if ((cur + sep + p).length <= ancho) cur = cur + sep + p; else { out.push(cur); cur = p; }
  }
  if (cur) out.push(cur);
  return out;
}
function _pad(left: string, right: string): string {
  left = _norm(left); right = _norm(right);
  let pad = W - left.length - right.length; if (pad < 1) pad = 1;
  return left + ' '.repeat(pad) + right;
}
function bytesToB64(B: number[]): string {
  let s = ''; for (let i = 0; i < B.length; i++) s += String.fromCharCode(B[i] & 0xff);
  return btoa(s);
}
function _money(n: unknown): string { const v = Number(n); return (Number.isFinite(v) ? v : 0).toFixed(2); }
// ¿producto vendido por PESO? (granel). La unidad de medida lo determina (KGM estándar SUNAT + variantes).
function _esPeso(unidad: unknown): boolean {
  const u = String(unidad || '').toUpperCase().trim();
  return u === 'KGM' || u === 'KG' || u === 'KGS' || u === 'G' || u === 'GMS' || u === 'GR';
}
// Cantidad INTELIGENTE: granel < 1 kg → gramos ("400 g"); >= 1 kg → kilos ("2.5 kg"); unidad → entero ("4").
function _fmtCant(cant: number, unidad: unknown): string {
  if (_esPeso(unidad)) {
    if (cant > 0 && cant < 1) return Math.round(cant * 1000) + ' g';
    const s = (cant % 1 === 0) ? cant.toFixed(0) : cant.toFixed(3).replace(/0+$/, '').replace(/\.$/, '');
    return s + ' kg';
  }
  return (cant % 1 === 0) ? String(cant) : cant.toFixed(3).replace(/0+$/, '').replace(/\.$/, '');
}

function _docLabel(tipo: string): string {
  const t = String(tipo || '').toUpperCase();
  if (t === 'BOLETA') return 'BOLETA DE VENTA ELECTRONICA';
  if (t === 'FACTURA') return 'FACTURA ELECTRONICA';
  if (t === 'NOTA_DE_VENTA' || t === 'NV') return 'NOTA DE VENTA';
  return t || 'COMPROBANTE';
}
function _cliDocLabel(tipoDoc: unknown): string {
  switch (Number(tipoDoc)) {
    case 1: return 'DNI'; case 4: return 'C.E.'; case 6: return 'RUC'; case 7: return 'PASAP'; default: return 'DOC';
  }
}
// [Reparación #9] WORDMARK por CÓDIGO: fuente de píxeles 5x7 → bitmap monocromo ESC/POS (GS v 0). Permite
// títulos estilizados (ej. "MOSexpress" con MOS en negrita + express normal) y el mini-emblema "LEVO" del pie.
// 100% original, imprime al instante. `segments` = tramos con bold opcional. `scale` controla la altura.
const FONT: Record<string, string[]> = {
  M: ['10001', '11011', '10101', '10101', '10001', '10001', '10001'],
  O: ['01110', '10001', '10001', '10001', '10001', '10001', '01110'],
  S: ['01111', '10000', '10000', '01110', '00001', '00001', '11110'],
  E: ['11111', '10000', '10000', '11110', '10000', '10000', '11111'],
  L: ['10000', '10000', '10000', '10000', '10000', '10000', '11111'],
  V: ['10001', '10001', '10001', '10001', '01010', '01010', '00100'],
  e: ['00000', '00000', '01110', '10001', '11111', '10000', '01110'],
  x: ['00000', '00000', '10001', '01010', '00100', '01010', '10001'],
  p: ['00000', '00000', '11110', '10001', '11110', '10000', '10000'],
  r: ['00000', '00000', '10110', '11000', '10000', '10000', '10000'],
  s: ['00000', '00000', '01111', '10000', '01110', '00001', '11110'],
  ' ': ['00000', '00000', '00000', '00000', '00000', '00000', '00000'],
};
function _wordmarkBytes(segments: { text: string; bold?: boolean }[], scale: number): number[] {
  const rows1: string[] = ['', '', '', '', '', '', ''];
  for (const seg of segments) {
    for (const ch of seg.text) {
      const g = FONT[ch] || FONT[' '];
      for (let r = 0; r < 7; r++) {
        let gr = g[r];
        if (seg.bold) { let nb = ''; for (let c = 0; c < gr.length; c++) nb += (gr[c] === '1' || (c > 0 && gr[c - 1] === '1')) ? '1' : '0'; gr = nb; }
        rows1[r] += gr + '0'; // 1-col de separación
      }
    }
  }
  const w1 = rows1[0].length;
  const grid: number[][] = [];
  for (let r = 0; r < 7; r++) for (let sy = 0; sy < scale; sy++) {
    const row: number[] = [];
    for (let c = 0; c < w1; c++) { const bit = rows1[r][c] === '1' ? 1 : 0; for (let sx = 0; sx < scale; sx++) row.push(bit); }
    grid.push(row);
  }
  const hPx = grid.length, wPx = grid[0].length;
  const totalBytes = 48;
  const wBytes = Math.ceil(wPx / 8);
  const padBytes = Math.max(0, Math.floor((totalBytes - wBytes) / 2));
  const data: number[] = [];
  for (let r = 0; r < hPx; r++) for (let b = 0; b < totalBytes; b++) {
    let byte = 0; const gc0 = (b - padBytes) * 8;
    if (gc0 >= 0) for (let bit = 0; bit < 8; bit++) { const c = gc0 + bit; if (c < wPx && grid[r][c]) byte |= (0x80 >> bit); }
    data.push(byte);
  }
  return [0x1d, 0x76, 0x30, 0, totalBytes & 0xff, (totalBytes >> 8) & 0xff, hPx & 0xff, (hPx >> 8) & 0xff, ...data];
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const APPS_OK = new Set(['MOS', 'mosExpress', 'warehouseMos']);
    const auth = req.headers.get('Authorization') || '';
    const token = auth.replace(/^Bearer\s+/i, '').trim();
    const claims = jwtClaims(token);
    if (!claims || !APPS_OK.has(String(claims.app))) return json({ ok: false, error: 'no autorizado (claim app)' }, 401);
    if (!SB_URL || !SB_KEY) return json({ ok: false, error: 'SUPABASE_URL / SERVICE_ROLE_KEY no configurados' }, 500);

    const body = await req.json().catch(() => ({}));
    const idVenta = String(body.idVenta || '');
    if (!idVenta) return json({ ok: false, error: 'idVenta requerido' }, 400);

    // PostgREST NO expone el schema `fac` (solo public/me/mos/wh) → usamos el wrapper mos.ticket_comprobante.
    const rpc = await sbRpc('mos', 'ticket_comprobante', { p: { idVenta } });
    if (!rpc || rpc.ok !== true || !rpc.data) return json({ ok: false, error: (rpc && rpc.error) || 'comprobante no encontrado' }, 404);
    const d = rpc.data;
    const emp = d.empresa || {};
    const tipo = String(d.tipoDoc || '').toUpperCase();
    const esCPE = (tipo === 'BOLETA' || tipo === 'FACTURA');

    // ── Buffer ESC/POS ────────────────────────────────────────────────────────
    const B: number[] = [];
    const b1 = (n: number) => B.push(n & 0xff);
    const bStr = (s: string) => { for (let i = 0; i < s.length; i++) b1(s.charCodeAt(i)); };
    const bLn = (s: string) => { bStr(s); b1(0x0a); };
    const SEP = '-'.repeat(W);
    const CTR = () => { b1(0x1b); b1(0x61); b1(0x01); };
    const LEFT = () => { b1(0x1b); b1(0x61); b1(0x00); };
    const RIGHT = () => { b1(0x1b); b1(0x61); b1(0x02); };
    const BOLD = (on: boolean) => { b1(0x1b); b1(0x45); on ? b1(0x01) : b1(0x00); };
    const SIZE = (mode: number) => { b1(0x1b); b1(0x21); b1(mode); }; // 0x00 normal, 0x10 doble alto, 0x30 doble

    b1(0x1b); b1(0x40);                       // init
    // ── Encabezado: TÍTULO "MOSexpress" (wordmark bitmap, MOS en negrita + express normal, alto y moderno) ──
    CTR();
    for (const byte of _wordmarkBytes([{ text: 'MOS', bold: true }, { text: 'express' }], 4)) b1(byte);
    b1(0x0a); b1(0x0a);
    // Razón social LEGAL en CHICO (como el RUC), no grande.
    const _rs = _norm(emp.razonSocial || 'INVERSIONES MOS');
    BOLD(true); bLn(_rs); BOLD(false);
    if (emp.ruc) bLn('R.U.C. ' + _norm(emp.ruc));
    _wrap(String(emp.direccion || ''), W).forEach((l) => l && bLn(l));
    if (emp.telefono || emp.email) bLn(_norm([emp.telefono ? 'Tel ' + emp.telefono : '', emp.email || ''].filter(Boolean).join('  ')));
    bLn('='.repeat(W));
    // ── Tipo de documento + correlativo ──
    SIZE(0x10); BOLD(true); bLn(_docLabel(tipo)); BOLD(false);
    bLn(_norm(d.correlativo || d.idVenta || '')); SIZE(0x00);
    LEFT(); bLn(SEP);
    // ── Meta ──
    const fecha = d.fecha ? new Date(d.fecha) : null;
    const fStr = fecha ? new Intl.DateTimeFormat('es-PE', { timeZone: 'America/Lima', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }).format(fecha) : '';
    bLn(_pad('Fecha : ' + fStr, d.vendedor ? ('Cajero: ' + _norm(d.vendedor)).slice(0, 20) : ''));
    // ── Cliente ──
    const cliNom = String(d.clienteNombre || '').trim();
    const cliDoc = String(d.clienteDoc || '').trim();
    if (cliNom || cliDoc) {
      if (cliNom) _wrap('Cliente: ' + cliNom, W).forEach((l) => bLn(l));
      if (cliDoc) bLn(_cliDocLabel(d.tipoDocCliente) + '    : ' + _norm(cliDoc));
    }
    bLn(SEP);
    // ── Items ── profesional: nombre (máx 2 renglones, ancho completo) + "cant inteligente x precio … subtotal".
    // Granel (peso) → cantidad en g/kg y precio /kg. Unidad → entero y precio unitario.
    BOLD(true); bLn(_pad('DESCRIPCION', 'IMPORTE')); BOLD(false);
    (d.items || []).forEach((it: Record<string, unknown>) => {
      const cant = Number(it.cantidad) || 0;
      const precio = Number(it.precio) || 0;
      const um = it.unidadMedida;
      const nom = String(it.nombre || '').replace(/\s*\(.*\)\s*$/, '');
      const sub = _money(it.subtotal);
      // nombre: hasta 2 renglones a ancho completo; si excede, recortar el 2do con "…".
      let ls = _wrap(nom, W);
      if (ls.length > 2) { ls = ls.slice(0, 2); ls[1] = ls[1].slice(0, W - 3) + '...'; }
      ls.forEach((l) => bLn(l));
      const cantTxt = _fmtCant(cant, um);
      const unitTxt = _esPeso(um) ? ('S/ ' + _money(precio) + '/kg') : ('S/ ' + _money(precio));
      bLn(_pad('  ' + cantTxt + '  x  ' + unitTxt, 'S/ ' + sub));
    });
    bLn(SEP);
    // ── Totales ── (label izq · S/ monto der). IGV solo sobre lo gravado; exonerado/inafecto aparte.
    if (esCPE && d.totalGravada != null) {
      if (Number(d.totalGravada) > 0) {
        bLn(_pad('OP. GRAVADA', 'S/ ' + _money(d.totalGravada)));
        bLn(_pad('IGV (18%)',   'S/ ' + _money(d.totalIgv)));
      }
      if (Number(d.totalExonerada) > 0) bLn(_pad('OP. EXON./INAF.', 'S/ ' + _money(d.totalExonerada)));
    }
    SIZE(0x10); BOLD(true); bLn(_pad('TOTAL', 'S/ ' + _money(d.total))); BOLD(false); SIZE(0x00);
    if (d.formaPago) bLn('Forma de pago: ' + _norm(d.formaPago));
    bLn(SEP);
    // ── QR ── CPE: SOLO el QR SUNAT real (nunca el correlativo, que no es un QR fiscal válido).
    //          NV: el correlativo como QR es aceptable. (el RPC ya devuelve nfQr='' para CPE sin QR fiscal)
    const qrData = esCPE ? String(d.nfQr || '') : String(d.nfQr || d.correlativo || d.idVenta || '');
    if (qrData) {
      CTR();
      const qrLen = qrData.length + 3;
      b1(0x1d); b1(0x28); b1(0x6b); b1(0x04); b1(0x00); b1(0x31); b1(0x41); b1(0x32); b1(0x00); // model 2
      b1(0x1d); b1(0x28); b1(0x6b); b1(0x03); b1(0x00); b1(0x31); b1(0x43); b1(0x05);            // module 5
      b1(0x1d); b1(0x28); b1(0x6b); b1(0x03); b1(0x00); b1(0x31); b1(0x45); b1(0x31);            // ecc L
      b1(0x1d); b1(0x28); b1(0x6b); b1(qrLen & 0xff); b1((qrLen >> 8) & 0xff); b1(0x31); b1(0x50); b1(0x30); // store
      bStr(qrData);
      b1(0x1d); b1(0x28); b1(0x6b); b1(0x03); b1(0x00); b1(0x31); b1(0x51); b1(0x30);            // print
      b1(0x0a);
      LEFT();
    }
    // ── Pie ──
    CTR();
    if (esCPE) {
      _wrap('Representacion impresa de la ' + _docLabel(tipo) + '.', W).forEach((l) => bLn(l));
      // [#9/#6 review] Solo declarar "Autorizado R.I. SUNAT" si el CPE realmente fue EMITIDO (tiene hash o QR
      // SUNAT). Un CPE PENDIENTE (aun no aceptado por NubeFact/SUNAT) NO esta autorizado → decir lo contrario
      // es enganoso/fiscalmente incorrecto. Pendiente → leyenda honesta.
      const _emitido = !!(d.nfHash || qrData);
      if (_emitido) {
        bLn('Autorizado mediante R.I. SUNAT');
        if (d.nfHash) bLn('Hash: ' + _norm(d.nfHash));
      } else {
        bLn('Comprobante en proceso de envio a SUNAT');
      }
      if (emp.email) bLn('Consulte: ' + _norm(emp.email));
    } else {
      bLn('Gracias por su compra');
      bLn('(Nota de venta - no es comprobante');
      bLn('de pago electronico)');
    }
    if (body.reimpresion === true) bLn('* REIMPRESION *');
    // ── Crédito del desarrollador: emblema LEVO chico + "by levo.dev" (minimal) ──
    bLn('');
    for (const byte of _wordmarkBytes([{ text: 'LEVO' }], 2)) b1(byte);  // emblema LEVO CHICO (raster GS v 0)
    b1(0x0a);
    bLn('by levo.dev');
    LEFT();
    b1(0x1b); b1(0x4a); b1(0x96);              // feed (150 dots)
    b1(0x1d); b1(0x56); b1(0x00);             // corte

    const b64 = bytesToB64(B);
    if (body.soloBase64 === true) return json({ ok: true, base64: b64, tipo, correlativo: d.correlativo });

    const printerId = parseInt(String(body.printerId), 10);
    if (!printerId || printerId <= 0) return json({ ok: false, error: 'printerId inválido' }, 400);
    const key = Deno.env.get('PRINTNODE_API_KEY');
    if (!key) return json({ ok: false, error: 'PRINTNODE_API_KEY no configurada (secret)' }, 500);
    const pn = await fetch('https://api.printnode.com/printjobs', {
      method: 'POST',
      headers: { 'Authorization': 'Basic ' + btoa(key + ':'), 'Content-Type': 'application/json' },
      body: JSON.stringify({ printerId, title: _docLabel(tipo) + ' ' + (d.correlativo || ''), contentType: 'raw_base64', content: b64, source: String(claims.app || 'mos') + '-ticket' }),
    });
    const text = await pn.text();
    if (pn.status !== 201) return json({ ok: false, error: 'PrintNode ' + pn.status + ': ' + text }, 502);
    return json({ ok: true, jobId: text, tipo, correlativo: d.correlativo });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
