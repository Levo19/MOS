// Edge `espia-chunk` — sube un chunk de audio/video del espía a Storage (bucket `espia`) y lo registra
// (mos.espia_chunk_registrar). Reemplaza el subirChunkAudio/espiaSubirChunk que iban a GAS→Drive. Cero-GAS.
// AUTORIZACIÓN: claim app ∈ {mosExpress,warehouseMos,MOS} (el dispositivo manda su token minteado). verify_jwt=false
// (llamable con el token de app); un token forjado requeriría el secret del proyecto.
// SECRETS: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['mosExpress', 'warehouseMos', 'MOS']);
function json(p: unknown, s = 200): Response { return new Response(JSON.stringify(p), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } }); }
function jwtClaims(t: string): Record<string, unknown> | null {
  try { const part = t.split('.')[1]; if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64)); } catch { return null; }
}
function stripB64(s: string): string { const i = String(s || '').indexOf('base64,'); return i >= 0 ? String(s).substring(i + 7) : String(s || ''); }
function extFromMime(m: string): string {
  m = String(m || '').toLowerCase();
  if (m.includes('webm')) return 'webm'; if (m.includes('mp4')) return 'mp4';
  if (m.includes('ogg')) return 'ogg'; if (m.includes('mpeg') || m.includes('mp3')) return 'mp3';
  if (m.includes('wav')) return 'wav'; return 'bin';
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const auth = req.headers.get('Authorization') || '';
    const claims = jwtClaims(auth.replace(/^Bearer\s+/i, '').trim());
    if (!claims || !APPS_OK.has(String(claims.app))) return json({ ok: false, error: 'no autorizado (claim app)' }, 401);

    const SB_URL = Deno.env.get('SUPABASE_URL'); const SB_SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!SB_URL || !SB_SR) return json({ ok: false, error: 'secrets no configurados' }, 500);

    const body = await req.json().catch(() => ({}));
    const idSesion = String(body.idSesion || '').trim();
    const deviceId = String(body.deviceId || '').trim();
    const tipo = (String(body.tipo || 'audio').toLowerCase() === 'video') ? 'video' : 'audio';
    const idx = parseInt(String(body.idx ?? '0'), 10) || 0;
    const ts = String(body.ts || (Date.now()));
    const mime = String(body.mime || (tipo === 'video' ? 'video/webm' : 'audio/webm'));
    const b64 = stripB64(String(body.audioBase64 || body.videoBase64 || body.base64 || ''));
    if (!idSesion) return json({ ok: false, error: 'idSesion requerido' }, 400);
    if (!b64) return json({ ok: false, error: 'chunk vacío' }, 400);

    let bin: Uint8Array;
    try { bin = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)); } catch { return json({ ok: false, error: 'base64 inválido' }, 400); }

    // 1) subir al bucket `espia` (público) en <idSesion>/<tipo>-<idx>-<ts>.<ext>
    const path = `${idSesion}/${tipo}-${idx}-${ts}.${extFromMime(mime)}`.replace(/[^\w./-]/g, '_');
    const up = await fetch(`${SB_URL}/storage/v1/object/espia/${path}`, {
      method: 'POST',
      headers: { 'apikey': SB_SR, 'Authorization': 'Bearer ' + SB_SR, 'Content-Type': mime, 'x-upsert': 'true' },
      body: bin,
    });
    if (!up.ok) { const t = await up.text(); return json({ ok: false, error: 'storage ' + up.status + ': ' + t.slice(0, 120) }, 502); }
    const url = `${SB_URL}/storage/v1/object/public/espia/${path}`;

    // 2) registrar el chunk (service role → mos.espia_chunk_registrar)
    const rr = await fetch(`${SB_URL}/rest/v1/rpc/espia_chunk_registrar`, {
      method: 'POST',
      headers: { 'apikey': SB_SR, 'Authorization': 'Bearer ' + SB_SR, 'Content-Type': 'application/json', 'Content-Profile': 'mos' },
      body: JSON.stringify({ p: { idSesion, deviceId, tipo, idx, ts, url, mime, tamBytes: bin.length } }),
    });
    const rj = await rr.json().catch(() => null);
    if (!rj || rj.ok === false) return json({ ok: false, error: (rj && rj.error) || 'registro falló', url }, 500);
    return json({ ok: true, data: { url, idChunk: rj.idChunk || rj.data?.idChunk || '', tamBytes: bin.length } });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e).slice(0, 200) }, 500);
  }
});
