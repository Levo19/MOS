// Edge Function `mint-mos` — EMITE el JWT Supabase (HS256, claim app='MOS') que la PWA de MOS (master) usará,
// en fases siguientes, para hablar directo con PostgREST/RPC en vez de saltar a GAS. Clon fiel de `mint-wh`
// cambiando únicamente APP y la app aceptada en mos.dispositivos.
//
// ⚠️ INERTE (FASE 0A): hoy nadie del frontend la llama. MOS sigue operando por GAS. Esta función solo deja el
// cimiento listo. Cuando el frontend de MOS la consuma (Fase 1), reemplazará el mint vía GAS.
//
// APP-ID 'MOS' (MAYÚSCULAS) — confirmado contra mos.dispositivos (distinct app = {'MOS','mosExpress',
// 'warehouseMos'}; MOS NO usa minúsculas) y contra el GAS de MOS (Config.gs registra app:'MOS').
//
// AUTORIZACIÓN — mismo modelo que mint-wh (es quien EMITE el primer token, por eso es de las pocas Edges con
// verify_jwt=false; no puede exigir un JWT nuestro para entregar un JWT nuestro). El control de acceso vive en
// código:
//   1) Valida el deviceId contra mos.dispositivos con la SERVICE_ROLE key (server-side, nunca al cliente):
//      estado='ACTIVO' y app ∈ {null, '', 'MOS'}. FAIL-CLOSED: cualquier error/no-match → no token.
//   2) app='MOS' y exp están HARDCODEADOS server-side; el body solo aporta el deviceId (= sub). El cliente no
//      puede pedir otra app ni un exp más largo.
//   3) Respuesta GENÉRICA {ok:false} ante cualquier fallo (anti-enumeración).
// El secret de firma (WH_JWT_SECRET) jamás sale de la función. Un token forjado requeriría ese secret.
//
// SECRETS:
//   WH_JWT_SECRET              — secret HS256 del PROYECTO (el mismo con el que la plataforma verifica las RPC).
//                                Es el JWT Secret del proyecto, no es exclusivo de WH → se reusa para firmar el
//                                token de MOS (un solo secret de proyecto). Ya está seteado; NO se crea uno nuevo.
//   SUPABASE_URL               — base del proyecto (PostgREST) — auto-inyectado.
//   SUPABASE_SERVICE_ROLE_KEY  — bypassa RLS para leer mos.dispositivos — auto-inyectado.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const TTL_SEG = 1800;   // 30 min. HARDCODEADO (no se toma del body).
const APP = 'MOS';      // claim app HARDCODEADO server-side (NO se toma del body).

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

function b64url(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}
function b64urlStr(str: string): string {
  return b64url(new TextEncoder().encode(str));
}

// Firma HS256 (WebCrypto HMAC-SHA256) — sin dependencias externas.
async function firmarJWT(payload: Record<string, unknown>, secret: string): Promise<string> {
  const header = { alg: 'HS256', typ: 'JWT' };
  const signingInput = b64urlStr(JSON.stringify(header)) + '.' + b64urlStr(JSON.stringify(payload));
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(signingInput));
  return signingInput + '.' + b64url(new Uint8Array(sig));
}

// Valida el deviceId contra mos.dispositivos vía PostgREST con la service-role key. FAIL-CLOSED.
async function deviceOk(deviceId: string): Promise<boolean> {
  try {
    const url = Deno.env.get('SUPABASE_URL');
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !key) return false;
    // Filtro server-side: estado=ACTIVO AND (app is null OR app in ('', 'MOS')).
    const q = `id_dispositivo=eq.${encodeURIComponent(deviceId)}`
      + `&estado=eq.ACTIVO`
      + `&or=(app.is.null,app.eq.,app.eq.${APP})`
      + `&select=id_dispositivo&limit=1`;
    const r = await fetch(`${url}/rest/v1/dispositivos?${q}`, {
      headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Accept-Profile': 'mos' },
    });
    if (!r.ok) return false;
    const rows = await r.json().catch(() => []);
    return Array.isArray(rows) && rows.length > 0;
  } catch { return false; }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const deviceId = String((body && body.deviceId) || '').trim();
    if (!deviceId) return json({ ok: false }, 400);   // genérico

    const secret = Deno.env.get('WH_JWT_SECRET');
    if (!secret) return json({ ok: false }, 500);      // genérico

    if (!(await deviceOk(deviceId))) return json({ ok: false }, 401);   // genérico

    const now = Math.floor(Date.now() / 1000);
    const exp = now + TTL_SEG;
    // app y exp NO se toman del body — el cliente solo influye en `sub` (deviceId ya validado).
    const payload = {
      iss: 'supabase',
      role: 'authenticated',
      aud: 'authenticated',
      sub: deviceId,
      app: APP,
      iat: now,
      exp,
    };
    const token = await firmarJWT(payload, secret);
    return json({ ok: true, token, exp });
  } catch {
    return json({ ok: false }, 500);   // genérico
  }
});
