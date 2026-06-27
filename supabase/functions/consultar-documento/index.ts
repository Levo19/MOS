// Edge Function `consultar-documento` — lookup EN VIVO SUNAT/RENIEC (APISPeru) 100% Supabase.
// Reemplaza el salto a GAS de meConsultarCliente cuando la sombra (mos.me_consultar_cliente) no tiene
// el doc. PORT EXACTO de MosExpress/gas/Catalogo.gs (misma cascada de códigos, mismos campos, mismo
// shape de respuesta) → drop-in: el frontend consume la misma forma que devolvía el GAS.
//
// AUTORIZACIÓN: la plataforma valida la FIRMA del JWT (verify_jwt=true). Exigimos claim
//   app ∈ {MOS, mosExpress, warehouseMos} (MOS facturación + ME POS hacen este lookup). La anon key no pasa.
//
// SECRETS (los setea el dueño; NO entran al repo):
//   supabase secrets set APISPERU_TOKEN=<token> --project-ref rzbzdeipbtqkzjqdchqk
//
// DEPLOY (lo corre el dueño):
//   supabase functions deploy consultar-documento --project-ref rzbzdeipbtqkzjqdchqk

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['MOS', 'mosExpress', 'warehouseMos']);

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

// [CACHE LOOKUP cero-GAS] Apenas APISPeru devuelve datos, guardamos el cliente en me.clientes_frecuentes
// (server-side, service-role). Así queda cacheado AUNQUE no se emita la venta → la próxima vez lo halla al
// instante y no se vuelve a pegar a APISPeru (ahorra cuota). insert-if-missing: NO pisa un nombre/dirección
// ya corregidos a mano (ignore-duplicates). Idempotente por `documento` (único). Fire-and-forget tolerante.
async function guardarClienteFrecuente(doc: string, nombre: string, direccion: string, tipo: string): Promise<void> {
  try {
    const url = Deno.env.get('SUPABASE_URL');
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !key || !doc || !nombre) return;
    if (doc === '66666') return;   // VARIOS no se cachea
    const tipo_doc = tipo === 'RUC' ? '6' : '1';
    await fetch(`${url}/rest/v1/clientes_frecuentes`, {
      method: 'POST',
      headers: {
        'apikey': key, 'Authorization': 'Bearer ' + key,
        'Content-Profile': 'me', 'Content-Type': 'application/json',
        'Prefer': 'resolution=ignore-duplicates',   // no pisa si ya existe
      },
      body: JSON.stringify({ documento: doc, nombre, tipo_doc, direccion: direccion || null }),
    });
  } catch { /* el cacheo nunca debe romper el lookup */ }
}

function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1];
    if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64));
  } catch { return null; }
}

// Una pasada contra APISPeru. Devuelve {_ok|_ko|_retry, ...}. Espejo de Catalogo.gs::_intentar.
async function intentar(url: string, doc: string, tipo: string, esRetry: boolean): Promise<Record<string, unknown>> {
  try {
    const response = await fetch(url, { method: 'GET' });
    const code = response.status;
    const body = await response.text();
    if (code === 401 || code === 403) {
      return { _ko: true, status: 'error', codigo: 'TOKEN_RECHAZADO', message: `Token APISPeru inválido o expirado (HTTP ${code}). Renovar.` };
    }
    if (code === 402 || /sin saldo|limit|excedid/i.test(body)) {
      return { _ko: true, status: 'error', codigo: 'SIN_SALDO', message: 'Token APISPeru sin saldo o cuota agotada. Renovar plan.' };
    }
    if (code === 404) {
      return { _ko: true, status: 'not_found', codigo: 'DOC_NO_ENCONTRADO', message: `Documento ${doc} no figura en ${tipo === 'ruc' ? 'SUNAT' : 'RENIEC'}.` };
    }
    if (code >= 500 && code < 600) {
      if (!esRetry) return { _retry: true };
      return { _ko: true, status: 'error', codigo: 'API_5XX', message: `APISPeru no responde (HTTP ${code}). Reintenta en unos segundos.` };
    }
    if (code !== 200) {
      return { _ko: true, status: 'error', codigo: 'HTTP_INESPERADO', message: `APISPeru respondió HTTP ${code}` };
    }
    let j: Record<string, unknown>;
    try { j = JSON.parse(body); }
    catch { return { _ko: true, status: 'error', codigo: 'PARSE_FAIL', message: `APISPeru devolvió texto inválido: ${body.substring(0, 100)}` }; }

    // APISPeru a veces devuelve 200 con {success:false} en vez de 404.
    if (j && j.success === false) {
      return { _ko: true, status: 'not_found', codigo: 'DOC_NO_ENCONTRADO',
               message: `Documento ${doc} no figura en ${tipo === 'ruc' ? 'SUNAT' : 'RENIEC'}${j.message ? ` (${j.message})` : ''}` };
    }

    let nombre = '';
    let direccion = '';
    if (tipo === 'dni') {
      const nombres = (j.nombres || j.nombre || j.first_name || '') as string;
      const apePat  = (j.apellidoPaterno || j.apellido_paterno || j.paterno || j.last_name || '') as string;
      const apeMat  = (j.apellidoMaterno || j.apellido_materno || j.materno || '') as string;
      nombre = [nombres, apePat, apeMat].filter(Boolean).join(' ').trim();
    } else {
      nombre    = String(j.razonSocial || j.razon_social || j.nombre || '').trim();
      direccion = String(j.direccion   || j.domicilio   || '').trim();
    }
    if (!nombre) {
      return { _ko: true, status: 'not_found', codigo: 'NOMBRE_VACIO', message: `APISPeru no devolvió nombre para ${doc}.` };
    }
    return { _ok: true, status: 'success', nombre, documento: doc, tipo: tipo === 'ruc' ? 'RUC' : 'DNI', fuente: 'api', direccion };
  } catch (e) {
    if (!esRetry) return { _retry: true };
    return { _ko: true, status: 'error', codigo: 'NET_ERROR', message: `Error de red: ${(e as Error).message}` };
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ status: 'error', codigo: 'METODO', message: 'Solo POST' }, 405);

  // Auth: la plataforma ya validó la firma (verify_jwt=true). Acá leemos el claim app.
  const auth = req.headers.get('authorization') || '';
  const claims = jwtClaims(auth.replace(/^Bearer\s+/i, ''));
  const app = claims && typeof claims.app === 'string' ? claims.app : '';
  if (!APPS_OK.has(app)) return json({ status: 'error', codigo: 'APP_NO_AUTORIZADA', message: 'app no autorizada' }, 401);

  let doc = '';
  try { const b = await req.json(); doc = String(b?.doc || b?.documento || '').replace(/\D/g, '').trim(); }
  catch { return json({ status: 'error', codigo: 'BODY', message: 'Body inválido' }, 400); }

  if (doc.length !== 8 && doc.length !== 11) {
    return json({ status: 'error', codigo: 'DOC_INVALIDO', message: 'Documento debe ser DNI (8) o RUC (11) dígitos.' }, 400);
  }

  const token = Deno.env.get('APISPERU_TOKEN');
  if (!token) return json({ status: 'error', codigo: 'TOKEN_NO_CONFIGURADO', message: 'APISPERU_TOKEN no está configurado en la Edge.' }, 500);

  const tipo = doc.length === 11 ? 'ruc' : 'dni';
  const url  = `https://dniruc.apisperu.com/api/v1/${tipo}/${doc}?token=${token}`;

  let r = await intentar(url, doc, tipo, false);
  if (r._retry) {
    await new Promise((res) => setTimeout(res, 800));   // backoff 800ms (igual que GAS)
    r = await intentar(url, doc, tipo, true);
  }
  const { _ok, _ko, _retry, ...payload } = r;
  void _ko; void _retry;
  // [CACHE LOOKUP cero-GAS] consulta exitosa → cachear en clientes_frecuentes (no bloquea si falla).
  if (_ok && payload.status === 'success') {
    await guardarClienteFrecuente(doc, String(payload.nombre || ''), String(payload.direccion || ''), String(payload.tipo || ''));
  }
  const httpStatus = payload.status === 'success' ? 200 : (payload.status === 'not_found' ? 404 : 502);
  return json(payload, httpStatus);
});
