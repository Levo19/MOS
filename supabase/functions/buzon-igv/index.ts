// [885/939] Edge `buzon-igv` — el buzón de IGV a favor. El OCR de tributos es VITAL: la factura de compra
// se GUARDA SIEMPRE (imagen a Storage + fila PENDIENTE) y se lee con IA apenas haya cupo — nunca se pierde
// ni depende de reintento manual. Dos modos:
//   · default (app): sube imagen → crea fila PENDIENTE → intenta OCR ya; si hay cupo se aplica, si no queda
//     PENDIENTE con la imagen a salvo (respuesta {pendiente:true}).
//   · reintento (cron wh.cron_buzon_reintentar, auth x-ocr-cron): baja la imagen guardada y re-OCRea las
//     PENDIENTE. Así se aprovecha el token: espera y ejecuta apenas se pueda.
import { geminiMessages, GEMINI_FLASH } from '../_shared/gemini.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-ocr-cron',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['warehouseMos', 'mosExpress', 'MOS']);
const SB_URL = Deno.env.get('SUPABASE_URL') || '';
const SB_SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const BUCKET = 'igv-buzon';

const SYSTEM = [
  'Eres un asistente experto en lectura de comprobantes de pago peruanos (SUNAT).',
  'Recibes la imagen de una FACTURA DE COMPRA y extraes sus datos. Es clave distinguir el EMISOR',
  '(quien vende / emite la factura) del CLIENTE (a quién está dirigida, "Señor(es)" / "Adquiriente").',
  '',
  '- FACTURA: tiene RUC del emisor + IGV desglosado (18%) → IGV recuperable.',
  '- BOLETA_VENTA / TICKET / NOTA_DE_VENTA: sin IGV recuperable.',
  '- NO_COMPROBANTE: la imagen no es un documento fiscal. ILEGIBLE: borrosa/no se ve.',
  '',
  'RESPONDE EXCLUSIVAMENTE JSON válido (sin markdown):',
  '{',
  '  "tipoComprobante": "FACTURA"|"BOLETA_VENTA"|"TICKET"|"NO_COMPROBANTE"|"ILEGIBLE",',
  '  "rucEmisor": "20XXXXXXXXX" o "",',
  '  "razonSocial": "razón social del EMISOR" o "",',
  '  "rucCliente": "el RUC del CLIENTE/adquiriente (a quién se emitió)" o "",',
  '  "serie": "F001" o "", "numero": "0000123" o "", "fecha": "DD/MM/YYYY" o "",',
  '  "total": número, "subtotal": número, "igvRecuperable": número (solo FACTURA con IGV),',
  '  "confidence": 0-100, "estado": "PROCESADO"|"SIN_IGV"|"ILEGIBLE"|"NO_COMPROBANTE",',
  '  "notas": "string corto"',
  '}',
].join('\n');

function json(p: unknown, s = 200): Response { return new Response(JSON.stringify(p), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } }); }
function claims(t: string): Record<string, unknown> | null { try { const b = t.split('.')[1]; return JSON.parse(atob(b.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(b.length / 4) * 4, '='))); } catch { return null; } }
async function rpc(fn: string, body: unknown) { const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: SB_SR, Authorization: 'Bearer ' + SB_SR, 'Content-Type': 'application/json', 'Content-Profile': 'mos' }, body: JSON.stringify(body) }); return r.json().catch(() => null); }

// ¿el fallo del OCR es por CUOTA/CRÉDITO agotado (no un bug)? → la fila queda PENDIENTE y el cron reintenta sin gastar tope.
function esSinCupo(status: number, err: string): boolean {
  if (status === 429) return true;
  return /quota|exceeded|resource_exhausted|credit balance|too low|rate[\s_-]*limit/i.test(String(err || ''));
}

// OCR de una imagen (Gemini con fallback a Claude). Devuelve {ok, texto} o {ok:false, sinCupo, error}.
async function ocrImagen(gkey: string, akey: string, jpgB64: string, mime: string): Promise<{ ok: boolean; texto?: string; sinCupo?: boolean; error?: string }> {
  const mensajes = [{ role: 'user', content: [
    { type: 'image', source: { type: 'base64', media_type: mime, data: jpgB64 } },
    { type: 'text', text: 'Extraé los datos de esta factura de compra y devolvé el JSON indicado.' },
  ] }];
  if (gkey) {
    const g = await geminiMessages({ key: gkey, model: GEMINI_FLASH, system: SYSTEM, messages: mensajes as any, max_tokens: 1200, json: true, timeoutMs: 60000 });
    if (g.ok && g.data) return { ok: true, texto: (((g.data.content as Record<string, unknown>[])[0] || {}).text as string) || '' };
    // Gemini falló. Si es cupo/5xx y hay Claude con saldo, se intenta Claude; si no, se reporta sin_cupo/err.
    const cupo = esSinCupo(g.status, g.error || '');
    if (akey && (cupo || g.status >= 500 || g.status === 0)) {
      const a = await ocrAnthropic(akey, mensajes);
      if (a.ok) return a;
      return { ok: false, sinCupo: cupo || a.sinCupo, error: a.error || g.error };
    }
    return { ok: false, sinCupo: cupo, error: String(g.error || 'gemini') };
  }
  if (akey) return ocrAnthropic(akey, mensajes);
  return { ok: false, sinCupo: false, error: 'sin proveedor de IA' };
}
async function ocrAnthropic(akey: string, mensajes: unknown): Promise<{ ok: boolean; texto?: string; sinCupo?: boolean; error?: string }> {
  try {
    const ar = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST', headers: { 'x-api-key': akey, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json' }, body: JSON.stringify({ model: 'claude-haiku-4-5-20251001', max_tokens: 1200, system: SYSTEM, messages: mensajes }) });
    const txt = await ar.text();
    if (!ar.ok) return { ok: false, sinCupo: esSinCupo(ar.status, txt), error: 'claude ' + ar.status };
    const aj = JSON.parse(txt); return { ok: true, texto: (aj && aj.content && aj.content[0] && aj.content[0].text) || '' };
  } catch (e) { return { ok: false, sinCupo: false, error: String((e as Error)?.message || e) }; }
}

function parseOCR(texto: string): Record<string, unknown> | null {
  try { const i0 = texto.indexOf('{'), i1 = texto.lastIndexOf('}'); return JSON.parse(texto.slice(i0, i1 + 1)); } catch { return null; }
}
function b64ToBytes(b64: string): Uint8Array { const bin = atob(b64); const bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i); return bytes; }

async function subirImagen(jpgB64: string, mime: string, mes: unknown, anio: unknown): Promise<string> {
  const path = `${anio}-${String(mes).padStart(2, '0')}/${Date.now()}.jpg`;
  const r = await fetch(`${SB_URL}/storage/v1/object/${BUCKET}/${path}`, { method: 'POST', headers: { apikey: SB_SR, Authorization: 'Bearer ' + SB_SR, 'Content-Type': mime, 'x-upsert': 'true' }, body: b64ToBytes(jpgB64) });
  if (!r.ok) throw new Error('storage ' + r.status);
  return path;
}
async function bajarImagen(path: string): Promise<string | null> {
  const r = await fetch(`${SB_URL}/storage/v1/object/${BUCKET}/${path}`, { headers: { apikey: SB_SR, Authorization: 'Bearer ' + SB_SR } });
  if (!r.ok) return null;
  const buf = new Uint8Array(await r.arrayBuffer());
  let bin = ''; const CH = 0x8000; for (let i = 0; i < buf.length; i += CH) bin += String.fromCharCode(...buf.subarray(i, i + CH));
  return btoa(bin);
}
function mapAplicar(idBuzon: string, d: Record<string, unknown>) {
  return { p: { idBuzon,
    rucEmisor: d.rucEmisor || '', razonSocial: d.razonSocial || '', rucCliente: d.rucCliente || '',
    serie: d.serie || '', numero: d.numero || '', fecha: d.fecha || '',
    total: d.total ?? 0, igv: d.igvRecuperable ?? 0, tipoComprobante: d.tipoComprobante || '',
    confidence: d.confidence ?? 0, estado: d.estado || '', notas: d.notas || '' } };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  if (!SB_URL || !SB_SR) return json({ ok: false, error: 'sin service role' }, 500);
  const gkey = Deno.env.get('GEMINI_API_KEY') || '';
  const akey = Deno.env.get('ANTHROPIC_API_KEY') || '';
  const body = await req.json().catch(() => ({}));
  const modo = String(body.modo || '');

  // ── MODO REINTENTO (cron): re-OCR de una PENDIENTE ya guardada ──
  if (modo === 'reintento') {
    const secret = Deno.env.get('OCR_CRON_SECRET');
    if (!secret || (req.headers.get('x-ocr-cron') || '') !== secret) return json({ ok: false, error: 'no autorizado' }, 401);
    const idBuzon = String(body.idBuzon || '');
    const path = String(body.foto || '');
    if (!idBuzon || !path) return json({ ok: false, error: 'falta idBuzon/foto' }, 400);
    const b64 = await bajarImagen(path);
    if (!b64) { await rpc('igv_buzon_ocr_fallo', { p: { idBuzon } }); return json({ ok: false, error: 'no se pudo bajar la imagen' }, 502); }
    const o = await ocrImagen(gkey, akey, b64, 'image/jpeg');
    if (!o.ok) {
      if (o.sinCupo) return json({ ok: true, pendiente: true, idBuzon, motivo: 'sin_cupo' });   // reintenta luego, NO cuenta intento
      await rpc('igv_buzon_ocr_fallo', { p: { idBuzon } });
      return json({ ok: false, error: o.error }, 502);
    }
    const d = parseOCR(o.texto || '');
    if (!d) { await rpc('igv_buzon_ocr_fallo', { p: { idBuzon } }); return json({ ok: false, error: 'OCR no devolvió JSON' }, 502); }
    const reg = await rpc('igv_buzon_ocr_aplicar', mapAplicar(idBuzon, d));
    return json({ ok: !!(reg && reg.ok), data: reg, ocr: d });
  }

  // ── MODO SUBIR (app): guardar SIEMPRE, luego intentar OCR ──
  const c = claims((req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim());
  if (!c || !APPS_OK.has(String(c.app))) return json({ ok: false, error: 'no autorizado' }, 401);
  const jpgB64 = String(body.jpgB64 || '').replace(/^data:[^;]+;base64,/, '');
  if (!jpgB64) return json({ ok: false, error: 'falta la imagen' }, 400);
  const mime = String(body.mime || 'image/jpeg');
  const usuario = String(body.usuario || '');
  const mes = body.mes, anio = body.anio;

  // 1) subir la imagen SIEMPRE (nunca perder la factura)
  let path = '';
  try { path = await subirImagen(jpgB64, mime, mes, anio); } catch { return json({ ok: false, error: 'no se pudo guardar la imagen, reintenta' }, 502); }
  // 2) crear la fila PENDIENTE (la factura ya está a salvo)
  const cr = await rpc('igv_buzon_pendiente_crear', { p: { foto: path, mes, anio, usuario } });
  if (!cr || cr.ok !== true) return json({ ok: false, error: (cr && cr.error) || 'no se registró' }, 502);
  const idBuzon = String(cr.idBuzon);
  // 3) intentar leerla ya
  const o = await ocrImagen(gkey, akey, jpgB64, mime);
  if (!o.ok) {
    if (o.sinCupo) return json({ ok: true, pendiente: true, idBuzon, mensaje: 'Factura guardada ✓ Se leerá sola apenas haya cupo de IA (unos minutos).' });
    await rpc('igv_buzon_ocr_fallo', { p: { idBuzon } });
    return json({ ok: true, pendiente: true, idBuzon, mensaje: 'Factura guardada ✓ El lector la reintentará en un momento.' });
  }
  const d = parseOCR(o.texto || '');
  if (!d) { await rpc('igv_buzon_ocr_fallo', { p: { idBuzon } }); return json({ ok: true, pendiente: true, idBuzon, mensaje: 'Factura guardada ✓ El lector la reintentará en un momento.' }); }
  const reg = await rpc('igv_buzon_ocr_aplicar', mapAplicar(idBuzon, d));
  if (!reg || reg.ok !== true) return json({ ok: false, error: (reg && reg.error) || 'no se aplicó' }, 502);
  return json({ ok: true, data: { ...reg, ocr: d } });
});
