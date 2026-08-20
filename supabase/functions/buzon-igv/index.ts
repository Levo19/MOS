// [885] Edge `buzon-igv` — el buzón de IGV a favor. Recibe una FOTO de factura de compra (que no
// tiene guía de ingreso), la lee con IA (Gemini, reusando el OCR de comprobantes + el RUC del CLIENTE),
// sube la imagen a Storage y la registra con dedup + validación de RUC propio (mos.igv_buzon_registrar).
import { geminiMessages, GEMINI_FLASH } from '../_shared/gemini.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['warehouseMos', 'mosExpress', 'MOS']);
const SB_URL = Deno.env.get('SUPABASE_URL') || '';
const SB_SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';

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

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  const c = claims((req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim());
  if (!c || !APPS_OK.has(String(c.app))) return json({ ok: false, error: 'no autorizado' }, 401);
  if (!SB_URL || !SB_SR) return json({ ok: false, error: 'sin service role' }, 500);
  const gkey = Deno.env.get('GEMINI_API_KEY') || '';
  const akey = Deno.env.get('ANTHROPIC_API_KEY') || '';
  const body = await req.json().catch(() => ({}));
  const jpgB64 = String(body.jpgB64 || '').replace(/^data:[^;]+;base64,/, '');
  if (!jpgB64) return json({ ok: false, error: 'falta la imagen' }, 400);
  const mime = String(body.mime || 'image/jpeg');
  const usuario = String(body.usuario || '');
  const mes = body.mes, anio = body.anio;

  // 1) OCR
  const mensajes = [{ role: 'user', content: [
    { type: 'image', source: { type: 'base64', media_type: mime, data: jpgB64 } },
    { type: 'text', text: 'Extraé los datos de esta factura de compra y devolvé el JSON indicado.' },
  ] }];
  let texto = '';
  if (gkey) {
    const g = await geminiMessages({ key: gkey, model: GEMINI_FLASH, system: SYSTEM, messages: mensajes as any, max_tokens: 1200, json: true, timeoutMs: 60000 });
    if (!g.ok || !g.data) return json({ ok: false, error: 'OCR: ' + String(g.error || 'gemini') }, 502);
    texto = (((g.data.content as Record<string, unknown>[])[0] || {}).text as string) || '';
  } else if (akey) {
    const ar = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST', headers: { 'x-api-key': akey, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json' }, body: JSON.stringify({ model: 'claude-haiku-4-5-20251001', max_tokens: 1200, system: SYSTEM, messages: mensajes }) });
    const aj = await ar.json().catch(() => null); texto = (aj && aj.content && aj.content[0] && aj.content[0].text) || '';
  } else return json({ ok: false, error: 'sin proveedor de IA' }, 500);

  let d: Record<string, unknown> = {};
  try { const i0 = texto.indexOf('{'), i1 = texto.lastIndexOf('}'); d = JSON.parse(texto.slice(i0, i1 + 1)); } catch { return json({ ok: false, error: 'OCR no devolvió JSON' }, 502); }

  // 2) subir la imagen (bucket privado 'igv-buzon')
  let path = '';
  try {
    const bin = atob(jpgB64); const bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    path = `${anio}-${String(mes).padStart(2, '0')}/${Date.now()}.jpg`;
    await fetch(`${SB_URL}/storage/v1/object/igv-buzon/${path}`, { method: 'POST', headers: { apikey: SB_SR, Authorization: 'Bearer ' + SB_SR, 'Content-Type': mime, 'x-upsert': 'true' }, body: bytes });
  } catch { path = ''; }

  // 3) registrar con dedup + validación de RUC propio
  const reg = await rpc('igv_buzon_registrar', { p: {
    foto: path, mes, anio, usuario,
    rucEmisor: d.rucEmisor || '', razonSocial: d.razonSocial || '', rucCliente: d.rucCliente || '',
    serie: d.serie || '', numero: d.numero || '', fecha: d.fecha || '',
    total: d.total ?? 0, igv: d.igvRecuperable ?? 0, tipoComprobante: d.tipoComprobante || '',
    confidence: d.confidence ?? 0, estado: d.estado || '', notas: d.notas || '',
  } });
  if (!reg || reg.ok !== true) return json({ ok: false, error: (reg && reg.error) || 'no se registró' }, 502);
  return json({ ok: true, data: { ...reg, ocr: d } });
});
