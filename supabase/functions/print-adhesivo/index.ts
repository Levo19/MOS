// Edge Function `print-adhesivo` — impresión de adhesivos (lotes de envasado) NATIVA en Supabase.
//
// Reemplaza al motor GAS (Envasados.gs: crearLoteAdhesivo/imprimirSubLoteAdhesivo/LotesTrigger).
// CONSTRUYE el TSPL2 server-side (logo bitmap + barcode adaptativo + word-wrap + highlights + Vto)
// y orquesta la impresión contra las RPCs ATÓMICAS de Supabase (206_wh_lotes_adhesivo_migracion.sql):
//   reservar → claim atómico del rango [desde,hasta) (FOR UPDATE) → imprimir ese rango → marcar.
// La RESERVA atómica + el least() de la RPC hacen IMPOSIBLE la sobre-impresión (el bug 40→50/80).
//
// MODOS (POST body):
//   { mode:'lote',    idLote }  → procesa un lote hasta terminar/pausar (con presupuesto de tiempo).
//   { mode:'pending', limit? }  → procesa la cola (pg_cron lo invoca; fire-and-forget).
//
// AUTORIZACIÓN: verify_jwt=true (la plataforma valida la firma). Aceptamos claim app='warehouseMos'
// (token mint-wh) O role='service_role' (pg_cron / backend). Patrón = riz-print/imprimir.
//
// SECRETS (los setea el dueño):
//   supabase secrets set PRINTNODE_API_KEY=<key> --project-ref rzbzdeipbtqkzjqdchqk
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-inyectados.
// DEPLOY: supabase functions deploy print-adhesivo --project-ref rzbzdeipbtqkzjqdchqk
//
// INERTE: las RPCs gatean en el flag WH_LOTE_ADHESIVO_DIRECTO (default '0') → mientras OFF, devuelven
// WH_LOTE_ADHESIVO_DIRECTO_OFF y esta Edge no imprime nada. GAS sigue siendo la vía viva hasta el cutover.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['warehouseMos', 'MOS']);   // WH (envasado/reimpresión) + MOS (modal cantidad+preview)
const WALL_BUDGET_MS = 110000;  // tope de ejecución por invocación (cron re-invoca para continuar)
const POLL_MS = 12000;          // poll corto a PrintNode por sub-job (solo para detectar out-of-paper)

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1]; if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64));
  } catch { return null; }
}

// ════════════════ TSPL2 — port fiel de gas/Envasados.gs ════════════════
const LOGO_W_BYTES = 23;
const LOGO_H = 36;
const LOGO_TSPL_HEX =
'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' +
'FFFFFFFFFFFFFFFFFFFFF7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE3FFFFC000' +
'1FE03FE0780C078083F80FFFFFFFFFFFFFFFC1FFFFC0001F800FE0380C078083C001FFFFFFFF' +
'FFFFFF007FFFC0001E0007E0380C0701838000FFFFFFFFFFFFFE003FFFC0001E0003E0380E03' +
'018380007FFFFFFFFFFFFC001FFFC0001C0001E0180E03018300007FFFFFFFFFFFF8000FFFC0' +
'001C0201E0180E03018300C07FFFFFFFFFFFE00003FFFE01FC0701E0180F03038301C07FFFFF' +
'FFFFFFC00001FFFE01F80701E0080F03038301C07FFFFFFFFFFF800000FFFE01F80701E0080F' +
'0203C301C07FFFFFFFFFFF0000007FFE01F80701E0080F8007FF00FFFFFFFFFFFFFC0000001F' +
'FE01F80701E0080F8007FF007FFFFFFFFFFFF000000007FE01F80701E0000F8007FF001FFFFF' +
'FFFFFFF000000007FE01F80701E0000F800FFF800FFFFFFFFFFFF000000007FE01F80701E000' +
'0FC00FFFC003FFFFFFFFFFF000000007FE01F80701E0000FC00FFFE001FFFFFFFFFFF0000000' +
'07FE01F80701E0000FC00FFFF000FFFFFFFFFFFE0000003FFE01F80701E0000FE01FFFFC007F' +
'FFFFFFFFFE0000003FFE01F80701E0000FE01FFFFE007FFFFFFFFFFE3E003E3FFE01F80701E0' +
'400FE01FFFFF807FFFFFFFFFFE3E003E3FFE01F80701E0400FE01FFF01C03FFFFFFFFFFE3E00' +
'3E3FFE01F80701E0400FE01FFF01C03FFFFFFFFFFE3EFFBE3FFE01F80701E0600FE01FFF01C0' +
'3FFFFFFFFFFE00FF803FFE01F80701E0600FE01FFF01C03FFFFFFFFFFE00FF803FFE01FC0701' +
'E0600FE01FFF01C03FFFFFFFFFFE00FF803FFE01FC0601E0700FE01FFF00C03FFFFFFFFFFE00' +
'FF803FFE01FC0001E0700FE01FFF80007FFFFFFFFFFE00FF803FFE01FE0003E0700FE01FFF80' +
'007FFFFFFFFFFE00FF803FFE01FE0007E0700FE01FFFC000FFFFFFFFFFFE00FF803FFE01FF80' +
'0FE0780FE01FFFE001FFFFFFFFFFFE00FF803FFE01FFE03FE0780FE01FFFF807FFFFFFFFFFFE' +
'00FF803FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE00FF803FFFFFFFFFFFFFFFFFFFFFFF' +
'FFFFFFFFFFFFFFFE00FF803FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF';
const MESES_ES = ['ENE','FEB','MAR','ABR','MAY','JUN','JUL','AGO','SEP','OCT','NOV','DIC'];

function normalizeEtq(s: unknown): string {
  if (s === null || s === undefined) return '';
  return String(s).normalize('NFD').replace(/[̀-ͯ]/g, '');
}
function calcVencimientoEtq(fechaEnvasado: Date | string | null): string {
  const d = fechaEnvasado ? new Date(fechaEnvasado) : new Date();
  d.setFullYear(d.getFullYear() + 1);
  return MESES_ES[d.getMonth()] + '/' + d.getFullYear();
}
function vtoStringAFechaEnvasado(vtoStr: string): Date {
  if (!vtoStr) return new Date();
  const parts = String(vtoStr).split('/');
  if (parts.length !== 2) return new Date();
  const mesIdx = MESES_ES.indexOf(parts[0].toUpperCase());
  const anio = parseInt(parts[1], 10);
  if (mesIdx < 0 || !anio) return new Date();
  return new Date(anio - 1, mesIdx, 1);
}
function detectHighlightsEtq(targetTokens: string[], allTokenized: string[][]): number[] {
  const hl: Record<number, boolean> = {};
  hl[targetTokens.length - 1] = true;
  for (let i = 0; i < allTokenized.length; i++) {
    const s = allTokenized[i];
    if (s === targetTokens) continue;
    if (s[0] !== targetTokens[0]) continue;
    for (let pos = 1; pos < targetTokens.length; pos++) {
      if (hl[pos]) continue;
      let prior = true;
      for (let k = 0; k < pos; k++) { if (s[k] !== targetTokens[k]) { prior = false; break; } }
      if (prior && s[pos] !== undefined && s[pos] !== targetTokens[pos]) { hl[pos] = true; break; }
    }
  }
  const out: number[] = [];
  for (const key in hl) if (hl[key]) out.push(parseInt(key, 10));
  out.sort((a, b) => a - b);
  return out;
}
function fontWidthEtq(isHighlight: boolean): number { return isHighlight ? 24 : 16; }
type Tok = { tok: string; hl: boolean; w: number };
function wrapTokensEtq(tokens: string[], highlights: number[]): Tok[][] {
  const MAX_W = 370, SPACE = 8;
  const widths = tokens.map((t, i) => t.length * fontWidthEtq(highlights.indexOf(i) >= 0));
  const isHl = (i: number) => highlights.indexOf(i) >= 0;
  let total = 0;
  for (let i = 0; i < widths.length; i++) total += widths[i] + (i > 0 ? SPACE : 0);
  if (total <= MAX_W) return [tokens.map((t, i) => ({ tok: t, hl: isHl(i), w: widths[i] }))];
  const firstHl = highlights.length > 0 ? highlights[0] : tokens.length;
  if (firstHl > 0 && firstHl < tokens.length) {
    const l1: Tok[] = []; let w1 = 0;
    for (let a = 0; a < firstHl; a++) { w1 += widths[a] + (l1.length > 0 ? SPACE : 0); l1.push({ tok: tokens[a], hl: false, w: widths[a] }); }
    const l2: Tok[] = []; let w2 = 0;
    for (let b = firstHl; b < tokens.length; b++) { w2 += widths[b] + (l2.length > 0 ? SPACE : 0); l2.push({ tok: tokens[b], hl: isHl(b), w: widths[b] }); }
    if (w1 <= MAX_W && w2 <= MAX_W) return [l1, l2];
  }
  const lines: Tok[][] = [[]]; let curW = 0;
  for (let c = 0; c < tokens.length; c++) {
    const sep = lines[lines.length - 1].length === 0 ? 0 : SPACE;
    if (curW + sep + widths[c] <= MAX_W) { lines[lines.length - 1].push({ tok: tokens[c], hl: isHl(c), w: widths[c] }); curW += sep + widths[c]; }
    else if (lines.length === 1) { lines.push([{ tok: tokens[c], hl: isHl(c), w: widths[c] }]); curW = widths[c]; }
    else { lines[1].push({ tok: tokens[c], hl: isHl(c), w: widths[c] }); curW += sep + widths[c]; }
  }
  return lines;
}
function hexToBytes(hex: string): number[] { const a: number[] = []; for (let i = 0; i < hex.length; i += 2) a.push(parseInt(hex.substr(i, 2), 16)); return a; }
function strToBytes(s: string): number[] { const a: number[] = []; for (let i = 0; i < s.length; i++) a.push(s.charCodeAt(i) & 0xFF); return a; }
function calcBarcodeAdaptativo(codigo: string) {
  const bc = String(codigo || '').replace(/"/g, '');
  const bcLen = bc.length;
  const modules = 11 * bcLen + 35;
  let narrowBc: number, quietZoneMin: number;
  if (modules * 3 <= 340) { narrowBc = 3; quietZoneMin = 30; }
  else if (modules * 2 <= 360) { narrowBc = 2; quietZoneMin = 20; }
  else if (modules * 2 <= 376) { narrowBc = 2; quietZoneMin = 12; }
  else { narrowBc = 2; quietZoneMin = 8; }
  const barcodeWidth = modules * narrowBc;
  const barcodeHeight = 48;
  const barcodeX = Math.max(quietZoneMin, Math.floor((400 - barcodeWidth) / 2));
  return { bc, bcLen, narrowBc, barcodeWidth, barcodeHeight, quietZoneMin, barcodeX };
}

type DriftCfg = { gapMm: number; density: number; speed: number; offsetBase: number; driftDots: number; printsBase: number };
// Construye los bytes TSPL2 para N etiquetas (port de _buildTSPLEtq). `iBase` = índice absoluto de
// la primera etiqueta del sub-job en el rollo (para el drift acumulado), = `desde` de la reserva.
function buildTSPLEtq(producto: { codigoBarra: string; descripcion: string }, fechaEnvasado: Date,
                      unidades: number, allEnvTokens: string[][], cfg: DriftCfg, iBase: number, withGapDetect: boolean): number[] {
  const descNorm = normalizeEtq(producto.descripcion);
  const tokens = descNorm.split(/\s+/);
  const highlights = detectHighlightsEtq(tokens, allEnvTokens);
  const lines = wrapTokensEtq(tokens, highlights);
  const vto = calcVencimientoEtq(fechaEnvasado);

  const offsetParaEtiqueta = (iEnRollo: number): number => {
    const comp = Math.round(cfg.driftDots * (cfg.printsBase + iEnRollo));
    let off = cfg.offsetBase + comp;
    if (off < -1) off = -1;
    if (off > 16) off = 16;
    return off;
  };

  const headerGlobal = [
    'SIZE 50 mm,25 mm', 'GAP ' + cfg.gapMm + ' mm,0 mm', 'DIRECTION 1',
    'DENSITY ' + cfg.density, 'SPEED ' + cfg.speed, '',
  ].join('\r\n');
  let bytes = strToBytes(headerGlobal);

  const _bc = calcBarcodeAdaptativo(producto.codigoBarra);
  const bc = _bc.bc, narrowBc = _bc.narrowBc, barcodeHeight = _bc.barcodeHeight, barcodeX = _bc.barcodeX;
  const frameX1 = 10, frameX2 = 389, cmL = 12, codigoFontW = 8;
  const codigoWidth = bc.length * codigoFontW;
  const codigoX = Math.max(frameX1 + 4, Math.floor((400 - codigoWidth) / 2));

  const N = unidades || 1;
  for (let iEtq = 0; iEtq < N; iEtq++) {
    const offsetY = offsetParaEtiqueta(iBase + iEtq);
    bytes = bytes.concat(strToBytes('CLS\r\n' + 'BITMAP 5,' + (2 + offsetY) + ',' + LOGO_W_BYTES + ',' + LOGO_H + ',0,'));
    bytes = bytes.concat(hexToBytes(LOGO_TSPL_HEX));
    bytes = bytes.concat(strToBytes('\r\n'));
    bytes = bytes.concat(strToBytes('TEXT 232,' + (12 + offsetY) + ',"2",0,1,1,"Vto ' + vto + '"\r\n'));
    bytes = bytes.concat(strToBytes('BAR 5,' + (42 + offsetY) + ',390,1\r\n'));

    const DESC_AREA_Y0 = 46, DESC_AREA_H = 72, LINE_H = 38, SPACE = 8;
    let startY: number;
    if (lines.length === 1) {
      const lineHasHl = lines[0].some((t) => t.hl);
      const lineHeight = lineHasHl ? 32 : 24;
      const baselineOffset = lineHasHl ? 0 : 4;
      startY = DESC_AREA_Y0 + Math.floor((DESC_AREA_H - lineHeight) / 2) - baselineOffset + offsetY;
    } else { startY = DESC_AREA_Y0 + offsetY; }
    for (let li = 0; li < lines.length; li++) {
      const line = lines[li];
      let totalW = 0;
      for (let ti = 0; ti < line.length; ti++) totalW += line[ti].w + (ti > 0 ? SPACE : 0);
      let x = Math.max(5, Math.round((400 - totalW) / 2));
      const y = startY + li * LINE_H;
      for (let tj = 0; tj < line.length; tj++) {
        const o = line[tj];
        const font = o.hl ? '4' : '3';
        const yAdj = o.hl ? y : y + 4;
        const safe = String(o.tok).replace(/"/g, "'");
        bytes = bytes.concat(strToBytes('TEXT ' + x + ',' + yAdj + ',"' + font + '",0,1,1,"' + safe + '"\r\n'));
        x += o.w + SPACE;
      }
    }

    const barcodeY = 124 + offsetY, frameY1 = 118 + offsetY, frameY2 = 196 + offsetY;
    bytes = bytes.concat(strToBytes('BAR ' + frameX1 + ',' + frameY1 + ',' + cmL + ',1\r\n'));
    bytes = bytes.concat(strToBytes('BAR ' + frameX1 + ',' + frameY1 + ',1,' + cmL + '\r\n'));
    bytes = bytes.concat(strToBytes('BAR ' + (frameX2 - cmL + 1) + ',' + frameY1 + ',' + cmL + ',1\r\n'));
    bytes = bytes.concat(strToBytes('BAR ' + frameX2 + ',' + frameY1 + ',1,' + cmL + '\r\n'));
    bytes = bytes.concat(strToBytes('BAR ' + frameX1 + ',' + frameY2 + ',' + cmL + ',1\r\n'));
    bytes = bytes.concat(strToBytes('BAR ' + frameX1 + ',' + (frameY2 - cmL + 1) + ',1,' + cmL + '\r\n'));
    bytes = bytes.concat(strToBytes('BAR ' + (frameX2 - cmL + 1) + ',' + frameY2 + ',' + cmL + ',1\r\n'));
    bytes = bytes.concat(strToBytes('BAR ' + frameX2 + ',' + (frameY2 - cmL + 1) + ',1,' + cmL + '\r\n'));
    bytes = bytes.concat(strToBytes('BARCODE ' + barcodeX + ',' + barcodeY + ',"128",' + barcodeHeight + ',0,0,' + narrowBc + ',' + narrowBc + ',"' + bc + '"\r\n'));
    const codigoY = barcodeY + barcodeHeight + 8;
    bytes = bytes.concat(strToBytes('TEXT ' + codigoX + ',' + codigoY + ',"1",0,1,1,"' + bc + '"\r\n'));
    bytes = bytes.concat(strToBytes('PRINT 1,1\r\n'));
  }

  if (withGapDetect) {
    // GAPDETECT antes del primer CLS (re-mide el sensor al rollo).
    const prefix = strToBytes('GAPDETECT\r\n');
    for (let i = 0; i < bytes.length - 5; i++) {
      if (bytes[i] === 67 && bytes[i+1] === 76 && bytes[i+2] === 83 && bytes[i+3] === 13 && bytes[i+4] === 10) {
        return bytes.slice(0, i).concat(prefix).concat(bytes.slice(i));
      }
    }
    return prefix.concat(bytes);
  }
  return bytes;
}
function bytesToBase64(arr: number[]): string {
  let s = ''; const CH = 8192;
  for (let i = 0; i < arr.length; i += CH) s += String.fromCharCode.apply(null, arr.slice(i, i + CH) as unknown as number[]);
  return btoa(s);
}

// ════════════════ Supabase / PrintNode ════════════════
const SB_URL = Deno.env.get('SUPABASE_URL');
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

async function rpcWh(fn: string, p: Record<string, unknown>): Promise<any> {
  if (!SB_URL || !SB_KEY) throw new Error('SUPABASE_URL/SERVICE_ROLE_KEY no disponibles');
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { 'apikey': SB_KEY, 'Authorization': 'Bearer ' + SB_KEY,
      'Accept-Profile': 'wh', 'Content-Profile': 'wh', 'Content-Type': 'application/json' },
    body: JSON.stringify({ p }),
  });
  const txt = await r.text();
  if (!r.ok) throw new Error('rpc ' + fn + ' HTTP ' + r.status + ': ' + txt);
  try { return JSON.parse(txt); } catch { return txt; }
}
// Lee config de drift/impresora desde mos.config (defaults = rollo calibrado, sin drift).
async function leerDriftCfg(): Promise<DriftCfg> {
  const def: DriftCfg = { gapMm: 2, density: 8, speed: 4, offsetBase: 0, driftDots: 0, printsBase: 0 };
  try {
    const keys = ['ADHESIVO_GAP_MM','ADHESIVO_DENSITY','ADHESIVO_SPEED','ADHESIVO_OFFSET_Y','ADHESIVO_DRIFT_DOTS_POR_PRINT','ADHESIVO_PRINTS_DESDE_CAL'];
    const r = await fetch(`${SB_URL}/rest/v1/config?select=clave,valor&clave=in.(${keys.join(',')})`, {
      headers: { 'apikey': SB_KEY!, 'Authorization': 'Bearer ' + SB_KEY!, 'Accept-Profile': 'mos' },
    });
    if (r.ok) {
      const rows = await r.json();
      const m: Record<string, string> = {};
      for (const row of (rows || [])) m[row.clave] = row.valor;
      if (m.ADHESIVO_GAP_MM != null) def.gapMm = parseFloat(m.ADHESIVO_GAP_MM) || 2;
      if (m.ADHESIVO_DENSITY != null) def.density = parseInt(m.ADHESIVO_DENSITY, 10) || 8;
      if (m.ADHESIVO_SPEED != null) def.speed = parseInt(m.ADHESIVO_SPEED, 10) || 4;
      if (m.ADHESIVO_OFFSET_Y != null) def.offsetBase = parseFloat(m.ADHESIVO_OFFSET_Y) || 0;
      if (m.ADHESIVO_DRIFT_DOTS_POR_PRINT != null) def.driftDots = parseFloat(m.ADHESIVO_DRIFT_DOTS_POR_PRINT) || 0;
      if (m.ADHESIVO_PRINTS_DESDE_CAL != null) def.printsBase = parseInt(m.ADHESIVO_PRINTS_DESDE_CAL, 10) || 0;
    }
  } catch { /* defaults */ }
  return def;
}
// Lista de envasables tokenizados (para detectar diferenciadores). codigo_barra WH* activos.
async function leerEnvasablesTokens(): Promise<string[][]> {
  try {
    const r = await fetch(`${SB_URL}/rest/v1/productos?select=codigo_barra,descripcion&codigo_barra=ilike.WH*`, {
      headers: { 'apikey': SB_KEY!, 'Authorization': 'Bearer ' + SB_KEY!, 'Accept-Profile': 'mos' },
    });
    if (!r.ok) return [];
    const rows = await r.json();
    return (rows || []).map((p: any) => normalizeEtq(p.descripcion).split(/\s+/));
  } catch { return []; }
}
// Resuelve la impresora ADHESIVO desde mos.impresoras (prefiere ALMACEN; fallback cualquier ADHESIVO activa).
async function resolverPrinterAdhesivo(): Promise<string> {
  try {
    let r = await fetch(`${SB_URL}/rest/v1/impresoras?select=printnode_id&tipo=eq.ADHESIVO&activo=eq.true&id_zona=eq.ALMACEN&limit=1`, {
      headers: { 'apikey': SB_KEY!, 'Authorization': 'Bearer ' + SB_KEY!, 'Accept-Profile': 'mos' },
    });
    let rows = r.ok ? await r.json() : [];
    if (!rows || !rows.length) {
      r = await fetch(`${SB_URL}/rest/v1/impresoras?select=printnode_id&tipo=eq.ADHESIVO&activo=eq.true&limit=1`, {
        headers: { 'apikey': SB_KEY!, 'Authorization': 'Bearer ' + SB_KEY!, 'Accept-Profile': 'mos' },
      });
      rows = r.ok ? await r.json() : [];
    }
    return (rows && rows.length) ? String(rows[0].printnode_id || '') : '';
  } catch { return ''; }
}
const PN_KEY = Deno.env.get('PRINTNODE_API_KEY');
async function printNodePost(printerId: number, title: string, b64: string, idLote: string): Promise<{ ok: boolean; jobId?: string; status: number; txt: string }> {
  const r = await fetch('https://api.printnode.com/printjobs', {
    method: 'POST',
    headers: { 'Authorization': 'Basic ' + btoa(PN_KEY + ':'), 'Content-Type': 'application/json' },
    body: JSON.stringify({ printerId, title, contentType: 'raw_base64', content: b64, source: 'supabase-print-adhesivo-' + idLote }),
  });
  const txt = await r.text();
  return { ok: r.status === 201, jobId: r.status === 201 ? txt : undefined, status: r.status, txt };
}
async function pollJobOutOfPaper(jobId: string, maxMs: number): Promise<{ estado: 'done'|'error'|'timeout'; outOfPaper: boolean; mensaje: string }> {
  const start = Date.now();
  while (Date.now() - start < maxMs) {
    await new Promise((res) => setTimeout(res, 2000));
    try {
      const r = await fetch('https://api.printnode.com/printjobs/' + jobId + '/states', {
        headers: { 'Authorization': 'Basic ' + btoa(PN_KEY + ':') },
      });
      if (r.status !== 200) continue;
      const body = await r.json();
      let events: any[] = [];
      if (Array.isArray(body)) for (const b of body) { if (Array.isArray(b)) events = events.concat(b); else events.push(b); }
      if (!events.length) continue;
      const u = events[events.length - 1];
      const estado = String(u.state || '').toLowerCase();
      const msg = String(u.message || u.data || '');
      if (estado === 'done') return { estado: 'done', outOfPaper: false, mensaje: '' };
      if (estado === 'error' || estado === 'expired') {
        const m = msg.toLowerCase();
        const oop = m.includes('paper') || m.includes('media') || m.includes('label') || m.includes('out of');
        return { estado: 'error', outOfPaper: oop, mensaje: msg };
      }
    } catch { /* seguir */ }
  }
  return { estado: 'timeout', outOfPaper: false, mensaje: 'sin confirmación' };
}

// Procesa UN lote hasta terminar / pausar / agotar presupuesto. Reserve-first atómico.
async function procesarLote(idLote: string, deadline: number, envTokens: string[][], cfg: DriftCfg, requireGapDetectFirst = false): Promise<any> {
  const g = await rpcWh('lote_adhesivo_get', { idLote });
  if (!g || g.ok === false) return { idLote, error: g?.error || 'get falló' };
  const lote = g.data;
  const printerId = parseInt(String(lote.printerId || ''), 10);
  if (!printerId) return { idLote, error: 'printerId inválido' };
  const fechaEnv = vtoStringAFechaEnvasado(String(lote.vto || ''));
  const producto = { codigoBarra: String(lote.codigoBarra || ''), descripcion: String(lote.descripcion || '') };
  let subJobs = 0, gap = requireGapDetectFirst;

  while (Date.now() < deadline) {
    const rr = await rpcWh('lote_adhesivo_reservar', { idLote });
    if (!rr || rr.ok === false) return { idLote, subJobs, error: rr?.error || 'reservar falló' };
    const d = rr.data;
    if (!d.qty || d.qty <= 0) return { idLote, subJobs, status: 'COMPLETADO' };

    const bytes = buildTSPLEtq(producto, fechaEnv, d.qty, envTokens, cfg, d.desde, gap);
    gap = false;
    const b64 = bytesToBase64(bytes);
    const pn = await printNodePost(printerId, 'Adhesivo ' + producto.codigoBarra + ' (' + d.qty + ') lote=' + idLote, b64, idLote);

    if (!pn.ok) {
      // PrintNode rechazó (no 201) → revertir el rango reservado (no se imprimió).
      await rpcWh('lote_adhesivo_marcar', { idLote, status: 'PAUSADO_ERROR', reembolsar: d.qty,
        completadasEsperado: d.completadas, ultimoError: 'PrintNode HTTP ' + pn.status + ': ' + pn.txt.substring(0, 180) });
      return { idLote, subJobs, status: 'PAUSADO_ERROR', error: 'PrintNode ' + pn.status };
    }
    subJobs++;

    // Poll corto: solo para detectar OUT_OF_PAPER (el conteo ya quedó comprometido en reservar).
    const poll = await pollJobOutOfPaper(pn.jobId!, POLL_MS);
    if (poll.estado === 'error') {
      await rpcWh('lote_adhesivo_marcar', { idLote, status: poll.outOfPaper ? 'PAUSADO_OUT_PAPER' : 'PAUSADO_ERROR',
        reembolsar: d.qty, completadasEsperado: d.completadas, ultimoPrintNodeJobId: pn.jobId, ultimoError: poll.mensaje });
      return { idLote, subJobs, status: poll.outOfPaper ? 'PAUSADO_OUT_PAPER' : 'PAUSADO_ERROR' };
    }
    // done / timeout → confirmar (el rango ya está contado; solo fijamos status + jobId).
    const mk = await rpcWh('lote_adhesivo_marcar', { idLote,
      status: d.completadas >= d.total ? 'COMPLETADO' : 'IMPRIMIENDO', ultimoPrintNodeJobId: pn.jobId });
    if (mk?.data?.status === 'COMPLETADO') return { idLote, subJobs, status: 'COMPLETADO' };
  }
  return { idLote, subJobs, status: 'PRESUPUESTO_AGOTADO' };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'metodo no permitido' }, 405);
  try {
    const auth = req.headers.get('Authorization') || '';
    const claims = jwtClaims(auth.replace(/^Bearer\s+/i, '').trim());
    const okAuth = !!claims && (APPS_OK.has(String(claims.app)) || String(claims.role) === 'service_role');
    if (!okAuth) return json({ ok: false, error: 'no autorizado (claim app/role)' }, 401);
    if (!PN_KEY) return json({ ok: false, error: 'PRINTNODE_API_KEY no configurado' }, 500);

    const body = await req.json().catch(() => ({}));
    const mode = String(body.mode || (body.idLote ? 'lote' : 'pending'));
    const deadline = Date.now() + WALL_BUDGET_MS;
    const cfg = await leerDriftCfg();
    const envTokens = await leerEnvasablesTokens();

    if (mode === 'lote') {
      const idLote = String(body.idLote || '');
      if (!idLote) return json({ ok: false, error: 'falta idLote' }, 400);
      const res = await procesarLote(idLote, deadline, envTokens, cfg, body.requireGapDetect === true);
      return json({ ok: true, data: res });
    }

    // mode 'crear' — crea el lote (RPC atómica, dedup por idempotencyKey) + imprime server-side. Lo usa MOS
    // (modal cantidad+preview): un solo viaje, no necesita llamar la RPC ni pollear directo (la Edge usa
    // service_role → pasa el gate). La cantidad EXACTA marcada = total_etq = lo que se imprime (reserve-first).
    if (mode === 'crear') {
      const total = parseInt(String(body.total || '0'), 10);
      const cod = String(body.codigoBarra || '');
      if (!cod || !(total > 0)) return json({ ok: false, error: 'falta codigoBarra/total' }, 400);
      let printerId = String(body.printerId || '');
      if (!printerId) printerId = await resolverPrinterAdhesivo();
      if (!printerId) return json({ ok: false, error: 'sin impresora ADHESIVO configurada' }, 400);
      const cr = await rpcWh('lote_adhesivo_crear', {
        codigoBarra: cod, descripcion: body.descripcion || '', total,
        vto: body.vto || '', tipoEtiqueta: body.tipoEtiqueta || 'ADHESIVO_ENVASADO',
        usuario: body.usuario || '', origen: body.origen || 'MOS',
        printerId, idempotencyKey: String(body.idempotencyKey || '')
      });
      if (!cr || cr.ok === false) return json({ ok: false, error: cr?.error || 'crear falló' }, 200);
      const idLote = cr.data && cr.data.idLote;
      if (!idLote) return json({ ok: false, error: 'sin idLote' }, 200);
      const res = await procesarLote(String(idLote), deadline, envTokens, cfg);
      return json({ ok: true, data: { idLote, total: cr.data.total, dedup: !!cr.dedup, ...res } });
    }

    // mode 'pending' — cola (pg_cron). Procesa varios lotes dentro del presupuesto.
    const pend = await rpcWh('lote_adhesivo_pendientes', { limit: parseInt(String(body.limit || '8'), 10) });
    if (!pend || pend.ok === false) return json({ ok: false, error: pend?.error || 'pendientes falló' }, 200);
    const lotes: any[] = pend.data || [];
    const resultados: any[] = [];
    for (const l of lotes) {
      if (Date.now() >= deadline) break;
      resultados.push(await procesarLote(String(l.idLote), deadline, envTokens, cfg));
    }
    return json({ ok: true, data: { procesados: resultados.length, resultados } });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
