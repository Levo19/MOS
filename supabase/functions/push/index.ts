// Edge Function `push` — envío de notificaciones FCM v1 (cero GAS). Port fiel de gas/Push.gs (_getFcmAccessToken
// + _enviarPushTokens): firma un JWT RS256 con la service-account, lo cambia por un access_token OAuth2 con scope
// firebase.messaging, y hace messages:send a cada token FCM. Devuelve resultado por token (ok / UNREGISTERED) para
// que el caller marque tokens muertos. La selección de audiencia (por rol/app/usuario) vive en quien llama (RPC o
// frontend) y le pasa la lista de tokens — esta Edge solo ENVÍA.
//
// AUTORIZACIÓN: verify_jwt=true (la plataforma verifica la firma) + claim app ∈ {warehouseMos,MOS,mosExpress}.
// La anon key (sin claim app) NO pasa. Un token forjado requeriría el secret del proyecto (server-side).
//
// SECRETS: FCM_PROJECT_ID, FCM_CLIENT_EMAIL, FCM_PRIVATE_KEY (service-account de proyectomos-push).

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['mosExpress', 'warehouseMos', 'MOS']);
const ICON = 'https://levo19.github.io/MOS/icons/icon-192.png';

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
function b64url(bytes: Uint8Array): string {
  let s = ''; for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}
function b64urlStr(str: string): string { return b64url(new TextEncoder().encode(str)); }

// PEM PKCS8 → CryptoKey (RS256). Tolera la llave con '\n' literal (como venía en Properties GAS) o saltos reales.
async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const norm = pem.replace(/\\n/g, '\n');
  const body = norm.replace(/-----BEGIN PRIVATE KEY-----/, '').replace(/-----END PRIVATE KEY-----/, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey('pkcs8', der.buffer, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
}

// Cache del access_token entre requests del mismo isolate (igual espíritu que GAS, menos llamadas a OAuth2).
let _tok: { value: string; exp: number } | null = null;
async function getAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (_tok && (_tok.exp - now) > 60) return _tok.value;
  const email = Deno.env.get('FCM_CLIENT_EMAIL');
  const pem = Deno.env.get('FCM_PRIVATE_KEY');
  if (!email || !pem) throw new Error('FCM_CLIENT_EMAIL/FCM_PRIVATE_KEY no configurados');
  const header = { alg: 'RS256', typ: 'JWT' };
  const claim = {
    iss: email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    exp: now + 3600,
    iat: now,
  };
  const signingInput = b64urlStr(JSON.stringify(header)) + '.' + b64urlStr(JSON.stringify(claim));
  const key = await importPrivateKey(pem);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(signingInput));
  const jwt = signingInput + '.' + b64url(new Uint8Array(sig));
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=' + encodeURIComponent(jwt),
  });
  const j = await r.json().catch(() => ({}));
  if (!j.access_token) throw new Error('FCM auth failed: ' + JSON.stringify(j).slice(0, 200));
  _tok = { value: j.access_token, exp: now + 3500 };
  return j.access_token;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const auth = req.headers.get('Authorization') || '';
    const claims = jwtClaims(auth.replace(/^Bearer\s+/i, '').trim());
    if (!claims || !APPS_OK.has(String(claims.app))) return json({ ok: false, error: 'no autorizado (claim app)' }, 401);

    const body = await req.json().catch(() => ({}));
    const op = String(body.op || 'send');
    if (op === 'auth_test') {
      // Smoke test: solo valida que la service-account autentica (no envía nada). Útil para verificar secrets.
      await getAccessToken();
      return json({ ok: true, data: { auth: 'ok' } });
    }
    if (op !== 'send') return json({ ok: false, error: 'op inválida' }, 400);

    const tokens: string[] = Array.isArray(body.tokens) ? body.tokens.map((t: unknown) => String(t || '')).filter(Boolean) : [];
    const title = String(body.title || 'MOS');
    const cuerpo = String(body.body || '');
    const data = (body.data && typeof body.data === 'object') ? body.data : null;
    if (!tokens.length) return json({ ok: false, error: 'tokens requerido' }, 400);

    const projectId = Deno.env.get('FCM_PROJECT_ID');
    if (!projectId) return json({ ok: false, error: 'FCM_PROJECT_ID no configurado' }, 500);
    const accessToken = await getAccessToken();
    const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

    const results: Array<{ token: string; ok: boolean; unregistered?: boolean; code?: number }> = [];
    let sent = 0;
    for (const token of tokens) {
      try {
        const msg: Record<string, unknown> = {
          token,
          notification: { title, body: cuerpo },
          webpush: { notification: { title, body: cuerpo, icon: ICON, badge: ICON, vibrate: [200, 100, 200] } },
        };
        if (data) msg.data = Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)]));
        const r = await fetch(url, {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + accessToken, 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: msg }),
        });
        if (r.status === 200) { sent++; results.push({ token: token.slice(0, 16), ok: true }); }
        else {
          let errCode = ''; const t = await r.text();
          try { const b = JSON.parse(t); errCode = b?.error?.details?.[0]?.errorCode || ''; } catch { /* */ }
          const unreg = errCode === 'UNREGISTERED' || r.status === 404;
          results.push({ token: token.slice(0, 16), ok: false, unregistered: unreg, code: r.status });
        }
      } catch (_) { results.push({ token: token.slice(0, 16), ok: false }); }
    }
    return json({ ok: true, data: { enviados: sent, total: tokens.length, results } });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e).slice(0, 200) }, 500);
  }
});
