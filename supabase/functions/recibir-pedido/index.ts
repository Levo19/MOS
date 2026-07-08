// Edge `recibir-pedido` — portal cliente WH, cero-GAS. Reemplaza ClientePortal.gs clienteRecibirPedido.
// PÚBLICO (anon key; el portal no tiene token de app). Orquesta server-side: Claude Vision para fotos +
// parser de lista para texto + fallback regex → crea el pedido PREVIEW (wh.cliente_pedido_crear, service role).
// Guarda adjuntos en Storage `wh-fotos/pedidos/<token>/` best-effort.
//
// SECRETS: ANTHROPIC_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const ANTHROPIC = 'https://api.anthropic.com/v1/messages';
const MODELO = 'claude-haiku-4-5-20251001';
const UNIDADES = ['kg','kilo','kilos','gr','gramo','gramos','lt','litro','litros','saco','sacos','caja','cajas','paquete','paquetes','unidad','unidades','und','u','botella','botellas','lata','latas','bolsa','bolsas','docena','docenas','tarro','tarros','frasco','frascos','pack'];

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
function stripB64(s: string): string { const i = String(s || '').indexOf('base64,'); return i >= 0 ? String(s).substring(i + 7) : String(s || ''); }

async function claude(key: string, system: string, messages: unknown[], maxTokens = 2048): Promise<string> {
  const r = await fetch(ANTHROPIC, {
    method: 'POST',
    headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({ model: MODELO, max_tokens: maxTokens, system, messages }),
  });
  if (!r.ok) throw new Error('Claude ' + r.status);
  const j = await r.json().catch(() => ({}));
  return (j && j.content && j.content[0] && j.content[0].text) ? String(j.content[0].text) : '';
}

// Vision: foto de lista → líneas "CANTIDAD UNIDAD NOMBRE"
async function visionLista(key: string, b64: string, mime: string): Promise<string> {
  const system = [
    'Recibes la foto de una LISTA de productos escrita a mano o impresa.',
    'Extrae los productos UNO POR LÍNEA en este formato exacto:',
    'CANTIDAD UNIDAD NOMBRE',
    'Ejemplo:', '2 saco arroz costeño', '6 lt aceite primor', '4 unidad coca cola 3L',
    '', 'Solo escribe las líneas, sin encabezados, sin comentarios.',
  ].join('\n');
  return await claude(key, system, [{
    role: 'user',
    content: [
      { type: 'image', source: { type: 'base64', media_type: mime || 'image/jpeg', data: stripB64(b64) } },
      { type: 'text', text: 'Transcribe esta lista en el formato indicado.' },
    ],
  }]);
}

// Texto consolidado → items estructurados (JSON) vía Claude
async function parseListaIA(key: string, texto: string): Promise<Array<Record<string, unknown>>> {
  const system = [
    'Recibes texto con una lista de compras (puede venir de una transcripción de foto).',
    'Devuelve SOLO un array JSON, sin texto extra, donde cada item es:',
    '{"nombre":"NOMBRE EN MAYUSCULAS","cantidad":número,"unidad":"kg|lt|saco|caja|unidad|...","duda":""}',
    'Si no estás seguro de un item, ponlo igual con "duda" describiendo la incertidumbre.',
    'No inventes productos que no estén en el texto.',
  ].join('\n');
  try {
    const out = await claude(key, system, [{ role: 'user', content: [{ type: 'text', text: texto }] }], 4096);
    const m = out.match(/\[[\s\S]*\]/);
    if (!m) return [];
    const arr = JSON.parse(m[0]);
    return Array.isArray(arr) ? arr : [];
  } catch { return []; }
}

// Fallback regex "N unidad nombre" (port de _cliFallbackParse)
function fallbackParse(texto: string): Array<Record<string, unknown>> {
  const items: Array<Record<string, unknown>> = [];
  for (const raw of String(texto || '').split(/\r?\n/)) {
    const l = raw.trim(); if (!l) continue;
    const m = l.match(/^(\d+(?:[.,]\d+)?)\s+(.+)$/); if (!m) continue;
    const qty = parseFloat(m[1].replace(',', '.')); if (!(qty > 0)) continue;
    const palabras = m[2].trim().split(/\s+/); let unidad = 'unidad';
    if (palabras.length >= 2) {
      const primera = palabras[0].toLowerCase().replace(/[.,]$/, '');
      const ultima = palabras[palabras.length - 1].toLowerCase().replace(/[.,]$/, '');
      if (UNIDADES.includes(primera)) { unidad = primera; palabras.shift(); }
      else if (UNIDADES.includes(ultima)) { unidad = ultima; palabras.pop(); }
    }
    const nombre = palabras.join(' ').trim().toUpperCase();
    if (nombre) items.push({ nombre, cantidad: qty, unidad });
  }
  return items;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const SB_URL = Deno.env.get('SUPABASE_URL');
    const SB_SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const AK = Deno.env.get('ANTHROPIC_API_KEY');
    if (!SB_URL || !SB_SR) return json({ ok: false, error: 'Supabase secrets no configurados' }, 500);

    const body = await req.json().catch(() => ({}));
    const token = String(body.token || 'ANON').toUpperCase() || 'ANON';
    const textoUser = String(body.texto || '').trim();
    const adjuntos = Array.isArray(body.adjuntos) ? body.adjuntos : [];

    const textosParaIA: string[] = [];
    if (textoUser) textosParaIA.push(textoUser);
    const adjMeta: Array<Record<string, unknown>> = [];

    for (const a of adjuntos) {
      const tipo = String(a.tipo || '');
      const mime = String(a.mime || 'application/octet-stream');
      const nombre = String(a.nombre || (tipo + '_' + Date.now()));
      // Guardar en Storage best-effort
      let url = '';
      try {
        const bin = Uint8Array.from(atob(stripB64(a.b64)), (c) => c.charCodeAt(0));
        const path = `pedidos/${token}/${Date.now()}_${nombre}`.replace(/[^\w./-]/g, '_');
        const up = await fetch(`${SB_URL}/storage/v1/object/wh-fotos/${path}`, {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + SB_SR, 'Content-Type': mime, 'x-upsert': 'true' },
          body: bin,
        });
        if (up.ok) url = `${SB_URL}/storage/v1/object/public/wh-fotos/${path}`;
      } catch { /* storage best-effort */ }
      adjMeta.push({ tipo, nombre, url });
      // Foto → Vision
      if (tipo === 'foto' && mime.startsWith('image/') && AK) {
        try { const t = await visionLista(AK, a.b64, mime); if (t) textosParaIA.push('[de imagen ' + nombre + ']\n' + t); }
        catch { /* sigue */ }
      }
    }

    const textoFinal = textosParaIA.join('\n');
    let items: Array<Record<string, unknown>> = [];
    let nota = '';
    if (textoFinal && AK) {
      items = await parseListaIA(AK, textoFinal);
      if (!items.length) { items = fallbackParse(textoFinal); nota = 'fallback regex (IA sin items)'; }
    } else if (textoFinal) {
      items = fallbackParse(textoFinal); nota = 'sin IA (parser básico)';
    }
    // Normalizar
    const itemsFront = items.map((it) => ({
      nombre: String(it.nombre || '').toUpperCase().trim(),
      cantidad: Math.round((parseFloat(String(it.cantidad)) || 0) * 10) / 10,
      unidad: String(it.unidad || 'unidad'),
      duda: String(it.duda || ''),
    })).filter((it) => it.nombre && it.cantidad > 0);
    // Audio/excel sin IA → marcar review
    const hayNoIA = adjMeta.some((a) => a.tipo === 'audio' || a.tipo === 'excel');
    if (hayNoIA && itemsFront.length === 0) itemsFront.push({ nombre: 'Adjunto sin procesar IA — revisar manualmente', cantidad: 1, unidad: 'rev', duda: 'audio/excel adjunto' });

    // Crear el pedido (service role RPC)
    const rr = await fetch(`${SB_URL}/rest/v1/rpc/cliente_pedido_crear`, {
      method: 'POST',
      headers: { 'apikey': SB_SR, 'Authorization': 'Bearer ' + SB_SR, 'Content-Type': 'application/json', 'Content-Profile': 'wh' },
      body: JSON.stringify({ p: { token, nota, items: itemsFront, adjuntos: adjMeta } }),
    });
    const rj = await rr.json().catch(() => null);
    if (!rj || rj.ok !== true) return json({ ok: false, error: (rj && rj.error) || 'No se pudo crear el pedido' }, 500);

    return json({ ok: true, data: { idPedido: rj.data.idPedido, items: rj.data.items, nombreCliente: rj.data.nombreCliente, nota, textoOriginal: textoFinal } });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
