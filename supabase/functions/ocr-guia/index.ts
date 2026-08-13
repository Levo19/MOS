// Edge Function `ocr-guia` — OCR AUTOMÁTICO de comprobantes de proveedor (server-side).
// [762] El dueño: "cada vez que un operador sube una foto a una guía de proveedor debe
// analizarse sola, así se cambie la foto después". Antes el OCR solo corría desde el FRONT
// de WH en la subida directa — la foto heredada del preingreso (el camino que más usan los
// operadores) nunca se analizaba: 25 de 26 guías de agosto quedaron sin OCR.
//
// Flujo: trigger en wh.guias marca ocr_estado='PENDIENTE' al cambiar la foto → pg_cron
// (wh.cron_ocr_guias, cada 10 min, máx 3 por tick = control de gasto Vision) llama acá con
// {idGuia} → esta función baja la foto, llama a Claude (visión) con el prompt fiscal SUNAT
// (réplica FIEL de IA.gs/WH api.js — no alterar: alimenta el IGV a favor del centro
// tributario) y persiste los 12 campos en wh.guias.
//
// AUTORIZACIÓN: header x-ocr-cron == secret OCR_CRON_SECRET (mismo patrón que la Edge push).
// SECRETS: ANTHROPIC_API_KEY (ya existe, la usa `ia`) + OCR_CRON_SECRET (nuevo).

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-ocr-cron',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

const SYSTEM = [
  'Eres un asistente experto en lectura de comprobantes de pago peruanos (SUNAT).',
  'Recibes una imagen y debes extraer los datos del documento.',
  '',
  'TIPOS DE COMPROBANTE:',
  '- FACTURA: tiene RUC del emisor + IGV desglosado (18%) → IGV es recuperable',
  '- BOLETA_VENTA con RUC: emisor identificado pero sin IGV recuperable',
  '- TICKET o NOTA_DE_VENTA: sin IGV → NO recuperable',
  '- NO_COMPROBANTE: la imagen no es un documento fiscal (es un producto, escena, etc.)',
  '- ILEGIBLE: la imagen está borrosa, oscura o no se ve el documento',
  '',
  'Si extraes IGV, debe coincidir con el formato peruano (18% del subtotal gravado).',
  'Si el total es S/ 118 y se ve "IGV 18" o "IGV S/ 18.00", entonces igvRecuperable=18.',
  '',
  'RESPONDE EXCLUSIVAMENTE con JSON válido (sin markdown, sin comentarios):',
  '{',
  '  "tipoComprobante": "FACTURA" | "BOLETA_VENTA" | "TICKET" | "NO_COMPROBANTE" | "ILEGIBLE",',
  '  "rucEmisor": "20XXXXXXXXX" (11 dígitos) o "",',
  '  "razonSocial": "string" o "",',
  '  "serie": "F001" o "B001" o "" (la serie del documento),',
  '  "numero": "0000123" o "" (el número del documento),',
  '  "fecha": "DD/MM/YYYY" o "",',
  '  "total": número o 0 (total del documento en soles),',
  '  "subtotal": número o 0 (gravada sin IGV — solo si es FACTURA),',
  '  "igvRecuperable": número o 0 (solo > 0 si es FACTURA con IGV discriminado),',
  '  "confidence": 0-100 (qué tan seguro estás de los datos extraídos),',
  '  "estado": "PROCESADO" | "SIN_IGV" | "ILEGIBLE" | "NO_COMPROBANTE",',
  '  "notas": "string corto explicando el caso si aplica"',
  '}',
].join('\n');

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const secret = Deno.env.get('OCR_CRON_SECRET');
    if (!secret || (req.headers.get('x-ocr-cron') || '') !== secret) {
      return json({ ok: false, error: 'no autorizado' }, 401);
    }
    const SB_URL = Deno.env.get('SUPABASE_URL');
    const SB_SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const AK = Deno.env.get('ANTHROPIC_API_KEY');
    if (!SB_URL || !SB_SR || !AK) return json({ ok: false, error: 'secrets faltantes' }, 500);
    const srHeaders = { 'apikey': SB_SR, 'Authorization': 'Bearer ' + SB_SR };

    const body = await req.json().catch(() => ({}));
    const idGuia = String(body.idGuia || body.id_guia || '').trim();
    if (!idGuia) return json({ ok: false, error: 'idGuia requerido' }, 400);

    // 1) foto de la guía (service role, lectura directa)
    const gr = await fetch(`${SB_URL}/rest/v1/guias?select=foto,tipo&id_guia=eq.${encodeURIComponent(idGuia)}`, {
      headers: { ...srHeaders, 'Accept-Profile': 'wh' },
    });
    const rows = await gr.json().catch(() => []);
    const foto = Array.isArray(rows) && rows[0] ? String(rows[0].foto || '').trim() : '';
    if (!foto) return json({ ok: false, error: 'guía sin foto', transitorio: false }, 200);

    // 2) bajar la imagen → base64 (cap 4.5MB: Claude rechaza imágenes mayores)
    const ir = await fetch(foto);
    if (!ir.ok) return json({ ok: false, error: 'descarga foto ' + ir.status, transitorio: true }, 200);
    const mime = ir.headers.get('Content-Type') || 'image/jpeg';
    const buf = new Uint8Array(await ir.arrayBuffer());
    if (buf.length > 4.5 * 1024 * 1024) {
      await persistir(SB_URL, srHeaders, idGuia, { estado: 'ILEGIBLE', tipo_comprobante: 'ILEGIBLE', notas: 'foto demasiado grande para Vision (' + Math.round(buf.length / 1024) + 'KB)' });
      return json({ ok: true, estado: 'ILEGIBLE' });
    }
    let bin = ''; const CH = 0x8000;
    for (let i = 0; i < buf.length; i += CH) bin += String.fromCharCode(...buf.subarray(i, i + CH));
    const b64 = btoa(bin);

    // 3) Claude visión (haiku — mismo modelo/costo que el camino del front vía Edge `ia`)
    const ar = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': AK, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001', max_tokens: 1536, system: SYSTEM,
        messages: [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: mime, data: b64 } },
          { type: 'text', text: 'Analiza este comprobante de proveedor y devuelve el JSON con la estructura indicada.' },
        ] }],
      }),
    });
    if (!ar.ok) return json({ ok: false, error: 'anthropic ' + ar.status, transitorio: true }, 200);
    const aj = await ar.json().catch(() => null);
    const text = (aj && aj.content && aj.content[0] && aj.content[0].text) || '';
    const first = text.indexOf('{'), last = text.lastIndexOf('}');
    if (first < 0 || last < 0) return json({ ok: false, error: 'respuesta sin JSON', transitorio: true }, 200);
    let r: Record<string, unknown>;
    try { r = JSON.parse(text.substring(first, last + 1)); } catch { return json({ ok: false, error: 'JSON inválido', transitorio: true }, 200); }

    // 4) persistir (normalización fiel a IA.gs/WH api.js)
    await persistir(SB_URL, srHeaders, idGuia, {
      estado: String(r.estado || 'NO_COMPROBANTE'),
      tipo_comprobante: String(r.tipoComprobante || 'NO_COMPROBANTE'),
      ruc_emisor: String(r.rucEmisor || ''),
      razon_social: String(r.razonSocial || ''),
      serie: String(r.serie || ''),
      numero: String(r.numero || ''),
      fecha: String(r.fecha || ''),
      total: parseFloat(String(r.total)) || 0,
      subtotal: parseFloat(String(r.subtotal)) || 0,
      igv_recuperable: parseFloat(String(r.igvRecuperable)) || 0,
      confidence: parseInt(String(r.confidence), 10) || 0,
      notas: String(r.notas || ''),
    });
    return json({ ok: true, estado: String(r.estado || 'NO_COMPROBANTE'), igv: parseFloat(String(r.igvRecuperable)) || 0 });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e).slice(0, 180), transitorio: true }, 200);
  }
});

async function persistir(SB_URL: string, srHeaders: Record<string, string>, idGuia: string, d: Record<string, unknown>) {
  const patch: Record<string, unknown> = {
    ocr_estado: d.estado, ocr_tipo: d.tipo_comprobante,
    ocr_ruc_emisor: d.ruc_emisor ?? '', ocr_razon_social: d.razon_social ?? '',
    ocr_serie: d.serie ?? '', ocr_numero: d.numero ?? '', ocr_fecha_comprobante: d.fecha ?? '',
    ocr_total: d.total ?? 0, ocr_subtotal: d.subtotal ?? 0, igv_recuperable: d.igv_recuperable ?? 0,
    ocr_confidence: d.confidence ?? 0, ocr_notas: d.notas ?? '', ocr_fecha_proceso: new Date().toISOString(),
  };
  await fetch(`${SB_URL}/rest/v1/guias?id_guia=eq.${encodeURIComponent(idGuia)}`, {
    method: 'PATCH',
    headers: { ...srHeaders, 'Content-Profile': 'wh', 'Content-Type': 'application/json', 'Prefer': 'return=minimal' },
    body: JSON.stringify(patch),
  });
}
