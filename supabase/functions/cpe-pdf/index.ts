// Edge Function `cpe-pdf` — proxy de SOLO LECTURA del PDF de un comprobante (boleta/factura) de ME.
//
// NubeFact protege su PDF con X-Frame-Options: SAMEORIGIN y NO envía cabeceras CORS → el navegador
// no puede ni embeberlo ni leer el archivo (fetch cross-origin bloqueado). Esta función, server-side:
//   1) resuelve nf_enlace desde me.ventas por id_venta (service role),
//   2) descarga el PDF de NubeFact (server-side no hay CORS/XFO),
//   3) lo re-sirve desde NUESTRO dominio con CORS → el front lo descarga / adjunta a WhatsApp / imprime.
//
// SSRF-guard: SOLO acepta id_venta (nunca una URL del cliente) y solo baja hosts *.nubefact.com.
// Guard "es-PDF": si NubeFact redirige (ej. comprobantes DEMO → /find_document devuelve HTML) responde 404.
// AUTORIZACIÓN: verify_jwt=true (firma verificada por la plataforma) + claim app ∈ (MOS, mosExpress).

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jerr(payload: unknown, status = 400): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1]; if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64));
  } catch { return null; }
}
function okHost(u: string): boolean {
  try { const h = new URL(u); return h.protocol === 'https:' && /(^|\.)nubefact\.com$/i.test(h.hostname); }
  catch { return false; }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return jerr({ error: 'METHOD_NOT_ALLOWED' }, 405);

  // ── auth: claim app del JWT (la firma ya la validó la plataforma con verify_jwt=true) ──
  const auth = req.headers.get('Authorization') || '';
  const claims = jwtClaims(auth.replace(/^Bearer\s+/i, ''));
  const app = claims ? String((claims as Record<string, unknown>).app || '') : '';
  if (app !== 'MOS' && app !== 'mosExpress') return jerr({ error: 'APP_NO_AUTORIZADA' }, 401);

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* body vacío */ }
  const idVenta = String(body.id_venta || '').trim();
  if (!idVenta) return jerr({ error: 'FALTA_ID_VENTA' }, 400);

  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return jerr({ error: 'CONFIG' }, 500);

  // ── lookup nf_enlace por id_venta (service role, schema me) ──
  const q = await fetch(`${url}/rest/v1/ventas?select=nf_enlace,correlativo,nf_estado&id_venta=eq.${encodeURIComponent(idVenta)}&limit=1`, {
    headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Accept-Profile': 'me' },
  });
  if (!q.ok) return jerr({ error: 'LOOKUP_FAIL', http: q.status }, 502);
  const rows = await q.json().catch(() => []);
  const row = Array.isArray(rows) ? rows[0] : null;
  const pdfUrl = row ? String(row.nf_enlace || '') : '';
  if (!pdfUrl) return jerr({ error: 'SIN_PDF' }, 404);
  if (!okHost(pdfUrl)) return jerr({ error: 'URL_NO_PERMITIDA' }, 400);

  // ── descargar el PDF de NubeFact (server-side sigue redirects; no hay CORS/XFO acá) ──
  let pdf: Response;
  try { pdf = await fetch(pdfUrl, { headers: { 'Accept': 'application/pdf,*/*' }, redirect: 'follow' }); }
  catch (e) { return jerr({ error: 'NUBEFACT_FETCH_FAIL', detalle: String((e as Error)?.message || e) }, 502); }
  const ct = (pdf.headers.get('Content-Type') || '').toLowerCase();
  if (!pdf.ok || !ct.includes('pdf')) {
    // p.ej. comprobantes DEMO → 302 a /find_document (HTML). No es un PDF real.
    return jerr({ error: 'PDF_NO_DISPONIBLE', estado: row?.nf_estado || '', detalle: 'NubeFact no sirvió un PDF (¿comprobante demo o no publicado?)' }, 404);
  }
  const bytes = await pdf.arrayBuffer();
  // doble-check por magic bytes %PDF
  const h = new Uint8Array(bytes.slice(0, 5));
  if (!(h[0] === 0x25 && h[1] === 0x50 && h[2] === 0x44 && h[3] === 0x46)) {
    return jerr({ error: 'PDF_NO_DISPONIBLE', estado: row?.nf_estado || '' }, 404);
  }

  const nombre = String(row?.correlativo || idVenta).replace(/[^\w.-]+/g, '_') + '.pdf';
  const dispo = String(body.download || '') === '1' ? 'attachment' : 'inline';
  return new Response(bytes, {
    status: 200,
    headers: { ...CORS, 'Content-Type': 'application/pdf', 'Content-Disposition': `${dispo}; filename="${nombre}"` },
  });
});
