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
const APPS_OK = new Set(['warehouseMos', 'MOS', 'mosExpress']);   // WH (envasado/reimpresión/andamio) + MOS (catálogo) + ME (góndola)
const WALL_BUDGET_MS = 140000;  // tope de ejecución por invocación (~400-500 etiquetas/tanda; cron retoma el resto)
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

// Centrado de barcode PRECISO para Code128. Los códigos NUMÉRICOS usan Code C
// (2 dígitos por símbolo) → la barra real es ~la mitad de ancho que estimar por
// carácter. calcBarcodeAdaptativo sobre-estimaba el ancho → barcodeX salía corrido
// a la IZQUIERDA en códigos largos (el número, centrado por nº de chars, sí salía
// bien). Esto estima los símbolos reales (pares para numérico) → centra de verdad.
function calcBarcodeCentrado(codigo: string) {
  const bc = String(codigo || '').replace(/"/g, '');
  const len = bc.length;
  const esNum = /^\d+$/.test(bc);
  const dataSym = esNum ? (Math.ceil(len / 2) + (len % 2)) : len;   // Code C: pares (+1 si impar)
  const modules = 11 * dataSym + 35;                                // start+data+check+stop
  let narrowBc: number, quiet: number;
  if (modules * 3 <= 340) { narrowBc = 3; quiet = 24; }
  else if (modules * 2 <= 376) { narrowBc = 2; quiet = 12; }
  else { narrowBc = 2; quiet = 8; }
  const width = modules * narrowBc;
  const barcodeX = Math.max(quiet, Math.floor((400 - width) / 2));
  return { bc, narrowBc, barcodeHeight: 56, barcodeX };
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
    // [margen derecho 1.5mm] Vto corrido 12 dots a la izquierda (232→220) para que el
    // año no quede pegado al borde derecho del adhesivo (400 dots = 50mm). 12 dots = 1.5mm.
    bytes = bytes.concat(strToBytes('TEXT 220,' + (12 + offsetY) + ',"2",0,1,1,"Vto ' + vto + '"\r\n'));
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

// ════════════════ TSPL2 MEMBRETES — port fiel de gas/Membretes.gs ════════════════
// Logo andamio WH (el membrete góndola ME NO lleva logo). Port exacto.
const LOGO_ALMACEN_WH_HEX =
'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' +
'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC00' +
'7E03F801C007C007FF01FF000703C07FFFE0020007FC007E03F801C007C007FC007F000701C0' +
'7FFFA0020007F8007E03F801C0078007F8001F000701C07FFF20020007F8003E03F801C00780' +
'03F0000F000701C07FFE20020007F8003E03F801C0078003E0000F000700C07FFC20020007F8' +
'003E03F800C0078003E0180F000700C07FF820020007F8003E03F800C0078003E0380701FF00' +
'C07FF0203E0007F8003E03F800C0078003C0380701FF00407FF0203E0007F8103E03F8008007' +
'8103C0380701FF00407FF0203E0007F0103E03F80080070103C0380701FF00407FF0203E0007' +
'F0101E03F80080070101C0380701FF00407FF0203E0007F0101E03F80080070101C03807000F' +
'00007FF0203E0007F0101E03F80000070101C03807000F00007FF0203E0007F0101E03F81004' +
'070101C03FFF000F00007FF0203E0007F0101E03F81004070101C03FFF000F00007FF0203E00' +
'07F0101E03F81004070101C03FFF000F00007FF0203E0007F0180E03F81004070180C03FFF00' +
'0F00007FFFFFFFFFFFE0380E03F81004060380C0380701FF00007FFFFFFFFFFFE0380E03F818' +
'04060380C0380701FF02007FFFFFFFFFFFE0380E03F81804060380C0380701FF02007FFFFFFF' +
'FFFFE0000E03F8180C060000C0380701FF02007FFFFFFFFFFFE0000E03F8180C060000C03807' +
'01FF03007FF0203E0007E0000E03F8180C060000C0380701FF03007FF0203E0007E0000603F8' +
'180C06000060380F01FF03007FF0203E0007E000060018180C06000060180F000703807FF020' +
'3E0007C0380600181C0C04038060000F000703807FF0203E0007C0380600181C0C0403807000' +
'1F000703807FF0203E0007C0380600181C1C04038070003F000703807FF0203E0007C0380600' +
'181C1C0403807C007F000703C07FF0203E0007C0380600181C1C0403807F01FF000703C07FF0' +
'203E0007FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0203E0007FFFFFFFFFFFFFFFFFFFFFF' +
'FFFFFFFFFFFFFFF0203E0007FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF';

// offsetY de drift por etiqueta absoluta (idx = posición en el rollo). clamp [-1,16] (=2mm).
function driftOffset(cfg: DriftCfg, idx: number): number {
  let off = cfg.offsetBase + Math.round(cfg.driftDots * (cfg.printsBase + idx));
  if (off < -1) off = -1;
  if (off > 16) off = 16;
  return off;
}

// Word-wrap simple a un ancho de dots dado (charW = ancho por carácter de la fuente).
function wrapEnAncho(text: string, maxW: number, charW: number): string[] {
  const words = String(text || '').split(/\s+/).filter(Boolean);
  const lines: string[] = []; let cur = '';
  for (const w of words) {
    const test = cur ? cur + ' ' + w : w;
    if (!cur || test.length * charW <= maxW) cur = test;
    else { lines.push(cur); cur = w; }
  }
  if (cur) lines.push(cur);
  return lines.length ? lines : [''];
}

// MEMBRETE GÓNDOLA (ME) — rediseño: nombre IZQUIERDA (auto-fit 1-3 líneas, centrado V+H),
// precio DERECHA focalizado (soles grande + céntimos chico elevado) en recuadro, medida
// auto (c/u · /kg), barcode full-width + alto, márgenes sup/inf. Todo centrado en su zona.
function buildTSPLMembreteMe(producto: any, _allEnvTokens: string[][], cfg: DriftCfg, offsetY: number): number[] {
  const header = ['SIZE 50 mm,25 mm','GAP ' + cfg.gapMm + ' mm,0 mm','DIRECTION 1','DENSITY ' + cfg.density,'SPEED ' + cfg.speed,'CLS'].join('\r\n') + '\r\n';
  let bytes = strToBytes(header);
  const TOP = 14 + offsetY, TOPZONE_H = 92;     // zona superior (nombre | precio)

  // ── NOMBRE (zona izquierda X12..208 · margen al divisor en X232) ──
  // Fuente adaptativa con MÁS líneas para la fuente chica antes de achicar: así un
  // nombre largo (ej. AJINOMOTO SAZONADOR GLUTAMATO 500GR BOLSA) usa Font 2 en ~4
  // líneas (legible) en vez de caer a Font 1 diminuta. NAME_W=196 deja ~24px (3mm)
  // antes del divisor → el nombre NUNCA toca la línea del medio.
  const NAME_X0 = 12, NAME_W = 196;
  const nombre = normalizeEtq(producto.descripcion || '');
  const fonts = [{ f: '3', cw: 16, lh: 26, max: 3 }, { f: '2', cw: 12, lh: 22, max: 4 }, { f: '1', cw: 8, lh: 14, max: 5 }];
  let chosen = fonts[2], nameLines: string[] = [];
  for (const ft of fonts) { const ls = wrapEnAncho(nombre, NAME_W, ft.cw); chosen = ft; nameLines = ls; if (ls.length <= ft.max) break; }
  if (nameLines.length > 5) nameLines = nameLines.slice(0, 5);
  let nameY = TOP + Math.max(0, Math.floor((TOPZONE_H - nameLines.length * chosen.lh) / 2));   // centrado V
  for (const ln of nameLines) {
    const w = ln.length * chosen.cw;
    const x = NAME_X0 + Math.max(0, Math.floor((NAME_W - w) / 2));                              // centrado H
    bytes = bytes.concat(strToBytes('TEXT ' + x + ',' + nameY + ',"' + chosen.f + '",0,1,1,"' + ln.replace(/"/g, "'") + '"\r\n'));
    nameY += chosen.lh;
  }

  // ── Divisor sutil ──
  bytes = bytes.concat(strToBytes('BAR 232,' + (TOP + 4) + ',2,' + (TOPZONE_H - 12) + '\r\n'));

  // ── PRECIO focalizado (zona derecha X240..388) centrado V+H, en recuadro · SIN medida ──
  // Quitada la medida (c/u · /kg): se sobreentiende → todo el cajón es para el precio.
  const precioNum = parseFloat(producto.precio) || 0;
  const ent = Math.floor(precioNum).toString();
  const cen = Math.round((precioNum - Math.floor(precioNum)) * 100).toString().padStart(2, '0');
  const RZ_X0 = 240, RZ_W = 148;
  const wSoles = 2 * 12, wEnt = ent.length * 24, wCen = 2 * 12;
  const rowW = wSoles + 3 + wEnt + 2 + wCen;
  const rowX = RZ_X0 + Math.max(4, Math.floor((RZ_W - rowW) / 2));
  const intY = TOP + Math.floor((TOPZONE_H - 32) / 2);            // centrado V (bloque ~32, sin medida)
  bytes = bytes.concat(strToBytes('TEXT ' + rowX + ',' + (intY + 10) + ',"2",0,1,1,"S/"\r\n'));
  bytes = bytes.concat(strToBytes('TEXT ' + (rowX + wSoles + 3) + ',' + intY + ',"4",0,1,1,"' + ent + '"\r\n'));
  bytes = bytes.concat(strToBytes('TEXT ' + (rowX + wSoles + 3 + wEnt + 2) + ',' + intY + ',"2",0,1,1,"' + cen + '"\r\n'));  // céntimos elevado
  const bx1 = RZ_X0, bx2 = 389, by1 = intY - 14, by2 = intY + 46;
  bytes = bytes.concat(strToBytes('BAR ' + bx1 + ',' + by1 + ',' + (bx2 - bx1) + ',2\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + bx1 + ',' + by2 + ',' + (bx2 - bx1) + ',2\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + bx1 + ',' + by1 + ',2,' + (by2 - by1) + '\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + (bx2 - 2) + ',' + by1 + ',2,' + (by2 - by1) + '\r\n'));

  // ── BARCODE IZQUIERDA (ancho capado) + código + [⧉/▫ tipo-código][ME] a la DERECHA ──
  let codigo = String((producto.esSkuBase ? producto.skuBase : producto.codigoBarra) || producto.codigoBarra || producto.skuBase || producto.codigo || producto.idProducto || '').replace(/"/g, '');
  if (!codigo) codigo = 'SIN-CODIGO';
  // Ancho del barcode CAPADO (Code C para numéricos) → deja lugar fijo a [cuadritos][ME] a la derecha.
  const esNum = /^\d+$/.test(codigo);
  const mods = ((esNum ? (Math.ceil(codigo.length / 2) + (codigo.length % 2)) : codigo.length) * 11) + 35;
  const nb = (mods * 2 <= 288) ? 2 : 1;
  const bcH = 56, bcX = 12;
  const bcY = TOP + TOPZONE_H + 4;
  bytes = bytes.concat(strToBytes('BARCODE ' + bcX + ',' + bcY + ',"128",' + bcH + ',0,0,' + nb + ',' + nb + ',"' + codigo + '"\r\n'));
  bytes = bytes.concat(strToBytes('TEXT ' + bcX + ',' + (bcY + bcH + 4) + ',"1",0,1,1,"' + codigo + '"\r\n'));
  // Indicador de TIPO de código que ACOMPAÑA al "ME": 2 cuadritos = multi-código
  // (canónico+equivalentes, imprime el skuBase) · 1 cuadrito = código único. Posición fija → siempre entra.
  const sq = (x: number, y: number, s: number) => {
    bytes = bytes.concat(strToBytes('BAR ' + x + ',' + y + ',' + s + ',2\r\n'));
    bytes = bytes.concat(strToBytes('BAR ' + x + ',' + (y + s - 2) + ',' + s + ',2\r\n'));
    bytes = bytes.concat(strToBytes('BAR ' + x + ',' + y + ',2,' + s + '\r\n'));
    bytes = bytes.concat(strToBytes('BAR ' + (x + s - 2) + ',' + y + ',2,' + s + '\r\n'));
  };
  const indX = 300, indY = bcY + 14;
  if (producto.esSkuBase) { sq(indX, indY + 6, 14); sq(indX + 8, indY, 14); }   // ⧉ dos cuadritos (multi)
  else { sq(indX + 4, indY + 3, 14); }                                          // un cuadrito (único)
  // "ME" sin caja, a la derecha del indicador (Font 4)
  bytes = bytes.concat(strToBytes('TEXT 338,' + (bcY + 14) + ',"4",0,1,1,"ME"\r\n'));
  bytes = bytes.concat(strToBytes('PRINT 1,1\r\n'));
  return bytes;
}

// ── Peso inteligente: gramos enteros si <1kg, kilos sin ceros sobrantes si >=1kg ──
function pesoBonitoG(kg: number): { num: string; unit: string } {
  const g = Math.round((Number(kg) || 0) * 1000);
  if (g < 1000) return { num: String(g), unit: 'g' };
  // [fix overflow] kg con 1 decimal (en el adhesivo no hace falta más precisión) → el número nunca se sale
  // del recuadro de peso. "12.345"→"12.3", "100.0"→"100", "5.5"→"5.5".
  return { num: (g / 1000).toFixed(1).replace(/\.0$/, ''), unit: 'kg' };
}
// ── Fecha+hora de Lima en ASCII: "25/06/2026  02:18pm" ──
function fechaHoraLimaAscii(): string {
  try {
    const parts = new Intl.DateTimeFormat('en-GB', {
      timeZone: 'America/Lima', day: '2-digit', month: '2-digit', year: '2-digit',
      hour: '2-digit', minute: '2-digit', hour12: true,
    }).formatToParts(new Date());
    const g = (t: string) => (parts.find((x) => x.type === t)?.value || '');
    const ap = (g('dayPeriod') || '').toLowerCase().replace(/[^a-z]/g, '');
    return g('day') + '/' + g('month') + '/' + g('year') + '  ' + g('hour') + ':' + g('minute') + ap;
  } catch { return ''; }
}

// ADHESIVO GRANEL DESPACHO (WH): para pegar en el saco al despachar un granel. 50×25mm.
//   · NOMBRE izquierda (auto-fit Font 3→1, word-wrap por palabras, NO parte palabras)
//   · PESO grande derecha (inteligente kg/g) en recuadro — reemplaza al precio del membrete
//   · BARCODE Code128 + código abajo-izq (escaneable en recepción)
//   · BADGE caja/bulto + "WH" abajo-derecha + FECHA/HORA de emisión
// item = { nombre|descripcion, codigo|codigoBarra, peso|cantidad(kg) }
function buildTSPLGranelDespacho(item: any, cfg: DriftCfg, offsetY: number): number[] {
  const header = ['SIZE 50 mm,25 mm', 'GAP ' + cfg.gapMm + ' mm,0 mm', 'DIRECTION 1', 'DENSITY ' + cfg.density, 'SPEED ' + cfg.speed, 'CLS'].join('\r\n') + '\r\n';
  let bytes = strToBytes(header);
  const TOP = 14 + offsetY, TOPZONE_H = 92;

  // ── NOMBRE (zona izquierda X12..208) auto-fit + word-wrap (wrapEnAncho corta por espacios, no parte palabras) ──
  const NAME_X0 = 12, NAME_W = 196;
  const nombre = normalizeEtq(item.nombre || item.descripcion || item.codigo || '');
  const fonts = [{ f: '3', cw: 16, lh: 26, max: 3 }, { f: '2', cw: 12, lh: 22, max: 4 }, { f: '1', cw: 8, lh: 14, max: 5 }];
  let chosen = fonts[2], nameLines: string[] = [];
  for (const ft of fonts) { const ls = wrapEnAncho(nombre, NAME_W, ft.cw); chosen = ft; nameLines = ls; if (ls.length <= ft.max) break; }
  if (nameLines.length > 5) nameLines = nameLines.slice(0, 5);
  let nameY = TOP + Math.max(0, Math.floor((TOPZONE_H - nameLines.length * chosen.lh) / 2));
  for (const ln of nameLines) {
    const w = ln.length * chosen.cw;
    const x = NAME_X0 + Math.max(0, Math.floor((NAME_W - w) / 2));
    bytes = bytes.concat(strToBytes('TEXT ' + x + ',' + nameY + ',"' + chosen.f + '",0,1,1,"' + ln.replace(/"/g, "'") + '"\r\n'));
    nameY += chosen.lh;
  }

  // ── Divisor vertical ──
  bytes = bytes.concat(strToBytes('BAR 232,' + (TOP + 4) + ',2,' + (TOPZONE_H - 12) + '\r\n'));

  // ── PESO (zona derecha X240..388) en recuadro: label "PESO" + número grande (Font 4) + unidad (Font 2) ──
  const peso = pesoBonitoG(Number(item.peso ?? item.cantidad ?? 0));
  const RZ_X0 = 240, RZ_W = 148;
  const lblW = 4 * 12;
  bytes = bytes.concat(strToBytes('TEXT ' + (RZ_X0 + Math.floor((RZ_W - lblW) / 2)) + ',' + (TOP + 8) + ',"2",0,1,1,"PESO"\r\n'));
  const wNum = peso.num.length * 24, wUni = peso.unit.length * 12;
  const rowW = wNum + 4 + wUni;
  const rowX = RZ_X0 + Math.max(2, Math.floor((RZ_W - rowW) / 2));
  const numY = TOP + 38;
  bytes = bytes.concat(strToBytes('TEXT ' + rowX + ',' + numY + ',"4",0,1,1,"' + peso.num + '"\r\n'));
  bytes = bytes.concat(strToBytes('TEXT ' + (rowX + wNum + 4) + ',' + (numY + 12) + ',"2",0,1,1,"' + peso.unit + '"\r\n'));
  const bx1 = RZ_X0, bx2 = 389, by1 = TOP + 2, by2 = TOP + TOPZONE_H - 4;
  bytes = bytes.concat(strToBytes('BAR ' + bx1 + ',' + by1 + ',' + (bx2 - bx1) + ',2\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + bx1 + ',' + by2 + ',' + (bx2 - bx1) + ',2\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + bx1 + ',' + by1 + ',2,' + (by2 - by1) + '\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + (bx2 - 2) + ',' + by1 + ',2,' + (by2 - by1) + '\r\n'));

  // ── BARCODE (abajo-izq) + código en texto ──
  let codigo = String(item.codigo || item.codigoBarra || '').replace(/"/g, '');
  if (!codigo) codigo = 'SIN-CODIGO';
  const esNum = /^\d+$/.test(codigo);
  const mods = ((esNum ? (Math.ceil(codigo.length / 2) + (codigo.length % 2)) : codigo.length) * 11) + 35;
  const nb = (mods * 2 <= 240) ? 2 : 1;   // cap de ancho: deja lugar al badge WH a la derecha
  const bcH = 50, bcX = 12;
  const bcY = TOP + TOPZONE_H + 6;
  bytes = bytes.concat(strToBytes('BARCODE ' + bcX + ',' + bcY + ',"128",' + bcH + ',0,0,' + nb + ',' + nb + ',"' + codigo + '"\r\n'));
  bytes = bytes.concat(strToBytes('TEXT ' + bcX + ',' + (bcY + bcH + 4) + ',"1",0,1,1,"' + codigo + '"\r\n'));

  // ── BADGE caja/bulto + "WH" (abajo-derecha) ──
  const wx = 306, wy = bcY + 2, ww = 56, wbh = 30;
  bytes = bytes.concat(strToBytes('BAR ' + wx + ',' + wy + ',' + ww + ',2\r\n'));                    // techo
  bytes = bytes.concat(strToBytes('BAR ' + wx + ',' + (wy + wbh - 2) + ',' + ww + ',2\r\n'));        // piso
  bytes = bytes.concat(strToBytes('BAR ' + wx + ',' + wy + ',2,' + wbh + '\r\n'));                   // izq
  bytes = bytes.concat(strToBytes('BAR ' + (wx + ww - 2) + ',' + wy + ',2,' + wbh + '\r\n'));        // der
  bytes = bytes.concat(strToBytes('BAR ' + wx + ',' + (wy + 9) + ',' + ww + ',2\r\n'));              // línea tapa
  bytes = bytes.concat(strToBytes('BAR ' + (wx + Math.floor(ww / 2) - 1) + ',' + wy + ',2,9\r\n'));  // solapa central
  bytes = bytes.concat(strToBytes('TEXT ' + (wx + 14) + ',' + (wy + 14) + ',"2",0,1,1,"WH"\r\n'));   // "WH"

  // ── FECHA/HORA de emisión (abajo-IZQ, bajo el código) ──
  // [fix overflow] antes iba abajo-derecha y "25/06/2026 02:18pm" (19 chars) se salía del borde (x≈452>400).
  // Ahora va bajo el código (x=12) con año de 2 dígitos → entra cómodo.
  const fh = fechaHoraLimaAscii();
  if (fh) bytes = bytes.concat(strToBytes('TEXT ' + bcX + ',' + (bcY + bcH + 22) + ',"1",0,1,1,"' + fh + '"\r\n'));

  bytes = bytes.concat(strToBytes('PRINT 1,1\r\n'));
  return bytes;
}

// MEMBRETE ANDAMIO (WH): logo WH + tag CAB/i/total + desc + barcode (layout = adhesivo). Port de _buildTSPLMembreteWh.
function buildTSPLMembreteWh(producto: any, esCabecera: boolean, indice: number, total: number, allEnvTokens: string[][], cfg: DriftCfg, offsetY: number): number[] {
  const descNorm = normalizeEtq(producto.descripcion || '');
  const tokens = descNorm.split(/\s+/);
  const highlights = detectHighlightsEtq(tokens, allEnvTokens);
  const lines = wrapTokensEtq(tokens, highlights);
  const header = ['SIZE 50 mm,25 mm','GAP ' + cfg.gapMm + ' mm,0 mm','DIRECTION 1','DENSITY ' + cfg.density,'SPEED ' + cfg.speed,'CLS','BITMAP 5,' + (8 + offsetY) + ',' + LOGO_W_BYTES + ',' + LOGO_H + ',0,'].join('\r\n');
  let bytes = strToBytes(header);
  bytes = bytes.concat(hexToBytes(LOGO_ALMACEN_WH_HEX));
  bytes = bytes.concat(strToBytes('\r\n'));
  if (total > 1) {
    const tagTexto = esCabecera ? 'CAB' : (indice + '/' + total);
    // [margen derecho 1.5mm] -20 dots (antes -8) → el CAB no queda pegado al borde.
    const tagX = 400 - tagTexto.length * 8 - 20;
    bytes = bytes.concat(strToBytes('TEXT ' + tagX + ',' + (10 + offsetY) + ',"2",0,1,1,"' + tagTexto + '"\r\n'));
  }
  const DESC_AREA_Y0 = 46, DESC_AREA_H = 72, LINE_H = 38, SPACE = 8;
  let startY: number;
  if (lines.length === 1) {
    const lineHasHl = lines[0].some((t) => t.hl);
    const lineHeight = lineHasHl ? 32 : 24, baselineOffset = lineHasHl ? 0 : 4;
    startY = DESC_AREA_Y0 + Math.floor((DESC_AREA_H - lineHeight) / 2) - baselineOffset + offsetY;
  } else { startY = DESC_AREA_Y0 + offsetY; }
  for (let li = 0; li < Math.min(lines.length, 2); li++) {
    const line = lines[li]; let totalW = 0;
    for (let ti = 0; ti < line.length; ti++) totalW += line[ti].w + (ti > 0 ? SPACE : 0);
    let x = Math.max(5, Math.round((400 - totalW) / 2)); const y = startY + li * LINE_H;
    for (let tj = 0; tj < line.length; tj++) {
      const o = line[tj]; const font = o.hl ? '4' : '3'; const yAdj = o.hl ? y : y + 4;
      const safe = String(o.tok).replace(/"/g, "'");
      bytes = bytes.concat(strToBytes('TEXT ' + x + ',' + yAdj + ',"' + font + '",0,1,1,"' + safe + '"\r\n')); x += o.w + SPACE;
    }
  }
  let codigo = String(producto.codigo || producto.codigoBarra || producto.skuBase || producto.idProducto || '').replace(/"/g, '');
  if (!codigo) codigo = 'SIN-CODIGO';
  const _bc = calcBarcodeCentrado(codigo);
  const bcH = 56;   // barcode más alto (~7mm) = escanea mejor
  const frameX1 = 10, frameX2 = 389, cmL = 12;
  const barcodeY = 114 + offsetY, frameY1 = 108 + offsetY, frameY2 = 188 + offsetY;
  bytes = bytes.concat(strToBytes('BAR ' + frameX1 + ',' + frameY1 + ',' + cmL + ',1\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + frameX1 + ',' + frameY1 + ',1,' + cmL + '\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + (frameX2 - cmL + 1) + ',' + frameY1 + ',' + cmL + ',1\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + frameX2 + ',' + frameY1 + ',1,' + cmL + '\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + frameX1 + ',' + frameY2 + ',' + cmL + ',1\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + frameX1 + ',' + (frameY2 - cmL + 1) + ',1,' + cmL + '\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + (frameX2 - cmL + 1) + ',' + frameY2 + ',' + cmL + ',1\r\n'));
  bytes = bytes.concat(strToBytes('BAR ' + frameX2 + ',' + (frameY2 - cmL + 1) + ',1,' + cmL + '\r\n'));
  bytes = bytes.concat(strToBytes('BARCODE ' + _bc.barcodeX + ',' + barcodeY + ',"128",' + bcH + ',0,0,' + _bc.narrowBc + ',' + _bc.narrowBc + ',"' + codigo + '"\r\n'));
  const codigoX = Math.max(frameX1 + 4, Math.floor((400 - codigo.length * 8) / 2));
  bytes = bytes.concat(strToBytes('TEXT ' + codigoX + ',' + (barcodeY + bcH + 4) + ',"1",0,1,1,"' + codigo + '"\r\n'));
  bytes = bytes.concat(strToBytes('PRINT 1,1\r\n'));
  return bytes;
}

// Expande items crudos a la lista de etiquetas (port de crearLoteMembrete). ME: 1/producto. WH: cabecera + códigos.
function expandirMembrete(tipo: string, items: any[]): any[] {
  const out: any[] = [];
  (items || []).forEach((item) => {
    if (tipo === 'MEMBRETE_ME') {
      out.push({ codigo: String(item.codigoBarra || ''), codigoBarra: String(item.codigoBarra || ''), descripcion: String(item.descripcion || ''),
        precio: parseFloat(item.precio) || 0, unidad: String(item.unidad || item.unidadMedida || ''),
        skuBase: String(item.skuBase || ''), esSkuBase: !!item.esSkuBase, esCabecera: false });
    } else {
      const codigos = (Array.isArray(item.codigos) && item.codigos.length > 0) ? item.codigos : (item.codigoBarra ? [item.codigoBarra] : []);
      if (codigos.length === 0) return;
      if (codigos.length > 1 && item.skuBase) {
        out.push({ codigo: String(item.skuBase), descripcion: String(item.descripcion || ''), skuBase: String(item.skuBase || ''), esCabecera: true });
      }
      codigos.forEach((c: any) => out.push({ codigo: String(c), descripcion: String(item.descripcion || ''), skuBase: String(item.skuBase || ''), esCabecera: false }));
    }
  });
  return out;
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
// Upsert best-effort de claves en mos.config (usado por el reset de calibración). Las claves ADHESIVO_* ya existen.
async function setConfigMos(kv: Record<string, string>): Promise<void> {
  try {
    // [FIX 393] UPSERT (no PATCH): claves como ADHESIVO_ROLLO_CALIBRADO/FECHA_CALIBRADO no están sembradas →
    // un PATCH afectaría 0 filas y se perdería la escritura. merge-duplicates inserta o actualiza.
    const rows = Object.entries(kv).map(([clave, valor]) => ({ clave, valor }));
    if (!rows.length) return;
    await fetch(`${SB_URL}/rest/v1/config`, {
      method: 'POST',
      headers: { 'apikey': SB_KEY!, 'Authorization': 'Bearer ' + SB_KEY!, 'Accept-Profile': 'mos', 'Content-Profile': 'mos', 'Content-Type': 'application/json', 'Prefer': 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify(rows) });
  } catch { /* best-effort */ }
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

// buildTSPLCalibrador — port fiel de gas/Envasados.gs `_buildTSPLCalibrador`. Regla vertical (mm) +
// caja "CAL #N/T" para que el operador mida el desvío del rollo. SIN compensación de drift (es la
// referencia). Devuelve el TSPL como string ASCII (luego → base64). numero/total = índice del calibrador.
function buildTSPLCalibrador(numero: number, total: number, cfg: DriftCfg): string {
  let t = ['SIZE 50 mm,25 mm', 'GAP ' + cfg.gapMm + ' mm,0 mm', 'DIRECTION 1', 'DENSITY ' + cfg.density, 'SPEED ' + cfg.speed, 'CLS'].join('\r\n') + '\r\n';
  // Reglas verticales (IZQ X=0..8, DER X=392..400). 1mm = 8 dots, alto 25mm = 200 dots.
  for (let mm = 0; mm <= 25; mm++) {
    const y = 2 + mm * 8;
    if (y > 198) break;
    const ancho = (mm % 10 === 0) ? 12 : (mm % 5 === 0) ? 8 : 4;
    t += 'BAR 0,' + y + ',' + ancho + ',1\r\n';
    t += 'BAR ' + (400 - ancho) + ',' + y + ',' + ancho + ',1\r\n';
    if (mm % 5 === 0 && mm > 0 && mm < 25) {
      t += 'TEXT 14,' + (y - 4) + ',"1",0,1,1,"' + mm + '"\r\n';
      t += 'TEXT 370,' + (y - 4) + ',"1",0,1,1,"' + mm + '"\r\n';
    }
  }
  // Indicador "0mm" en tope y final (caja negra + hueco blanco).
  t += 'BAR 30,2,20,12\r\n' + 'BAR 32,4,16,8\r\n' + 'TEXT 33,5,"1",0,1,1,"0mm"\r\n';
  t += 'BAR 350,2,32,12\r\n' + 'BAR 352,4,28,8\r\n' + 'TEXT 353,5,"1",0,1,1,"0mm"\r\n';
  // Caja central "CAL #N/T".
  const label = 'CAL #' + numero + '/' + total;
  const labelX = Math.floor((400 - label.length * 16) / 2);
  t += 'TEXT ' + labelX + ',88,"3",0,1,1,"' + label + '"\r\n';
  const sub = 'mide el desvio mm';
  const subX = Math.floor((400 - sub.length * 8) / 2);
  t += 'TEXT ' + subX + ',120,"1",0,1,1,"' + sub + '"\r\n';
  t += 'TEXT 180,150,"3",0,1,1,"v"\r\n';
  t += 'PRINT 1,1\r\n';
  return t;
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
  const tipo = String(lote.tipoEtiqueta || 'ADHESIVO_ENVASADO').toUpperCase();
  // items del membrete (jsonb → ya viene como array en la respuesta; tolera string).
  const items = Array.isArray(lote.itemsJson) ? lote.itemsJson
    : (typeof lote.itemsJson === 'string' && lote.itemsJson ? (() => { try { return JSON.parse(lote.itemsJson); } catch { return []; } })() : []);
  let subJobs = 0, gap = requireGapDetectFirst;

  while (Date.now() < deadline) {
    const rr = await rpcWh('lote_adhesivo_reservar', { idLote });
    if (!rr || rr.ok === false) return { idLote, subJobs, error: rr?.error || 'reservar falló' };
    const d = rr.data;
    if (!d.qty || d.qty <= 0) return { idLote, subJobs, status: 'COMPLETADO' };

    // [FIX 2026-07-04] TODO el sub-job (build + base64 + PrintNode + poll + marcar) va en try/catch. Si LANZA
    // (build pesado que cuelga, red a PrintNode, timeout del Edge) ANTES de que PrintNode ACEPTE el job, se
    // REEMBOLSA el rango que `reservar` ya había comprometido → `completadas` no cuenta etiquetas fantasma y el
    // lote NUNCA se marca COMPLETADO en falso (el operador necesita TODAS). Reintentable (queda PAUSADO_ERROR).
    let printedOk = false;
    try {
      // ADHESIVO_ENVASADO = qty copias del mismo. MEMBRETE_* = items[d.desde..d.hasta), cada uno distinto.
      let bytes: number[];
      if (tipo === 'ADHESIVO_ENVASADO') {
        bytes = buildTSPLEtq(producto, fechaEnv, d.qty, envTokens, cfg, d.desde, gap);
      } else {
        bytes = gap ? strToBytes('GAPDETECT\r\n') : [];
        for (let k = 0; k < d.qty; k++) {
          const idx = d.desde + k; const it = items[idx];
          if (!it) continue;
          const off = driftOffset(cfg, idx);
          bytes = (tipo === 'MEMBRETE_ME')
            ? bytes.concat(buildTSPLMembreteMe(it, envTokens, cfg, off))
            : bytes.concat(buildTSPLMembreteWh(it, !!it.esCabecera, idx + 1, items.length, envTokens, cfg, off));
        }
      }
      gap = false;
      const b64 = bytesToBase64(bytes);
      const pn = await printNodePost(printerId, tipo + ' (' + d.qty + ') lote=' + idLote, b64, idLote);

      if (!pn.ok) {
        // PrintNode rechazó (no 201) → revertir el rango reservado (no se imprimió).
        await rpcWh('lote_adhesivo_marcar', { idLote, status: 'PAUSADO_ERROR', reembolsar: d.qty,
          completadasEsperado: d.completadas, ultimoError: 'PrintNode HTTP ' + pn.status + ': ' + pn.txt.substring(0, 180) });
        return { idLote, subJobs, status: 'PAUSADO_ERROR', error: 'PrintNode ' + pn.status };
      }
      printedOk = true;   // PrintNode ACEPTÓ el job → las etiquetas salen; a partir de aquí NO se reembolsa
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
    } catch (ex) {
      const msg = String((ex as any)?.message || ex).substring(0, 160);
      // Reembolsar SOLO si la excepción fue ANTES de que PrintNode aceptara (no se imprimió). Si fue después
      // (poll/marcar lanzaron), el label YA salió → NO reembolsar (no descontar algo impreso); solo marcar estado.
      await rpcWh('lote_adhesivo_marcar', printedOk
        ? { idLote, status: 'PAUSADO_ERROR', ultimoError: 'post-print: ' + msg }
        : { idLote, status: 'PAUSADO_ERROR', reembolsar: d.qty, completadasEsperado: d.completadas, ultimoError: 'sub-job: ' + msg }
      ).catch(() => {});
      return { idLote, subJobs, status: 'PAUSADO_ERROR', error: 'excepcion' };
    }
  }
  return { idLote, subJobs, status: 'PRESUPUESTO_AGOTADO' };
}

// ════════════════ Ticket de picking 80mm — pickup acumulado por zona ════════════════
function _ascii(s: string): string {
  return String(s == null ? '' : s).normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^\x20-\x7e]/g, ' ');
}
async function leerTicketPrinterId(): Promise<string> {
  try {
    const r = await fetch(`${SB_URL}/rest/v1/config?select=valor&clave=eq.WH_TICKET_PRINTER_ID`, {
      headers: { 'apikey': SB_KEY!, 'Authorization': 'Bearer ' + SB_KEY!, 'Accept-Profile': 'mos' } });
    if (!r.ok) return '';
    const rows = await r.json();
    return (rows && rows.length) ? String(rows[0].valor || '') : '';
  } catch { return ''; }
}
async function leerPickup(idp: string): Promise<any> {
  try {
    const r = await fetch(`${SB_URL}/rest/v1/pickups?select=id_pickup,id_zona,items,notas,estado,fuente&id_pickup=eq.${encodeURIComponent(idp)}&limit=1`, {
      headers: { 'apikey': SB_KEY!, 'Authorization': 'Bearer ' + SB_KEY!, 'Accept-Profile': 'wh' } });
    if (!r.ok) return null;
    const rows = await r.json();
    return (rows && rows.length) ? rows[0] : null;
  } catch { return null; }
}
async function marcarPickupImpreso(idp: string, notas: string): Promise<void> {
  try {
    await fetch(`${SB_URL}/rest/v1/pickups?id_pickup=eq.${encodeURIComponent(idp)}`, {
      method: 'PATCH',
      headers: { 'apikey': SB_KEY!, 'Authorization': 'Bearer ' + SB_KEY!, 'Accept-Profile': 'wh', 'Content-Profile': 'wh', 'Content-Type': 'application/json', 'Prefer': 'return=minimal' },
      body: JSON.stringify({ notas }) });
  } catch { /* best-effort */ }
}
function buildPickingTicketB64(pickup: any): { b64: string; lineas: number; unidades: number } {
  const ESC = '\x1b', GS = '\x1d';
  const zona = _ascii(pickup.id_zona || 'SIN ZONA');
  let items: any[] = [];
  try { items = Array.isArray(pickup.items) ? pickup.items : JSON.parse(pickup.items || '[]'); } catch { items = []; }
  const pend = items.map((it: any) => ({
    nombre: _ascii(it.nombre || it.skuBase || ''),
    cant: Math.max(0, (parseFloat(it.solicitado) || 0) - (parseFloat(it.despachado) || 0)),
  })).filter((x: any) => x.cant > 0);
  let t = '';
  t += ESC + '@';
  t += ESC + '\x61\x01' + ESC + '\x21\x30' + 'ALMACEN\n' + ESC + '\x21\x00';
  t += 'Picking acumulado semanal\n';
  t += '================================\n';
  t += ESC + '\x61\x00';
  t += 'Zona: ' + zona + '\n';
  t += 'Pendiente de despachar:\n';
  t += '--------------------------------\n';
  let uds = 0;
  for (const p of pend) {
    const c = String(p.cant);
    const nm = p.nombre.substring(0, 26);
    const dots = Math.max(1, 30 - nm.length - c.length);
    t += nm + '.'.repeat(dots) + c + '\n';
    uds += p.cant;
  }
  t += '--------------------------------\n';
  t += 'Productos: ' + pend.length + '   Unidades: ' + uds + '\n';
  t += '================================\n';
  t += ESC + '\x61\x01' + 'Lo NO despachado de la semana\n' + '\n\n\n';
  t += GS + '\x56\x00';
  let bin = '';
  for (let i = 0; i < t.length; i++) bin += String.fromCharCode(t.charCodeAt(i) & 0xff);
  return { b64: btoa(bin), lineas: pend.length, unidades: uds };
}

// [góndola multi-código SERVER-AUTHORITATIVE] Marca esSkuBase=true en los items cuyo
// skuBase tiene ≥1 equivalente ACTIVO en mos.equivalencias (fuente de verdad). Así el
// canónico imprime el skuBase + ⧉ AUNQUE el catálogo de ME esté incompleto. Fail-soft:
// si la consulta falla, deja esSkuBase como vino del cliente (no rompe la impresión).
async function marcarCanonicosME(items: any[]): Promise<void> {
  try {
    if (!SB_URL || !SB_KEY) return;
    const skus = Array.from(new Set(items.map((i) => String(i.skuBase || '').trim()).filter(Boolean)));
    if (!skus.length) return;
    const r = await fetch(`${SB_URL}/rest/v1/equivalencias?select=sku_base&activo=eq.true&sku_base=in.(${skus.map(encodeURIComponent).join(',')})`, {
      headers: { 'apikey': SB_KEY, 'Authorization': 'Bearer ' + SB_KEY, 'Accept-Profile': 'mos' },
    });
    if (!r.ok) return;
    const rows = await r.json();
    const conEquiv = new Set((rows || []).map((x: any) => String(x.sku_base)));
    for (const it of items) if (conEquiv.has(String(it.skuBase || ''))) it.esSkuBase = true;
  } catch (_) { /* fail-soft */ }
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

    // ── Modos de control de impresora ADHESIVO (cero-GAS; port de wh estado/calibrar/cancelar) ──
    // Van ANTES de leerDriftCfg/leerEnvasablesTokens (no los necesitan) para no pagar ese costo.
    // mode 'estado' — chequea si la impresora ADHESIVO está online (PrintNode printers/{id}).
    if (mode === 'estado') {
      let printerId = String(body.printerId || '');
      if (!printerId) printerId = await resolverPrinterAdhesivo();
      if (!printerId) return json({ ok: false, error: 'sin impresora ADHESIVO configurada', data: { esOnline: false } }, 200);
      const pr = await fetch('https://api.printnode.com/printers/' + printerId, {
        headers: { 'Authorization': 'Basic ' + btoa(PN_KEY + ':') } });
      if (!pr.ok) return json({ ok: false, error: 'PrintNode HTTP ' + pr.status, data: { printerId, esOnline: false } }, 200);
      const pj = await pr.json().catch(() => null);
      const pp = Array.isArray(pj) ? pj[0] : pj;
      return json({ ok: true, data: {
        printerId, nombre: pp?.name, estado: pp?.state,
        esOnline: String(pp?.state).toLowerCase() === 'online',
        computadora: pp?.computer && pp.computer.name, compEstado: pp?.computer && pp.computer.state } });
    }
    // mode 'calibrar' — GAPDETECT + FORMFEED (mide el gap del rollo nuevo) + reset drift/contador.
    if (mode === 'calibrar') {
      let printerId = String(body.printerId || '');
      if (!printerId) printerId = await resolverPrinterAdhesivo();
      if (!printerId) return json({ ok: false, error: 'sin impresora ADHESIVO configurada' }, 200);
      const tspl = 'SIZE 50 mm,25 mm\r\nGAP 2 mm,0 mm\r\nDIRECTION 1\r\nCLS\r\nGAPDETECT\r\nFORMFEED\r\n';
      let bin = ''; for (let i = 0; i < tspl.length; i++) bin += String.fromCharCode(tspl.charCodeAt(i) & 0xff);
      const pn = await printNodePost(parseInt(printerId), 'Calibrar ADHESIVO', btoa(bin), 'calibrar');
      if (!pn.ok) return json({ ok: false, error: 'PrintNode ' + pn.status + ': ' + pn.txt }, 200);
      await setConfigMos({ ADHESIVO_ROLLO_CALIBRADO: 'true', ADHESIVO_PRINTS_DESDE_CAL: '0',
        ADHESIVO_DRIFT_DOTS_POR_PRINT: '0', ADHESIVO_FECHA_CALIBRADO: new Date().toISOString() });
      return json({ ok: true, data: { jobId: pn.jobId,
        mensaje: 'Calibración enviada. Tras las ~3 etiquetas blancas, imprime alineado.' } });
    }
    // mode 'cancelar' — marca el lote CANCELADO (RPC atómica wh.lote_adhesivo_cancelar). Sin impresión.
    if (mode === 'cancelar') {
      const idLote = String(body.idLote || '');
      if (!idLote) return json({ ok: false, error: 'falta idLote' }, 400);
      const cn = await rpcWh('lote_adhesivo_cancelar', { idLote, usuario: body.usuario || '' });
      if (!cn || cn.ok === false) return json({ ok: false, error: cn?.error || 'cancelar falló' }, 200);
      return json({ ok: true, data: cn.data || cn });
    }

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

    // mode 'crear-membrete' — góndola ME / andamio WH. Expande items (1/producto ME; cabecera+códigos WH),
    // crea el lote atómico (codigoBarra placeholder = tipo; items reales en items_json) e imprime server-side.
    if (mode === 'crear-membrete') {
      const tipo = String(body.tipo || '').toUpperCase();
      if (tipo !== 'MEMBRETE_ME' && tipo !== 'MEMBRETE_WH') return json({ ok: false, error: 'tipo invalido (MEMBRETE_ME|MEMBRETE_WH)' }, 400);
      const itemsRaw = Array.isArray(body.items) ? body.items : [];
      if (!itemsRaw.length) return json({ ok: false, error: 'items vacio' }, 400);
      const expandidos = expandirMembrete(tipo, itemsRaw);
      if (!expandidos.length) return json({ ok: false, error: 'sin items validos (cada uno requiere codigoBarra o codigos)' }, 400);
      // [góndola] Resolver multi-código contra mos.equivalencias (server-authoritative)
      // → el canónico imprime skuBase + ⧉ aunque el catálogo de ME no traiga las equivalencias.
      if (tipo === 'MEMBRETE_ME') await marcarCanonicosME(expandidos);
      let printerId = String(body.printerId || '');
      if (!printerId) printerId = await resolverPrinterAdhesivo();
      if (!printerId) return json({ ok: false, error: 'sin impresora ADHESIVO configurada' }, 400);
      const cr = await rpcWh('lote_adhesivo_crear', {
        codigoBarra: tipo,
        descripcion: (tipo === 'MEMBRETE_ME' ? 'ME: ' : 'WH: ') + itemsRaw.length + ' productos',
        total: expandidos.length, tipoEtiqueta: tipo, itemsJson: expandidos,
        usuario: body.usuario || '', origen: body.origen || 'MOS', printerId,
        idempotencyKey: String(body.idempotencyKey || '')
      });
      if (!cr || cr.ok === false) return json({ ok: false, error: cr?.error || 'crear falló' }, 200);
      const idLote = cr.data && cr.data.idLote;
      if (!idLote) return json({ ok: false, error: 'sin idLote' }, 200);
      const res = await procesarLote(String(idLote), deadline, envTokens, cfg);
      return json({ ok: true, data: { idLote, total: cr.data.total, dedup: !!cr.dedup, ...res } });
    }

    // mode 'pickup-ticket' — imprime el ticket 80mm del PICKUP ACUMULADO por zona (lo no
    // despachado de la semana). Lo dispara el frontend WH el lunes (1 por zona) + botón 🖨
    // manual (force). Dedup server-side: marca [impreso] en notas → no re-imprime salvo force.
    if (mode === 'pickup-ticket') {
      const idp = String(body.id_pickup || body.idPickup || '');
      if (!idp) return json({ ok: false, error: 'falta id_pickup' }, 400);
      const pk = await leerPickup(idp);
      if (!pk) return json({ ok: false, error: 'pickup no encontrado' }, 200);
      const notas = String(pk.notas || '');
      const force = body.force === true;
      if (!force && notas.includes('[impreso]')) return json({ ok: true, data: { dedup: true, idPickup: idp } });
      const tk = buildPickingTicketB64(pk);
      if (tk.lineas === 0) return json({ ok: true, data: { vacio: true, idPickup: idp } });
      const printerId = (String(body.printerId || '') || await leerTicketPrinterId());
      if (!printerId) return json({ ok: false, error: 'sin WH_TICKET_PRINTER_ID configurado' }, 400);
      const pr = await printNodePost(parseInt(printerId, 10), 'Acumulado ' + _ascii(pk.id_zona || ''), tk.b64, idp);
      if (!pr.ok) return json({ ok: false, error: 'PrintNode HTTP ' + pr.status + ': ' + pr.txt }, 200);
      if (!notas.includes('[impreso]')) await marcarPickupImpreso(idp, notas + ' [impreso]');
      return json({ ok: true, data: { idPickup: idp, jobId: pr.jobId, lineas: tk.lineas, unidades: tk.unidades } });
    }

    // mode 'granel-despacho' — al despachar graneles desde WH, imprime 1 adhesivo por ítem (peso/nombre/código/
    // fecha + badge WH) para pegar en el saco. Print DIRECTO a PrintNode (sin lote/reserva), igual que pickup-ticket.
    // body { items:[{codigo|codigoBarra, nombre|descripcion, peso|cantidad(kg)}], printerId? }.
    if (mode === 'granel-despacho') {
      const itemsRaw = Array.isArray(body.items) ? body.items : [];
      if (!itemsRaw.length) return json({ ok: false, error: 'items vacio' }, 400);
      let printerId = String(body.printerId || '');
      if (!printerId) printerId = await resolverPrinterAdhesivo();
      if (!printerId) return json({ ok: false, error: 'sin impresora ADHESIVO configurada' }, 400);
      const pid = parseInt(printerId, 10);
      const impresos: any[] = [];
      let idx = 0;
      for (const it of itemsRaw) {
        if (Date.now() >= deadline) break;
        const codigo = String(it.codigo || it.codigoBarra || '');
        if (!codigo) continue;
        const tspl = buildTSPLGranelDespacho(it, cfg, driftOffset(cfg, idx++));
        const pr = await printNodePost(pid, 'Granel ' + _ascii(String(it.nombre || it.descripcion || codigo)).slice(0, 24), bytesToBase64(tspl), 'granel-' + codigo);
        impresos.push({ codigo, ok: !!pr.ok, jobId: pr.ok ? pr.jobId : null, error: pr.ok ? null : ('PrintNode ' + pr.status) });
      }
      return json({ ok: true, data: { impresos, total: impresos.length } });
    }

    // mode 'calibradores' — port de gas imprimirCalibradoresAdhesivo. Manda N reglas (1 job c/u) a la
    // impresora ADHESIVO para que el operador mida el desvío del rollo. Calibradores NO cuentan para el
    // contador de drift (están "fuera de cuenta"). cantidad 1..30 (default 10).
    if (mode === 'calibradores') {
      const cantidad = Math.max(1, Math.min(30, parseInt(String(body.cantidad || '10'), 10) || 10));
      const printerId = (String(body.printerId || '') || await resolverPrinterAdhesivo());
      if (!printerId) return json({ ok: false, error: 'sin impresora ADHESIVO configurada' }, 400);
      if (!PN_KEY) return json({ ok: false, error: 'PRINTNODE_API_KEY no configurada' }, 500);
      const detalle: Array<{ i: number; ok: boolean; jobId?: string; error?: string }> = [];
      for (let i = 1; i <= cantidad; i++) {
        const tspl = buildTSPLCalibrador(i, cantidad, cfg);
        let bin = ''; for (let k = 0; k < tspl.length; k++) bin += String.fromCharCode(tspl.charCodeAt(k) & 0xff);
        const pr = await printNodePost(parseInt(printerId, 10), 'Calibrador #' + i + '/' + cantidad, btoa(bin), 'calib');
        detalle.push(pr.ok ? { i, ok: true, jobId: pr.jobId } : { i, ok: false, error: 'HTTP ' + pr.status });
      }
      const enviados = detalle.filter((r) => r.ok).length;
      return json({ ok: true, data: { enviados, total: cantidad, detalle,
        mensaje: 'Mirá el calibrador #' + cantidad + '. ¿Cuántos mm se subió la regla? Ingresalo en "Aplicar drift detectado".' } });
    }

    // mode 'diagnostico-printnode' — port de gas diagnosticoPrintNodeAdhesivo. Solo LECTURA: estado de la
    // impresora ADHESIVO + últimos 10 jobs. Nunca imprime. Devuelve ok:true con `errores[]` poblado (no 4xx)
    // para que el frontend muestre el diagnóstico aunque falte impresora/API key.
    if (mode === 'diagnostico-printnode') {
      const diag: { printerId: string; impresoraInfo: unknown; jobsRecientes: unknown[]; errores: string[] } =
        { printerId: '', impresoraInfo: null, jobsRecientes: [], errores: [] };
      const printerId = (String(body.printerId || '') || await resolverPrinterAdhesivo());
      if (!printerId) { diag.errores.push('IMPRESORAS no tiene tipo=ADHESIVO zona=ALMACEN activa'); return json({ ok: true, data: diag }); }
      diag.printerId = printerId;
      if (!PN_KEY) { diag.errores.push('PRINTNODE_API_KEY no configurada'); return json({ ok: true, data: diag }); }
      const auth = 'Basic ' + btoa(PN_KEY + ':');
      try {
        const rImp = await fetch('https://api.printnode.com/printers/' + printerId, { headers: { Authorization: auth } });
        if (rImp.status === 200) {
          const arr = await rImp.json();
          const p = Array.isArray(arr) ? arr[0] : arr;
          if (p) diag.impresoraInfo = { id: p.id, name: p.name || '', description: p.description || '',
            state: (p.computer && p.computer.state) || p.state || 'unknown',
            online: !!(p.computer && p.computer.state === 'connected'), computer: (p.computer && p.computer.name) || '' };
        } else diag.errores.push('PrintNode rechazó getPrinter: HTTP ' + rImp.status);
      } catch (eP) { diag.errores.push('Error consultando impresora: ' + String((eP as Error)?.message || eP)); }
      try {
        const rJobs = await fetch('https://api.printnode.com/printers/' + printerId + '/printjobs?limit=10', { headers: { Authorization: auth } });
        if (rJobs.status === 200) {
          const jobs = await rJobs.json();
          diag.jobsRecientes = (jobs || []).map((j: any) => ({ id: j.id, title: String(j.title || '').substring(0, 60),
            state: j.state || 'unknown', createTimestamp: j.createTimestamp || '', source: String(j.source || '').substring(0, 40) }));
        } else diag.errores.push('PrintNode rechazó getJobs: HTTP ' + rJobs.status);
      } catch (eJ) { diag.errores.push('Error consultando jobs: ' + String((eJ as Error)?.message || eJ)); }
      return json({ ok: true, data: diag });
    }

    // mode 'calibrate-roll' — CALIBRAR NUEVO ROLLO (operador, sin admin/MOS). Manda un
    // GAPDETECT independiente a la impresora de adhesivos: re-mide el gap del rollo nuevo
    // (gasta ~2-3 etiquetas) y alinea la siguiente. Distinto de "calibrar drift" (ajuste fino).
    // Usa el gap configurado (ADHESIVO_GAP_MM=3) como referencia.
    if (mode === 'calibrate-roll') {
      const printerId = (String(body.printerId || '') || await resolverPrinterAdhesivo());
      if (!printerId) return json({ ok: false, error: 'sin impresora ADHESIVO configurada' }, 400);
      const tspl = 'SIZE 50 mm,25 mm\r\nGAP ' + cfg.gapMm + ' mm,0 mm\r\nDIRECTION 1\r\nGAPDETECT\r\n';
      let bin = ''; for (let i = 0; i < tspl.length; i++) bin += String.fromCharCode(tspl.charCodeAt(i) & 0xff);
      const pr = await printNodePost(parseInt(printerId, 10), 'Calibrar rollo adhesivo', btoa(bin), 'calib');
      if (!pr.ok) return json({ ok: false, error: 'PrintNode HTTP ' + pr.status + ': ' + pr.txt }, 200);
      return json({ ok: true, data: { calibrado: true, gapMm: cfg.gapMm, jobId: pr.jobId } });
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
    // Paridad con gas procesarAhoraTodos: intentados/ok/errores (aditivo; el cron ignora estos campos).
    const okN = resultados.filter((r) => r && r.status === 'COMPLETADO').length;
    const errN = resultados.filter((r) => r && (r.error || String(r.status || '').indexOf('PAUSADO') === 0)).length;
    return json({ ok: true, data: { procesados: resultados.length, intentados: resultados.length, ok: okN, errores: errN, resultados } });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
