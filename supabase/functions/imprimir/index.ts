// Edge Function `imprimir` — relay seguro PWA → PrintNode (reemplaza el salto a GAS en cada impresión).
// El browser arma el ticket ESC/POS (raw_base64) y lo manda acá; esta función lo reenvía a PrintNode con
// la API key guardada en un SECRET (nunca en el navegador). Más rápido que GAS (~100-300ms vs ~500ms-1s).
//
// AUTORIZACIÓN: la plataforma verifica la FIRMA del JWT contra el secret del proyecto (verify_jwt=true, igual
// que las RPC). Además exigimos el claim `app=mosExpress` → la anon key (pública, sin ese claim) NO pasa, y
// un token de otra app tampoco. Un token forjado requeriría el secret (solo server-side) → imposible.
//
// SECRET requerido (set por el usuario, NO entra al repo):
//   supabase secrets set PRINTNODE_API_KEY=<key> --project-ref rzbzdeipbtqkzjqdchqk

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

// Decodifica el payload del JWT (la FIRMA ya la validó la plataforma; acá solo leemos claims).
function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1];
    if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64));
  } catch {
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ status: 'error', mensaje: 'método no permitido' }, 405);

  try {
    // Apps del ecosistema autorizadas (la firma ya está verificada por la plataforma; rechazamos anon/otras apps).
    // multi-app: mosExpress + warehouseMos (PASO 5 — WH reusa esta Edge en vez de saltar a GAS para imprimir).
    const APPS_OK = new Set(['mosExpress', 'warehouseMos']);
    const auth = req.headers.get('Authorization') || '';
    const token = auth.replace(/^Bearer\s+/i, '').trim();
    const claims = jwtClaims(token);
    if (!claims || !APPS_OK.has(String(claims.app))) {
      return json({ status: 'error', mensaje: 'no autorizado (claim app)' }, 401);
    }

    const body = await req.json().catch(() => ({}));
    const printerId = parseInt(String(body.printerId), 10);
    const content = body.content;
    const title = String(body.title || 'MOSexpress');
    if (!printerId || printerId <= 0) return json({ status: 'error', mensaje: 'printerId inválido' }, 400);
    if (!content) return json({ status: 'error', mensaje: 'falta content (raw_base64)' }, 400);

    const key = Deno.env.get('PRINTNODE_API_KEY');
    if (!key) return json({ status: 'error', mensaje: 'PRINTNODE_API_KEY no configurada (secret)' }, 500);

    const pn = await fetch('https://api.printnode.com/printjobs', {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + btoa(key + ':'),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        printerId,
        title,
        contentType: 'raw_base64',
        content,
        source: String(claims.app || 'mos') + '-Edge',
      }),
    });
    const text = await pn.text();
    // PrintNode devuelve 201 + el id del printjob al crear
    if (pn.status !== 201) {
      return json({ status: 'error', mensaje: 'PrintNode ' + pn.status + ': ' + text }, 502);
    }
    return json({ status: 'success', printJobId: text });
  } catch (e) {
    return json({ status: 'error', mensaje: String((e as Error)?.message || e) }, 500);
  }
});
