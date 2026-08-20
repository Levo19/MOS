// [MosGuard] Edge `mint-guard` — el puente de identidad para reusar Spy 2.0.
//
// Un equipo MosGuard vive en mos.yape_dispositivos (lo identifica su SECRETO). El motor del espía
// (RPCs espia_*) exige un JWT de app (`_espia_app_ok` = jwt_app <> ''). Esta función valida el
// secreto contra yape_dispositivos y emite un JWT HS256 con app='mosGuard' → así el WebView de
// MosGuard puede correr el cliente de espía EXACTO de Spy 2.0 (cam+mic+GPS) sobre Supabase, sin
// reescribir WebRTC. El deviceId del espía = el nombre del equipo (estable, único por equipo).
//
// verify_jwt=false (no puede exigir un JWT para dar un JWT). El control real: el secreto (bcryptless
// hash sha256 en yape_dispositivos) + el WH_JWT_SECRET del proyecto, que jamás sale de acá.
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APP = 'mosGuard';
const TTL_SEG = 60 * 60;   // 1 h

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
function b64urlStr(s: string): string {
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
async function firmarJWT(payload: Record<string, unknown>, secret: string): Promise<string> {
  const header = { alg: 'HS256', typ: 'JWT' };
  const signingInput = b64urlStr(JSON.stringify(header)) + '.' + b64urlStr(JSON.stringify(payload));
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(signingInput));
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return signingInput + '.' + sigB64;
}

// resuelve el equipo por su secreto (via RPC service-role → sha256 en el server). Devuelve el nombre o ''.
async function equipoPorSecreto(secreto: string): Promise<string> {
  try {
    const url = Deno.env.get('SUPABASE_URL'); const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !key) return '';
    const r = await fetch(`${url}/rest/v1/rpc/yape_guard_por_secreto`, {
      method: 'POST',
      headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json', 'Content-Profile': 'mos' },
      body: JSON.stringify({ p: { secreto } }),
    });
    const d = await r.json().catch(() => null);
    return d && d.ok ? String(d.nombre || '') : '';
  } catch { return ''; }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const secreto = String((body && body.secreto) || '').trim();
    if (!secreto) return json({ ok: false }, 400);
    const secret = Deno.env.get('WH_JWT_SECRET');
    if (!secret) return json({ ok: false }, 500);
    const nombre = await equipoPorSecreto(secreto);
    if (!nombre) return json({ ok: false }, 401);

    const now = Math.floor(Date.now() / 1000);
    const payload = {
      iss: 'supabase', role: 'authenticated', aud: 'authenticated',
      sub: 'guard:' + nombre, app: APP, iat: now, exp: now + TTL_SEG,
    };
    const token = await firmarJWT(payload, secret);
    // deviceId del espía = el nombre del equipo (lo que el master apunta desde MOS)
    return json({ ok: true, token, deviceId: nombre, exp: now + TTL_SEG });
  } catch {
    return json({ ok: false }, 500);
  }
});
