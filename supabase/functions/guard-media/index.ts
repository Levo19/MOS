// [882] MosGuard · cámara — Edge `guard-media`.
//   · SUBIR (desde el equipo MosGuard): POST {secreto, jpgB64, tipo?} → verifica el secreto contra
//     mos.yape_dispositivos, guarda el JPEG en el bucket privado 'guard' con service role, y anota la
//     ruta/hora en el dispositivo. Además apaga el one-shot `guard_foto_pedida`.
//   · URL (desde MOS): POST {action:'url', nombre} con JWT de app (claim) → devuelve una URL FIRMADA
//     temporal del último cuadro de ese equipo (el bucket es privado: nada es público).
//
// No toca audio ni nada más. La captura de Yapes es otra función; esta es solo media de resguardo.
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const SB_URL = Deno.env.get('SUPABASE_URL') || '';
const SB_SR  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const APPS_OK = new Set(['warehouseMos', 'mosExpress', 'MOS']);

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1]; if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64));
  } catch { return null; }
}
function b64ToBytes(b64: string): Uint8Array {
  const clean = b64.replace(/^data:[^;]+;base64,/, '');
  const bin = atob(clean); const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
async function rpc(fn: string, body: unknown): Promise<Record<string, unknown> | null> {
  try {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: SB_SR, Authorization: 'Bearer ' + SB_SR, 'Content-Type': 'application/json', 'Content-Profile': 'mos' },
      body: JSON.stringify(body),
    });
    return await r.json().catch(() => null);
  } catch { return null; }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  if (!SB_URL || !SB_SR) return json({ ok: false, error: 'sin service role' }, 500);
  const body = await req.json().catch(() => ({}));

  // ── URL firmada (para MOS) ──
  if (String(body.action || '') === 'url') {
    const claims = jwtClaims((req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim());
    if (!claims || !APPS_OK.has(String(claims.app))) return json({ ok: false, error: 'no autorizado' }, 401);
    const nombre = String(body.nombre || '').trim();
    if (!nombre) return json({ ok: false, error: 'falta nombre' }, 400);
    // ruta del último media (via una consulta directa a la tabla con service role)
    const q = await fetch(`${SB_URL}/rest/v1/yape_dispositivos?select=guard_media_path&nombre=eq.${encodeURIComponent(nombre)}&limit=1`, {
      headers: { apikey: SB_SR, Authorization: 'Bearer ' + SB_SR, 'Accept-Profile': 'mos' },
    });
    const rows = await q.json().catch(() => []);
    const pathMedia = Array.isArray(rows) && rows[0] ? String(rows[0].guard_media_path || '') : '';
    if (!pathMedia) return json({ ok: true, url: '' });
    const s = await fetch(`${SB_URL}/storage/v1/object/sign/guard/${pathMedia}`, {
      method: 'POST',
      headers: { apikey: SB_SR, Authorization: 'Bearer ' + SB_SR, 'Content-Type': 'application/json' },
      body: JSON.stringify({ expiresIn: 120 }),
    });
    const sj = await s.json().catch(() => null);
    const signed = sj && sj.signedURL ? SB_URL + '/storage/v1' + sj.signedURL : '';
    return json({ ok: true, url: signed });
  }

  // ── SUBIR (desde el equipo MosGuard) ──
  const secreto = String(body.secreto || '');
  const jpgB64 = String(body.jpgB64 || '');
  if (!secreto || !jpgB64) return json({ ok: false, error: 'faltan secreto o imagen' }, 400);
  // verificar el equipo por su secreto (misma regla que yape_ingesta): se marca la foto como recibida,
  // lo que también valida el secreto (si no existe, no_equipo). Reusamos yape_guard_media_recibida.
  const bytes = b64ToBytes(jpgB64);
  if (bytes.length < 500 || bytes.length > 6 * 1024 * 1024) return json({ ok: false, error: 'imagen fuera de rango' }, 400);
  // resolver nombre + validar secreto
  const dev = await rpc('yape_guard_por_secreto', { p: { secreto } });
  const nombre = dev && dev.ok ? String((dev as Record<string, unknown>).nombre || '') : '';
  if (!nombre) return json({ ok: false, error: 'DISPOSITIVO_NO_AUTORIZADO' }, 401);
  const tipo = String(body.tipo || 'foto') === 'frame' ? 'frame' : 'foto';
  const safe = nombre.replace(/[^A-Za-z0-9_-]/g, '_');
  const path = `${safe}/${tipo}-${Date.now()}.jpg`;
  const up = await fetch(`${SB_URL}/storage/v1/object/guard/${path}`, {
    method: 'POST',
    headers: { apikey: SB_SR, Authorization: 'Bearer ' + SB_SR, 'Content-Type': 'image/jpeg', 'x-upsert': 'true' },
    body: bytes,
  });
  if (!up.ok) { const t = await up.text().catch(() => ''); return json({ ok: false, error: 'storage ' + up.status + ': ' + t.slice(0, 160) }, 502); }
  await rpc('yape_guard_media_recibida', { p: { secreto, path } });
  return json({ ok: true, path });
});
