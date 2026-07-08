// Edge `espia-chunk` — sube un chunk de media del espía a Supabase Storage + registra metadata (cero-GAS).
// Reemplaza subirChunkAudio (audio) + espiaSubirChunk (video/screen), que guardaban en Drive vía GAS.
// Requiere claim app (mosExpress/warehouseMos/MOS) — solo dispositivos del ecosistema suben. NO es dinero.
//
// Body: { idSesion?, deviceId, tipo:'audio'|'audio_video'|'screen', idx?, ts?, base64, mime }
// SECRETS: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['mosExpress', 'warehouseMos', 'MOS']);
function json(p: unknown, s = 200): Response { return new Response(JSON.stringify(p), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } }); }
function claims(t: string): Record<string, unknown> | null {
  try { const p = t.split('.')[1]; if (!p) return null; const b = p.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(p.length / 4) * 4, '='); return JSON.parse(atob(b)); } catch { return null; }
}
function stripB64(s: string): string { const i = String(s || '').indexOf('base64,'); return i >= 0 ? String(s).substring(i + 7) : String(s || ''); }
function extFor(mime: string): string { const m = String(mime || ''); if (m.indexOf('mp4') >= 0) return 'mp4'; if (m.indexOf('ogg') >= 0) return 'ogg'; if (m.indexOf('webm') >= 0) return 'webm'; return 'bin'; }

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const auth = req.headers.get('Authorization') || '';
    const cl = claims(auth.replace(/^Bearer\s+/i, '').trim());
    if (!cl || !APPS_OK.has(String(cl.app))) return json({ ok: false, error: 'no autorizado (claim app)' }, 401);

    const SB = Deno.env.get('SUPABASE_URL'); const SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!SB || !SR) return json({ ok: false, error: 'Supabase secrets no configurados' }, 500);

    const b = await req.json().catch(() => ({}));
    const deviceId = String(b.deviceId || '').trim();
    const tipo = String(b.tipo || 'audio').toLowerCase();
    const b64 = stripB64(String(b.base64 || b.audioBase64 || b.contenido || ''));
    const mime = String(b.mime || b.mimeType || 'audio/webm');
    const ts = parseInt(String(b.ts || Date.now()), 10) || Date.now();
    const idx = parseInt(String(b.idx || 0), 10) || 0;
    if (!deviceId || !b64) return json({ ok: false, error: 'Requiere deviceId y contenido' }, 400);
    if (b64.length > 28 * 1024 * 1024) return json({ ok: false, error: 'Chunk demasiado grande (>20MB)' }, 400);

    // decodificar + subir a Storage: bucket `espia` → <deviceId>/<deviceId>_<tipo>_<ts>.<ext>
    const bin = Uint8Array.from(atob(b64), (ch) => ch.charCodeAt(0));
    const path = `${deviceId}/${deviceId}_${tipo}_${ts}.${extFor(mime)}`.replace(/[^\w./-]/g, '_');
    const up = await fetch(`${SB}/storage/v1/object/espia/${path}`, {
      method: 'POST', headers: { 'apikey': SR, 'Authorization': 'Bearer ' + SR, 'Content-Type': mime, 'x-upsert': 'true' }, body: bin,
    });
    if (!up.ok) return json({ ok: false, error: 'Storage ' + up.status + ': ' + (await up.text()).slice(0, 120) }, 502);
    const url = `${SB}/storage/v1/object/public/espia/${path}`;

    // registrar metadata (service role)
    const rr = await fetch(`${SB}/rest/v1/rpc/espia_chunk_registrar`, {
      method: 'POST', headers: { 'apikey': SR, 'Authorization': 'Bearer ' + SR, 'Content-Type': 'application/json', 'Content-Profile': 'mos' },
      body: JSON.stringify({ p: { idSesion: String(b.idSesion || b.sesionId || ''), deviceId, tipo, idx, ts, url, mime, tamBytes: bin.length } }),
    });
    const rj = await rr.json().catch(() => null);
    return json({ ok: true, data: { idChunk: (rj && rj.idChunk) || '', url } });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e).slice(0, 200) }, 500);
  }
});
