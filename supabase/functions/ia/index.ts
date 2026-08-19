// Edge Function `ia` — proxy seguro PWA → Claude (Anthropic). Reemplaza el salto a GAS para IA (OCR boleta, parser
// listas, chat almacén). El navegador arma los `messages` (texto y/o imagen) y los manda acá; esta función reenvía
// a api.anthropic.com con la API key guardada en un SECRET (nunca en el navegador). Misma key que usa GAS hoy.
//
// AUTORIZACIÓN: la plataforma verifica la FIRMA del JWT (verify_jwt=true). Además exigimos claim app ∈ apps del
// ecosistema → la anon key (sin claim) NO pasa, y otra app tampoco.
//
// SECRET: supabase secrets set ANTHROPIC_API_KEY=<la misma de GAS> --project-ref rzbzdeipbtqkzjqdchqk

import { geminiMessages, proveedorIA, mapearModelo } from '../_shared/gemini.ts';

// [IA · Gemini 19-ago-2026] El proveedor se elige por mos.config.IA_PROVEEDOR (gemini | anthropic); con
// GEMINI_API_KEY puesta y sin config, Gemini. El navegador NO cambia: manda messages estilo Anthropic y lee
// content[].text + usage — el adaptador (_shared/gemini.ts) traduce ida y vuelta. Si Gemini responde
// 429/5xx y hay clave Anthropic con saldo, se cae a Claude en esa llamada (y al revés no: Claude sin saldo
// es 400, no se reintenta).
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['warehouseMos', 'mosExpress', 'MOS']);   // [RIZ Capa 5] MOS reusa la Edge IA para el panel de sugerencias por zona
const MODELO_DEFAULT = 'claude-haiku-4-5-20251001';
// whitelist de modelos permitidos (evita que pidan opus u otros caros vía el proxy) — solo haiku/sonnet
const MODELOS_OK = new Set(['claude-haiku-4-5-20251001', 'claude-3-5-haiku-20241022', 'claude-sonnet-5', 'claude-sonnet-4-6', 'claude-sonnet-4-5-20250929']);   // [foto/PDF listas] +sonnet-5 (visión/tablas)
const MAX_TOKENS_CAP = 8192;   // techo duro (= máximo output de Haiku 4.5; analizarListaSombra usa 8192 para listas grandes)
const ENDPOINT = 'https://api.anthropic.com/v1/messages';
// [852] CONTABILIDAD DE IA — registra tokens y costo de cada llamada a Claude.
// Nunca lanza: si el registro falla, la IA sigue funcionando igual. Sin await en el camino
// caliente (se dispara y se olvida) para no sumar latencia al usuario.
function _iaLog(rec: Record<string, unknown>): void {
  try {
    const _u = Deno.env.get('SUPABASE_URL');
    const _k = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!_u || !_k) return;
    fetch(`${_u}/rest/v1/rpc/ia_registrar_uso`, {
      method: 'POST',
      headers: { apikey: _k, Authorization: 'Bearer ' + _k,
                 'Content-Type': 'application/json', 'Content-Profile': 'mos' },
      body: JSON.stringify({ p: rec }),
    }).catch(() => {});
  } catch { /* contabilizar jamás rompe la operación */ }
}


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

    const prov = await proveedorIA();
    const key = Deno.env.get('ANTHROPIC_API_KEY');
    const gkey = Deno.env.get('GEMINI_API_KEY');
    if (prov === 'anthropic' && !key) return json({ ok: false, error: 'ANTHROPIC_API_KEY no configurada (secret)' }, 500);
    if (prov === 'gemini' && !gkey) return json({ ok: false, error: 'GEMINI_API_KEY no configurada (secret)' }, 500);

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
      // [fix 500x S5] passthrough de `thinking` (p.ej. {type:'disabled'}) — el parser de listas lo desactiva para
      // bajar latencia (evita el bloque thinking que arriesga timeout en visión). Solo se acepta si es objeto válido.
      ...(body.thinking && typeof body.thinking === 'object' ? { thinking: body.thinking } : {}),
    };

    const _t0 = Date.now();
    // [852] la función la declara quien llama (listaSombra, ocrComprobante, resumenZona…);
    // la app sale del claim del token, que ya está verificado arriba.
    const _fn = String(body.funcion || body.fn || 'ia').slice(0, 60);
    const _app = String(claims.app || '?');

    // ── GEMINI ──
    if (prov === 'gemini' && gkey) {
      const conWeb = Array.isArray(body.tools) && body.tools.some((t: Record<string, unknown>) => /web_search|google_search/i.test(String(t && (t.type || t.name) || '')));
      const gmodel = mapearModelo(body.model);
      const g = await geminiMessages({ key: gkey, model: gmodel, system: body.system ? String(body.system) : undefined,
                                       messages, max_tokens, grounding: conWeb, timeoutMs: 120000 });
      if (g.ok && g.data) {
        _iaLog({ app: _app, funcion: _fn, modelo: String(g.data.model || gmodel), ok: true, ms: Date.now() - _t0,
                 usage: g.data.usage || {}, meta: { stop: g.data.stop_reason || '', maxTokens: max_tokens, proveedor: 'gemini' } });
        return new Response(JSON.stringify(g.data), { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } });
      }
      _iaLog({ app: _app, funcion: _fn, modelo: gmodel, ok: false, ms: Date.now() - _t0,
               error: String(g.error || 'gemini').slice(0, 300), usage: {}, meta: { proveedor: 'gemini' } });
      // sin red de Claude (o error que no es de cupo): se devuelve el error de Gemini
      const caerAClaude = !!key && (g.status === 429 || g.status >= 500 || g.status === 0);
      if (!caerAClaude) return json({ ok: false, error: g.error || 'gemini' }, 502);
      // si no, sigue abajo con Claude en esta llamada
    }

    // ── ANTHROPIC ──
    if (!key) return json({ ok: false, error: 'sin proveedor de IA disponible' }, 500);
    const r = await fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const text = await r.text();
    if (!r.ok) {
      _iaLog({ app: _app, funcion: _fn, modelo: model, ok: false, ms: Date.now() - _t0,
               error: ('Claude ' + r.status + ': ' + text).slice(0, 300), usage: {} });
      return json({ ok: false, error: 'Claude ' + r.status + ': ' + text }, 502);
    }
    try {
      const _d = JSON.parse(text);
      _iaLog({ app: _app, funcion: _fn, modelo: String(_d.model || model), ok: true,
               ms: Date.now() - _t0, usage: _d.usage || {},
               meta: { stop: _d.stop_reason || '', maxTokens: max_tokens } });
    } catch { /* respuesta no-JSON: no se puede contabilizar, pero la IA responde igual */ }
    // devolvemos el JSON de Claude tal cual (el front lee .content[0].text como con GAS)
    return new Response(text, { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
