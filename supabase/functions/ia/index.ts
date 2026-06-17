// Edge Function `ia` — proxy seguro PWA → Claude (Anthropic). Reemplaza el salto a GAS para IA (OCR boleta, parser
// listas, chat almacén). El navegador arma los `messages` (texto y/o imagen) y los manda acá; esta función reenvía
// a api.anthropic.com con la API key guardada en un SECRET (nunca en el navegador). Misma key que usa GAS hoy.
//
// AUTORIZACIÓN: la plataforma verifica la FIRMA del JWT (verify_jwt=true). Además exigimos claim app ∈ apps del
// ecosistema → la anon key (sin claim) NO pasa, y otra app tampoco.
//
// SECRET: supabase secrets set ANTHROPIC_API_KEY=<la misma de GAS> --project-ref rzbzdeipbtqkzjqdchqk

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['warehouseMos', 'mosExpress', 'MOS']);   // [RIZ Capa 5] MOS reusa la Edge IA para el panel de sugerencias por zona
const MODELO_DEFAULT = 'claude-haiku-4-5-20251001';
// whitelist de modelos permitidos (evita que pidan opus u otros caros vía el proxy) — solo haiku/sonnet
const MODELOS_OK = new Set(['claude-haiku-4-5-20251001', 'claude-3-5-haiku-20241022', 'claude-sonnet-4-6', 'claude-sonnet-4-5-20250929']);
const MAX_TOKENS_CAP = 8192;   // techo duro (= máximo output de Haiku 4.5; analizarListaSombra usa 8192 para listas grandes)
const ENDPOINT = 'https://api.anthropic.com/v1/messages';

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1];
    if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64));
  } catch { return null; }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const auth = req.headers.get('Authorization') || '';
    const claims = jwtClaims(auth.replace(/^Bearer\s+/i, '').trim());
    if (!claims || !APPS_OK.has(String(claims.app))) return json({ ok: false, error: 'no autorizado (claim app)' }, 401);

    const key = Deno.env.get('ANTHROPIC_API_KEY');
    if (!key) return json({ ok: false, error: 'ANTHROPIC_API_KEY no configurada (secret)' }, 500);

    const body = await req.json().catch(() => ({}));
    // El navegador manda los messages ya armados (texto y/o imagen base64). La Edge solo agrega key + reenvía.
    const messages = body.messages;
    if (!Array.isArray(messages) || messages.length === 0) return json({ ok: false, error: 'falta messages[]' }, 400);
    // model: solo de la whitelist (sino haiku); max_tokens: capeado (control de costos)
    const model = MODELOS_OK.has(String(body.model)) ? String(body.model) : MODELO_DEFAULT;
    const max_tokens = Math.min(Math.max(parseInt(String(body.max_tokens)) || 1024, 1), MAX_TOKENS_CAP);
    const payload = {
      model,
      max_tokens,
      messages,
      ...(body.system ? { system: String(body.system) } : {}),
      ...(Array.isArray(body.tools) && body.tools.length ? { tools: body.tools } : {}),
      ...(body.tool_choice ? { tool_choice: body.tool_choice } : {}),
    };

    const r = await fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const text = await r.text();
    if (!r.ok) return json({ ok: false, error: 'Claude ' + r.status + ': ' + text }, 502);
    // devolvemos el JSON de Claude tal cual (el front lee .content[0].text como con GAS)
    return new Response(text, { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
