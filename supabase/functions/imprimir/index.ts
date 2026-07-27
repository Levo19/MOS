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
    // [Reparación #4] + MOS: el panel admin imprime el ticket de venta (reimpresión) directo por esta Edge,
    // armando el ESC/POS client-side (cero GAS). MOS es app del ecosistema (firma JWT ya validada).
    const APPS_OK = new Set(['mosExpress', 'warehouseMos', 'MOS']);
    const auth = req.headers.get('Authorization') || '';
    const token = auth.replace(/^Bearer\s+/i, '').trim();
    const claims = jwtClaims(token);
    if (!claims || !APPS_OK.has(String(claims.app))) {
      return json({ status: 'error', mensaje: 'no autorizado (claim app)' }, 401);
    }

    const body = await req.json().catch(() => ({}));

    // [watch-job] Consulta READ-ONLY del estado de un printjob para detectar jobs que mueren en 'error'
    // (equipo "Connected" en PrintNode pero microcorte de red al descargar el PDF → "Could not resolve host").
    // El semáforo de conexión no ve esto: conectado ≠ imprimió. Devuelve done/error + último estado.
    if (String(body.op || '') === 'states') {
      const jobId = parseInt(String(body.jobId), 10);
      if (!jobId || jobId <= 0) return json({ status: 'error', mensaje: 'jobId inválido' }, 400);
      const keyS = Deno.env.get('PRINTNODE_API_KEY');
      if (!keyS) return json({ status: 'error', mensaje: 'PRINTNODE_API_KEY no configurada (secret)' }, 500);
      const st = await fetch('https://api.printnode.com/printjobs/' + jobId + '/states', {
        headers: { 'Authorization': 'Basic ' + btoa(keyS + ':') },
      });
      const stTxt = await st.text();
      if (!st.ok) return json({ status: 'error', mensaje: 'PrintNode ' + st.status + ': ' + stTxt }, 502);
      let parsed: unknown = [];
      try { parsed = JSON.parse(stTxt); } catch { parsed = []; }
      // PrintNode devuelve un array (por printjob) de arrays de estados {state,message,timestamp,...}.
      const flat = (Array.isArray(parsed) ? (parsed as unknown[]).flat() : []) as Array<Record<string, unknown>>;
      const estados = flat.map((s) => String(s.state || ''));
      const done = estados.includes('done');
      const error = estados.includes('error');
      const last = flat.length ? flat[flat.length - 1] : null;
      return json({
        status: 'success', jobId, estados, done, error, terminal: done || error,
        last: last ? { state: String(last.state || ''), message: String(last.message || '') } : null,
      });
    }

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
