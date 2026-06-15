// Edge Function `fotos` — proxy seguro PWA → Google Drive (subir / ver / eliminar). Reemplaza el DriveApp de GAS.
// El navegador manda la foto (base64) o pide verla; esta función opera en Drive con un SERVICE ACCOUNT (secret),
// la PWA nunca toca Drive. Organización: WH_FOTOS_ROOT/yyyyMM/<tipo>/<id>/foto_<n>.jpg (productos: productos/<cod>).
//
// AUTORIZACIÓN: verify_jwt + claim app ∈ {warehouseMos}. SECRETS:
//   GOOGLE_SA_JSON         = JSON del service account (con acceso Editor a la carpeta raíz)
//   WH_FOTOS_ROOT          = id de la carpeta raíz de fotos en Drive

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};
const APPS_OK = new Set(['warehouseMos', 'mosExpress']);
const DRIVE = 'https://www.googleapis.com/drive/v3';
const UPLOAD = 'https://www.googleapis.com/upload/drive/v3/files';

function json(p: unknown, status = 200): Response {
  return new Response(JSON.stringify(p), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1]; if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64));
  } catch { return null; }
}
function b64url(buf: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

// ── Service Account → OAuth access token (cacheado en memoria del isolate ~50 min) ──
let _tok: { v: string; exp: number } | null = null;
async function getToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (_tok && _tok.exp - now > 120) return _tok.v;
  const sa = JSON.parse(Deno.env.get('GOOGLE_SA_JSON') || '{}');
  if (!sa.client_email || !sa.private_key) throw new Error('GOOGLE_SA_JSON inválido');
  const enc = (o: unknown) => btoa(JSON.stringify(o)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const claim = { iss: sa.client_email, scope: 'https://www.googleapis.com/auth/drive',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 };
  const signingInput = enc({ alg: 'RS256', typ: 'JWT' }) + '.' + enc(claim);
  // importar private key PEM (PKCS8) → CryptoKey RS256
  const pem = sa.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der.buffer, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(signingInput));
  const jwt = signingInput + '.' + b64url(sig);
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=' + jwt,
  });
  const d = await res.json();
  if (!d.access_token) throw new Error('OAuth: ' + JSON.stringify(d));
  _tok = { v: d.access_token, exp: now + (d.expires_in || 3600) };
  return _tok.v;
}

// busca subcarpeta por nombre bajo parent; la crea si no existe → devuelve su id
async function ensureFolder(token: string, parent: string, name: string): Promise<string> {
  const q = encodeURIComponent(`name='${name.replace(/'/g, "\\'")}' and '${parent}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false`);
  const r = await fetch(`${DRIVE}/files?q=${q}&fields=files(id)&supportsAllDrives=true&includeItemsFromAllDrives=true`,
    { headers: { authorization: 'Bearer ' + token } });
  const d = await r.json();
  if (d.files && d.files.length) return d.files[0].id;
  const cr = await fetch(`${DRIVE}/files?supportsAllDrives=true`, {
    method: 'POST', headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
    body: JSON.stringify({ name, mimeType: 'application/vnd.google-apps.folder', parents: [parent] }),
  });
  const cd = await cr.json();
  if (!cd.id) throw new Error('crear carpeta: ' + JSON.stringify(cd));
  return cd.id;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const auth = req.headers.get('Authorization') || '';
    const claims = jwtClaims(auth.replace(/^Bearer\s+/i, '').trim());
    if (!claims || !APPS_OK.has(String(claims.app))) return json({ ok: false, error: 'no autorizado (claim app)' }, 401);
    const root = Deno.env.get('WH_FOTOS_ROOT');
    if (!root) return json({ ok: false, error: 'WH_FOTOS_ROOT no configurado (secret)' }, 500);

    // GET ?fileId= → ver la imagen (proxy)
    if (req.method === 'GET') {
      const fileId = new URL(req.url).searchParams.get('fileId');
      if (!fileId) return json({ ok: false, error: 'falta fileId' }, 400);
      const token = await getToken();
      const r = await fetch(`${DRIVE}/files/${fileId}?alt=media&supportsAllDrives=true`, { headers: { authorization: 'Bearer ' + token } });
      if (!r.ok) return json({ ok: false, error: 'Drive ' + r.status }, 502);
      return new Response(r.body, { status: 200, headers: { ...CORS, 'Content-Type': r.headers.get('content-type') || 'image/jpeg', 'Cache-Control': 'private, max-age=3600' } });
    }

    const body = await req.json().catch(() => ({}));
    const accion = String(body.accion || 'subir');
    const token = await getToken();

    if (accion === 'eliminar') {
      if (!body.fileId) return json({ ok: false, error: 'falta fileId' }, 400);
      const r = await fetch(`${DRIVE}/files/${body.fileId}?supportsAllDrives=true`, { method: 'DELETE', headers: { authorization: 'Bearer ' + token } });
      return json({ ok: r.status === 204 || r.ok });
    }

    if (accion === 'subir') {
      const tipo = String(body.tipo || '').trim();             // guia | preingreso | merma | producto
      const id = String(body.id || '').trim();
      const base64 = String(body.base64 || '');
      const mime = String(body.mime || 'image/jpeg');
      if (!tipo || !id || !base64) return json({ ok: false, error: 'faltan tipo/id/base64' }, 400);
      // path: productos/<cod>  |  yyyyMM/<tipo>s/<id>
      let folder: string;
      if (tipo === 'producto') {
        folder = await ensureFolder(token, await ensureFolder(token, root, 'productos'), id);
      } else {
        const yyyyMM = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Lima', year: 'numeric', month: '2-digit' }).format(new Date()).replace('-', '');
        const mes = await ensureFolder(token, root, yyyyMM);
        const ent = await ensureFolder(token, mes, tipo + 's');
        folder = await ensureFolder(token, ent, id);
      }
      // numerar foto_<n> según cuántas ya hay
      const q = encodeURIComponent(`'${folder}' in parents and trashed=false`);
      const lst = await fetch(`${DRIVE}/files?q=${q}&fields=files(id)&supportsAllDrives=true&includeItemsFromAllDrives=true`, { headers: { authorization: 'Bearer ' + token } });
      const n = (((await lst.json()).files) || []).length + 1;
      const nombre = `foto_${n}.${mime.includes('png') ? 'png' : 'jpg'}`;
      // upload multipart (metadata + media)
      const boundary = 'whfoto' + Math.floor(Date.now()).toString(36);
      const meta = JSON.stringify({ name: nombre, parents: [folder] });
      const pre = `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${meta}\r\n--${boundary}\r\nContent-Type: ${mime}\r\nContent-Transfer-Encoding: base64\r\n\r\n`;
      const multipart = pre + base64 + `\r\n--${boundary}--`;
      const up = await fetch(`${UPLOAD}?uploadType=multipart&supportsAllDrives=true&fields=id`, {
        method: 'POST', headers: { authorization: 'Bearer ' + token, 'content-type': `multipart/related; boundary=${boundary}` }, body: multipart,
      });
      const ud = await up.json();
      if (!ud.id) return json({ ok: false, error: 'upload: ' + JSON.stringify(ud) }, 502);
      // permiso público de lectura (link)
      await fetch(`${DRIVE}/files/${ud.id}/permissions?supportsAllDrives=true`, {
        method: 'POST', headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
        body: JSON.stringify({ role: 'reader', type: 'anyone' }),
      }).catch(() => {});
      return json({ ok: true, fileId: ud.id, nombre, url: `https://drive.google.com/uc?export=view&id=${ud.id}` });
    }

    return json({ ok: false, error: 'accion no soportada' }, 400);
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
