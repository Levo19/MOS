// Edge `print-adhesivo-plantilla` — imprime una plantilla del Editor de Adhesivos (cero GAS).
// PORT de AdhesivosPersonalizados.gs::imprimirAdhesivoPlantilla. La generación TSPL2 vive en
// ./tspl.mjs (verificada byte-a-byte vs el GAS por _verify_tspl.mjs).
//
// AUTORIZACIÓN: verify_jwt=true; exige claim app ∈ {MOS, mosExpress, warehouseMos}.
// SECRETS: PRINTNODE_API_KEY (ya seteado para los otros Edges de impresión).
// BODY: { idPlantilla, cantidad?=1, dryRun?=false }
//   dryRun=true → NO envía a PrintNode; devuelve byte count + preview (para verificar plumbing).
import { adhJson2tspl } from './tspl.mjs';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['MOS', 'mosExpress', 'warehouseMos']);

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

// offset de drift por etiqueta i (espeja _adhCalcularOffsetParaIndice del GAS)
function offsetParaIndice(calib: any, i: number): number {
  const comp = Math.round((calib.drift || 0) * ((calib.printsCount || 0) + i));
  let off = (calib.offsetBase || 0) + comp;
  if (off < -1) off = -1;
  if (off > 16) off = 16;
  return off;
}

async function rpc(fn: string, body: unknown): Promise<any> {
  const url = Deno.env.get('SUPABASE_URL')!;
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json',
               'Content-Profile': 'mos', 'Accept-Profile': 'mos' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`rpc ${fn}: HTTP ${res.status} ${text.substring(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'Solo POST' }, 405);

  const auth = req.headers.get('authorization') || '';
  const claims = jwtClaims(auth.replace(/^Bearer\s+/i, ''));
  const app = claims && typeof claims.app === 'string' ? claims.app : '';
  if (!APPS_OK.has(app)) return json({ ok: false, error: 'app no autorizada' }, 401);

  let idPlantilla = '', cantidad = 1, dryRun = false;
  try {
    const b = await req.json();
    idPlantilla = String(b?.idPlantilla || '').trim();
    cantidad = parseInt(b?.cantidad ?? 1) || 1;
    dryRun = b?.dryRun === true;
  } catch { return json({ ok: false, error: 'Body inválido' }, 400); }

  if (!idPlantilla) return json({ ok: false, error: 'idPlantilla requerido' }, 400);
  if (cantidad < 1 || cantidad > 100) return json({ ok: false, error: 'cantidad fuera de rango (1-100)' }, 400);

  // 1) datos (plantilla + iconos + impresora + calib) en 1 round-trip
  let data: any;
  try { data = await rpc('adhesivo_print_data', { p_id: idPlantilla }); }
  catch (e) { return json({ ok: false, error: 'datos: ' + (e as Error).message }, 502); }
  if (!data || data.ok !== true) return json({ ok: false, error: (data && data.error) || 'plantilla no disponible' }, 404);

  // 2) generar TSPL para las N etiquetas (con drift incremental, igual que el GAS)
  let bytes: number[] = [];
  try {
    for (let i = 0; i < cantidad; i++) {
      const off = offsetParaIndice(data.calib, i);
      bytes = bytes.concat(adhJson2tspl(data.json, off, data.iconos, data.calib));
    }
  } catch (e) { return json({ ok: false, error: 'TSPL gen: ' + (e as Error).message }, 500); }

  if (bytes.length === 0) return json({ ok: false, error: 'TSPL vacío — plantilla sin contenido' }, 400);
  if (bytes.length > 1024 * 1024) return json({ ok: false, error: `TSPL muy grande (${bytes.length} bytes)` }, 400);

  // base64 de los bytes raw — chunked (el spread `...bytes` revienta el stack en lotes grandes / 100 etiquetas)
  let _bin = '';
  for (let i = 0; i < bytes.length; i += 8192) _bin += String.fromCharCode.apply(null, bytes.slice(i, i + 8192));
  const b64 = btoa(_bin);

  if (dryRun) {
    const preview = new TextDecoder('latin1').decode(new Uint8Array(bytes.slice(0, 220)));
    return json({ ok: true, dryRun: true, bytes: bytes.length, base64Len: b64.length, printerId: data.printerId,
                  cantidad, nombre: data.nombre, preview });
  }

  // 3) PrintNode
  const apiKey = Deno.env.get('PRINTNODE_API_KEY');
  if (!apiKey) return json({ ok: false, error: 'PRINTNODE_API_KEY no configurado en la Edge' }, 500);
  const title = 'Aviso ' + (data.nombre ? `"${String(data.nombre).substring(0, 40)}" ` : '') + 'x' + cantidad;
  try {
    const res = await fetch('https://api.printnode.com/printjobs', {
      method: 'POST',
      headers: { 'Authorization': 'Basic ' + btoa(apiKey + ':'), 'Content-Type': 'application/json' },
      body: JSON.stringify({
        printerId: parseInt(data.printerId),
        title,
        contentType: 'raw_base64',
        content: b64,
        source: 'Edge:print-adhesivo-plantilla',
      }),
    });
    const body = await res.text();
    if (res.status >= 200 && res.status < 300) {
      try { await rpc('adhesivo_inc_prints', { p_qty: cantidad }); } catch (_) { /* contador best-effort */ }
      return json({ ok: true, jobId: body, cantidad, printerId: data.printerId });
    }
    return json({ ok: false, error: `PrintNode ${res.status}: ${body.substring(0, 200)}` }, 502);
  } catch (e) { return json({ ok: false, error: 'PrintNode fetch: ' + (e as Error).message }, 502); }
});
