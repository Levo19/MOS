// Edge Function `printers` — LISTAR + VERIFICAR impresoras 100% Supabase (reemplaza el salto a GAS de
// listarImpresorasPN / verificarImpresoraAhora, que tardaban ~9s por la latencia de UrlFetchApp en GAS).
//
// A DIFERENCIA de la Edge `imprimir` (RELAY de printjobs: el browser arma el ESC/POS), esta función:
//   • LEE el catálogo MOS (mos.impresoras_lista / mos.zonas_lista / mos.estaciones_lista) con la
//     SERVICE_ROLE key (bypassa RLS, igual que riz-print), y
//   • consulta el estado EN VIVO de PrintNode (/printers + /computers) con PRINTNODE_API_KEY,
//   • y MERGEA ambos para devolver el MISMO shape que el GAS listarImpresorasPN (campo por campo),
//     porque ese shape lo consume el frontend (liquidaciones / costos guía / picker universal).
//
// OPERACIONES (body.op):
//   • 'list'   → { ok:true, data:[ {id,printNodeId,nombre,nombrePN,nombreCatalogo,computer,computerState,
//                  printerStateRaw,state,reason,icon,color,online,registrada,idEstacion,estacionNombre,
//                  idZona,zonaNombre,appOrigen,tipo}, ... ] }   ← BYTE-equivalente a GAS
//   • 'verify' → { ok:true, data:{ printerId,nombrePN,computer,computerState,printerStateRaw,state,
//                  reason,icon,color,online } }                  ← BYTE-equivalente a GAS verificarImpresoraAhora
//
// AUTORIZACIÓN: la plataforma verifica la FIRMA del JWT (verify_jwt=true). Exigimos claim `app ∈
// {MOS, mosExpress, warehouseMos}` — ME y WH también consultan estado de impresoras (chip 🟢/🔴 + wizard).
// Antes era solo {MOS} → ME/WH recibían 401 → chip "verificando eterno". La anon key no pasa.
//
// SECRETS (los setea el dueño; NO entran al repo):
//   supabase secrets set PRINTNODE_API_KEY=<key> --project-ref rzbzdeipbtqkzjqdchqk
//   SUPABASE_URL              — auto-inyectado (PostgREST)
//   SUPABASE_SERVICE_ROLE_KEY — auto-inyectado (lee mos.* sin RLS)
//
// DEPLOY (lo corre el dueño):
//   supabase functions deploy printers --project-ref rzbzdeipbtqkzjqdchqk

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['MOS', 'mosExpress', 'warehouseMos']);

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

// Decodifica el payload del JWT (la FIRMA ya la validó la plataforma; acá solo leemos claims).
function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1];
    if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64));
  } catch { return null; }
}

// ── PORT EXACTO de gas/Evaluaciones.gs::_interpretarEstadoImpresora ──
// MISMA cascada, mismos regex, mismos {state,reason,icon,color}. Cualquier divergencia rompería el render.
function interpretarEstado(printerState: unknown, computerState: unknown, descripcion: unknown):
  { state: string; reason: string; icon: string; color: string } {
  const cs = String(computerState || '').toLowerCase().trim();
  const ps = String(printerState || '').toLowerCase().trim();
  const ds = String(descripcion || '').toLowerCase();
  const combined = ps + ' ' + ds;

  // 1. PC desconectada gana sobre cualquier otro estado del printer
  if (cs && cs !== 'connected') {
    return { state: 'PC_OFFLINE', reason: 'PC desconectada · revisa internet o cliente PrintNode', icon: '🔌', color: 'orange' };
  }
  // 2. Detalles específicos del driver
  if (/jam|atasco|atasc/.test(combined)) {
    return { state: 'ATASCO', reason: 'Papel atascado · revisa la bandeja', icon: '⚠', color: 'red' };
  }
  if (/paper.?out|out.?of.?paper|sin.?papel|no.?paper|paperout/.test(combined)) {
    return { state: 'SIN_PAPEL', reason: 'Sin papel · cargar bandeja', icon: '📄', color: 'yellow' };
  }
  if (/ink|toner|tinta|cartridge|low.?supplies/.test(combined)) {
    return { state: 'SIN_TINTA', reason: 'Tinta/toner bajo o ausente', icon: '🟡', color: 'yellow' };
  }
  if (/door.?open|tapa|cover.?open|cover\-?open/.test(combined)) {
    return { state: 'TAPA_ABIERTA', reason: 'Tapa abierta · cerrar para imprimir', icon: '🚪', color: 'yellow' };
  }
  // 3. Estados crudos de PrintNode
  if (ps === 'paused')   return { state: 'PAUSED',   reason: 'Pausada en la cola del OS', icon: '⏸', color: 'gray' };
  if (ps === 'disabled') return { state: 'DISABLED', reason: 'Deshabilitada manualmente', icon: '🚫', color: 'gray' };
  if (ps === 'error' || /error/.test(ps))
    return { state: 'ERROR', reason: String(descripcion || '') || 'Error del driver', icon: '⚠', color: 'red' };
  if (ps === 'offline' || ps === 'disconnected')
    return { state: 'PRINTER_OFFLINE', reason: 'Impresora apagada o cable desconectado', icon: '🔴', color: 'red' };
  if (ps === 'online') return { state: 'ONLINE', reason: 'Lista para imprimir', icon: '🟢', color: 'green' };
  if (ps === 'unknown' || !ps)
    return { state: 'UNKNOWN', reason: 'Estado no reportado por driver', icon: '❔', color: 'gray' };
  // Caso fallback — estado raro que no reconocemos
  return { state: 'ERROR', reason: 'Estado: ' + String(printerState), icon: '⚠', color: 'red' };
}

// Lee una RPC del esquema mos con SERVICE_ROLE (bypassa RLS). Devuelve el array de `data` o [] si falla.
async function rpcMosData(fn: string, p: Record<string, unknown>): Promise<any[]> {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('SUPABASE_URL/SERVICE_ROLE_KEY no disponibles');
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'apikey': key, 'Authorization': 'Bearer ' + key,
      'Accept-Profile': 'mos', 'Content-Profile': 'mos', 'Content-Type': 'application/json',
    },
    body: JSON.stringify({ p }),
  });
  const txt = await r.text();
  if (!r.ok) throw new Error('rpc ' + fn + ' HTTP ' + r.status + ': ' + txt);
  let j: any; try { j = JSON.parse(txt); } catch { return []; }
  return (j && Array.isArray(j.data)) ? j.data : [];
}

const PN_BASE = 'https://api.printnode.com';

// ── op:'list' — MERGE catálogo MOS + estado PrintNode → shape de listarImpresorasPN ──
async function opList(pnKey: string): Promise<Response> {
  const authHeader = 'Basic ' + btoa(pnKey + ':');

  // 1) PrintNode: printers + computers EN PARALELO (igual que el GAS fetchAll).
  let pnList: any[] = [], pnComps: any[] = [];
  try {
    const [rp, rc] = await Promise.all([
      fetch(`${PN_BASE}/printers`,  { headers: { 'Authorization': authHeader } }),
      fetch(`${PN_BASE}/computers`, { headers: { 'Authorization': authHeader } }),
    ]);
    if (!rp.ok) {
      const body = await rp.text();
      return json({ ok: false, error: 'PrintNode printers HTTP ' + rp.status + ': ' + body.substring(0, 200) }, 502);
    }
    pnList  = await rp.json().catch(() => []);
    pnComps = rc.ok ? await rc.json().catch(() => []) : [];
  } catch (e) {
    return json({ ok: false, error: 'PrintNode fetch fallo: ' + String((e as Error)?.message || e) }, 502);
  }
  if (!Array.isArray(pnList))  pnList = [];
  if (!Array.isArray(pnComps)) pnComps = [];

  // Mapa idComputer → {name,state} (state en minúsculas, igual que GAS).
  const compMap: Record<string, { name: string; state: string }> = {};
  pnComps.forEach((c: any) => {
    compMap[String(c.id)] = { name: String(c.name || ''), state: String(c.state || '').toLowerCase() };
  });
  // Mapa idPrinter → printer crudo.
  const printerMap: Record<string, any> = {};
  pnList.forEach((p: any) => { printerMap[String(p.id)] = p; });

  // 2) Catálogo MOS (service_role). Lookups de nombres zona/estación (friendly labels).
  let cat: any[] = [], zonas: any[] = [], estaciones: any[] = [];
  try {
    [cat, zonas, estaciones] = await Promise.all([
      rpcMosData('impresoras_lista', {}),
      rpcMosData('zonas_lista', {}),
      rpcMosData('estaciones_lista', {}),
    ]);
  } catch (e) {
    return json({ ok: false, error: 'No se pudo leer catálogo IMPRESORAS: ' + String((e as Error)?.message || e) }, 500);
  }
  const zonaNom: Record<string, string> = {};
  zonas.forEach((z: any) => { zonaNom[String(z.idZona)] = String(z.nombre || z.idZona); });
  const estNom: Record<string, string> = {};
  estaciones.forEach((e: any) => { estNom[String(e.idEstacion)] = String(e.nombre || e.idEstacion); });

  // 3) Iterar el CATÁLOGO (no PrintNode) — replica EXACTA del GAS (reporta SIN_ID e ID_INVALIDO).
  const data: any[] = [];
  cat.forEach((r: any) => {
    // El RPC ya devuelve activo como '1'/'0'; aceptamos también 'true' por compat.
    const act = String(r.activo) === '1' || String(r.activo).toLowerCase() === 'true';
    if (!act) return;
    const pid       = String(r.printNodeId || '').trim();
    const nombreCat = String(r.nombre || '');
    const idEst     = String(r.idEstacion || '');
    const idZona    = String(r.idZona || '');
    const tipo      = String(r.tipo || 'TICKET');

    let diag: { state: string; reason: string; icon: string; color: string };
    let compName = '', compState = '', printerName = '', printerStateRaw = '';

    if (!pid) {
      diag = { state: 'SIN_ID', reason: 'Falta asignar ID de PrintNode', icon: '⚙', color: 'gray' };
    } else if (!printerMap[pid]) {
      diag = { state: 'ID_INVALIDO', reason: 'ID ' + pid + ' no existe en PrintNode (verifica que esté registrada)', icon: '❓', color: 'red' };
    } else {
      const p = printerMap[pid];
      const cid = (p.computer && p.computer.id) ? String(p.computer.id) : '';
      const comp = compMap[cid] || { name: '', state: '' };
      compName = comp.name || (p.computer && p.computer.name ? String(p.computer.name) : '');
      compState = comp.state || '';
      printerName = String(p.name || '');
      printerStateRaw = String(p.state || '');
      const desc = String(p.description || (p.default && 'default') || '');
      diag = interpretarEstado(printerStateRaw, compState, desc);
    }

    data.push({
      id:               pid ? parseInt(pid, 10) : null,
      printNodeId:      pid,
      nombrePN:         printerName,
      nombre:           nombreCat || printerName,
      nombreCatalogo:   nombreCat,
      computer:         compName,
      computerState:    compState,
      printerStateRaw:  printerStateRaw,
      state:            diag.state,
      reason:           diag.reason,
      icon:             diag.icon,
      color:            diag.color,
      online:           diag.state === 'ONLINE',
      registrada:       true,
      idEstacion:       idEst,
      estacionNombre:   estNom[idEst] || idEst || '',
      idZona:           idZona,
      zonaNombre:       zonaNom[idZona] || idZona || '',
      appOrigen:        String(r.appOrigen || ''),
      tipo:             tipo,
    });
  });

  return json({ ok: true, data });
}

// ── op:'verify' — estado FRESH de UNA impresora → shape de verificarImpresoraAhora ──
async function opVerify(pnKey: string, printerId: unknown): Promise<Response> {
  const pid = String(printerId == null ? '' : printerId).trim();
  if (!pid) return json({ ok: false, error: 'Requiere printerId' }, 400);
  const authHeader = 'Basic ' + btoa(pnKey + ':');
  let resp: Response;
  try {
    resp = await fetch(`${PN_BASE}/printers/${encodeURIComponent(pid)}`, { headers: { 'Authorization': authHeader } });
  } catch (e) {
    return json({ ok: false, error: 'PrintNode fetch fallo: ' + String((e as Error)?.message || e) }, 502);
  }
  if (resp.status === 404) {
    return json({ ok: true, data: { state: 'ID_INVALIDO', reason: 'ID ' + pid + ' no existe en PrintNode', icon: '❓', color: 'red', online: false, printerId: pid } });
  }
  if (resp.status !== 200) {
    return json({ ok: false, error: 'PrintNode HTTP ' + resp.status }, 502);
  }
  const jj = await resp.json().catch(() => null);
  const p = Array.isArray(jj) ? jj[0] : jj;
  if (!p) return json({ ok: true, data: { state: 'ID_INVALIDO', reason: 'No reportada', icon: '❓', color: 'red', online: false } });

  let compState = '', compName = '';
  if (p.computer) {
    compName = String(p.computer.name || '');
    compState = String(p.computer.state || '').toLowerCase();
  }
  const diag = interpretarEstado(String(p.state || ''), compState, String(p.description || ''));
  return json({ ok: true, data: {
    printerId:       pid,
    nombrePN:        String(p.name || ''),
    computer:        compName,
    computerState:   compState,
    printerStateRaw: String(p.state || ''),
    state:           diag.state,
    reason:          diag.reason,
    icon:            diag.icon,
    color:           diag.color,
    online:          diag.state === 'ONLINE',
  } });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);

  try {
    const auth = req.headers.get('Authorization') || '';
    const claims = jwtClaims(auth.replace(/^Bearer\s+/i, '').trim());
    if (!claims || !APPS_OK.has(String(claims.app))) return json({ ok: false, error: 'no autorizado (claim app)' }, 401);

    const body = await req.json().catch(() => ({}));
    const op = String(body.op || 'list');

    const key = Deno.env.get('PRINTNODE_API_KEY');
    if (!key) return json({ ok: false, error: 'PRINTNODE_API_KEY no configurado (secret)' }, 500);

    if (op === 'verify') return await opVerify(key, body.printerId != null ? body.printerId : body.id);
    return await opList(key);   // op ausente o 'list'
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
