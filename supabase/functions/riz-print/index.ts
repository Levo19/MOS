// Edge Function `riz-print` — impresión 80mm NIVEL PROFESIONAL del módulo RIZ (Reposición Inteligente por Zona).
//
// A DIFERENCIA de la Edge `imprimir` (que solo es un RELAY: el browser arma el ESC/POS), esta función
// CONSTRUYE el ESC/POS server-side a partir de las RPCs determinísticas (mos.zona_ticket_dia /
// mos.zona_lista_compras) leídas con la SERVICE_ROLE key, y luego lo manda a PrintNode. Así el frontend
// no tiene que reimplementar el builder ni traer todos los datos: pide {tipo,zona,fecha/semana,printerId}.
//
// AUTORIZACIÓN: la plataforma verifica la FIRMA del JWT (verify_jwt=true). Además exigimos el claim
// `app ∈ {MOS}` (igual patrón que /functions/ia y /functions/imprimir). La anon key (sin claim) NO pasa,
// y un token de otra app tampoco. El token de MOS lo emite `mint-mos` con app='MOS' (MAYÚSCULAS).
//
// SECRETS (los setea el dueño; NO entran al repo):
//   supabase secrets set PRINTNODE_API_KEY=<key> --project-ref rzbzdeipbtqkzjqdchqk
//   SUPABASE_URL              — auto-inyectado (PostgREST)
//   SUPABASE_SERVICE_ROLE_KEY — auto-inyectado (lee mos.zona_* sin RLS)
//
// DEPLOY (lo corre el dueño):
//   supabase functions deploy riz-print --project-ref rzbzdeipbtqkzjqdchqk
//
// INERTE: el frontend SOLO llama esta Edge desde la vista 'zona', y esa vista solo se abre con el flag
// mos_zona_modulo ON (default OFF). Con el flag OFF nadie la invoca → la app es idéntica a hoy.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const APPS_OK = new Set(['MOS']);
const W = 48;   // 80mm @ font A = 48 columnas (NO 32, que es 58mm)

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

// ── Helpers ESC/POS (reescritos en TS; estilo inspirado en gas/Almacen.gs::_buildEscPosReporteJefa) ──
// Sin tildes ni caracteres fuera de ASCII (la impresora no tiene codepage configurado).
function norm(s: unknown): string {
  return String(s == null ? '' : s)
    .normalize('NFD').replace(/[̀-ͯ]/g, '')   // quita acentos (diacriticos combinados)
    .replace(/[ñÑ]/g, (m) => (m === 'ñ' ? 'n' : 'N'))
    .replace(/[“”]/g, '"').replace(/[‘’]/g, "'")
    .replace(/[–—]/g, '-').replace(/[•·]/g, '*')
    .replace(/[^\x20-\x7E]/g, '');                       // descarta el resto no-ASCII
}
function padR(s: string, n: number): string { s = String(s); return s.length >= n ? s.slice(0, n) : s + ' '.repeat(n - s.length); }
function padL(s: string, n: number): string { s = String(s); return s.length >= n ? s.slice(0, n) : ' '.repeat(n - s.length) + s; }
function center(s: string, n = W): string {
  s = String(s); if (s.length >= n) return s.slice(0, n);
  const left = Math.floor((n - s.length) / 2);
  return ' '.repeat(left) + s + ' '.repeat(n - s.length - left);
}
function rule(ch = '=', n = W): string { return ch.repeat(n); }
// "NOMBRE .......  12 un" — etiqueta a la izq, valor pegado a la derecha con puntos de relleno.
function dotLeader(label: string, value: string, n = W): string {
  label = String(label); value = String(value);
  const space = n - value.length - 1;
  if (label.length > space) label = label.slice(0, Math.max(0, space - 1)) + ' ';
  const dots = Math.max(1, space - label.length);
  return label + ' '.repeat(0) + '.'.repeat(dots) + ' ' + value;
}

// Comandos ESC/POS crudos
const ESC = '\x1b', GS = '\x1d';
const INIT = ESC + '@';                 // reset
const ALIGN_C = ESC + 'a' + '\x01';     // centrar
const ALIGN_L = ESC + 'a' + '\x00';     // izquierda
const BOLD_ON = ESC + 'E' + '\x01', BOLD_OFF = ESC + 'E' + '\x00';
const DBL = ESC + '!' + '\x30';         // doble alto + doble ancho
const NORMAL = ESC + '!' + '\x00';
const CUT = GS + 'V' + '\x42' + '\x00'; // corte parcial con feed
const FEED3 = '\n\n\n';

// ── Builder: TICKET DIARIO (3.6 del diseño) ──
// data esperado (de mos.zona_ticket_dia): { zona, nombreZona?, fecha, lote?:{n,total}, items:[{
//   descripcion|nombre, stockZona, esperada, picos:[...], tendencia, brecha, faltan, stockAlmacen }] }
function buildTicketDiario(data: any): string {
  const zonaNom = norm(data.nombreZona || data.zona || 'ZONA');
  const fecha = norm(data.fecha || '');
  const lote = data.lote || (data.lotes && data.lotes[0]) || null;
  const loteTxt = lote && (lote.n != null) ? `Lote ${lote.n}/${lote.total || '?'}` : '';
  const items: any[] = Array.isArray(data.items) ? data.items
    : (Array.isArray(data.productos) ? data.productos
    : (Array.isArray(data.lotes && data.lotes[0] && data.lotes[0].items) ? data.lotes[0].items : []));

  let t = INIT;
  t += ALIGN_C + BOLD_ON + DBL + 'MOS' + NORMAL + BOLD_OFF + '\n';
  t += ALIGN_C + BOLD_ON + norm(zonaNom) + BOLD_OFF + '\n';
  t += ALIGN_C + 'REPOSICION DEL DIA' + '\n';
  t += ALIGN_C + norm([fecha, loteTxt].filter(Boolean).join('  *  ')) + '\n';
  t += ALIGN_L + rule('=') + '\n';

  if (!items.length) {
    t += center('(sin productos para hoy)') + '\n';
  } else {
    items.forEach((it, i) => {
      const nm = norm(it.descripcion || it.nombre || it.skuBase || '');
      const stock = Number(it.stockZona != null ? it.stockZona : it.stock) || 0;
      const esp = Number(it.esperada != null ? it.esperada : it.esperado) || 0;
      const alm = Number(it.stockAlmacen != null ? it.stockAlmacen : it.almacen) || 0;
      const brecha = Number(it.brecha != null ? it.brecha : it.faltan);
      const faltan = isFinite(brecha) ? Math.max(0, brecha) : Math.max(0, esp - stock);
      const picos: number[] = Array.isArray(it.picos) ? it.picos.slice(-4).map((x: any) => Number(x) || 0) : [];
      const tend = norm(String(it.tendencia || '')).toUpperCase();
      const tendTxt = tend.startsWith('ASC') || tend.startsWith('CREC') ? 'SUBE'
        : tend.startsWith('DESC') || tend.startsWith('DECREC') ? 'BAJA'
        : tend.startsWith('NUL') || tend.startsWith('CERO') ? 'SIN ROTAR' : 'ESTABLE';

      // A. Nombre (numerado, en negrita)
      t += BOLD_ON + padR((i + 1) + ') ' + nm, W) + BOLD_OFF + '\n';
      // B/E. Stock zona + esperado  (dos columnas alineadas)
      t += '   ' + padR('Zona: ' + stock, 18) + padR('Esperado: ' + esp, W - 21) + '\n';
      // C. Tendencia (mini serie + etiqueta)
      const serie = picos.length ? picos.join(' ') : '-';
      t += '   ' + padR('Tend: ' + serie, 28) + padR('(' + tendTxt + ')', W - 31) + '\n';
      // D/E. Faltan + almacen
      t += '   ' + padR('Faltan: ' + faltan, 18) + padR('Almacen: ' + alm, W - 21) + '\n';
      // Casillas de verificacion
      t += '   [ ] verificado' + (faltan > 0 ? '   [ ] pedido' : '') + '\n';
      t += rule('-') + '\n';
    });
  }
  t += ALIGN_C + 'Verifica el stock real, ajusta' + '\n';
  t += ALIGN_C + 'en la app y pide lo que falte' + '\n';
  t += ALIGN_L + rule('=') + '\n';
  t += FEED3 + CUT;
  return t;
}

// ── Builder: LISTA DE COMPRAS DEL LUNES (3.7 del diseño) ──
// data esperado (de mos.zona_lista_compras): { zona, nombreZona?, semana, fecha?, items:[{
//   descripcion|nombre, cantidad }] }
function buildListaCompras(data: any): string {
  const zonaNom = norm(data.nombreZona || data.zona || 'ZONA');
  const semana = norm(data.semana != null ? String(data.semana) : '');
  const fecha = norm(data.fecha || '');
  const items: any[] = Array.isArray(data.items) ? data.items
    : (Array.isArray(data.productos) ? data.productos : (Array.isArray(data) ? data : []));

  let t = INIT;
  t += ALIGN_C + BOLD_ON + DBL + 'MOS' + NORMAL + BOLD_OFF + '\n';
  t += ALIGN_C + BOLD_ON + norm(zonaNom) + BOLD_OFF + '\n';
  t += ALIGN_C + 'LISTA DE COMPRA EXTERNA' + '\n';
  t += ALIGN_C + norm(['Semana ' + semana, fecha].filter(Boolean).join('  *  ')) + '\n';
  t += ALIGN_C + '(almacen NO cubrio + SI rota)' + '\n';
  t += ALIGN_L + rule('=') + '\n';

  let totItems = 0, totUnid = 0;
  if (!items.length) {
    t += center('(nada que comprar esta semana)') + '\n';
  } else {
    items.forEach((it) => {
      const nm = norm(it.descripcion || it.nombre || it.skuBase || '');
      const cant = Number(it.cantidad != null ? it.cantidad : (it.unidades != null ? it.unidades : it.faltan)) || 0;
      totItems++; totUnid += cant;
      t += dotLeader(nm, cant + ' un') + '\n';
    });
  }
  t += rule('-') + '\n';
  t += BOLD_ON + padR('TOTAL ITEMS: ' + totItems, 24) + padR('UNID: ' + totUnid, W - 24) + BOLD_OFF + '\n';
  t += ALIGN_C + 'Comprar con caja de zona.' + '\n';
  t += ALIGN_C + 'Marca lo conseguido en la app.' + '\n';
  t += ALIGN_L + rule('=') + '\n';
  t += FEED3 + CUT;
  return t;
}

// base64 de un string ESC/POS (bytes 1:1, latin1) → raw_base64 para PrintNode.
function toBase64(raw: string): string {
  // raw ya es ASCII/latin1 (norm descartó >0x7E salvo los comandos < 0x20). btoa exige bytes < 256.
  let s = '';
  for (let i = 0; i < raw.length; i++) s += String.fromCharCode(raw.charCodeAt(i) & 0xff);
  return btoa(s);
}

// Llama una RPC del esquema mos (wrapper → me.zona_*) con la SERVICE_ROLE key (bypassa RLS).
async function rpcMos(fn: string, p: Record<string, unknown>): Promise<any> {
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
  try { return JSON.parse(txt); } catch { return txt; }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'metodo no permitido' }, 405);

  try {
    const auth = req.headers.get('Authorization') || '';
    const claims = jwtClaims(auth.replace(/^Bearer\s+/i, '').trim());
    if (!claims || !APPS_OK.has(String(claims.app))) return json({ ok: false, error: 'no autorizado (claim app)' }, 401);

    const body = await req.json().catch(() => ({}));
    const tipo = String(body.tipo || '');
    const zona = String(body.zona || body.zonaId || '');
    const printerId = parseInt(String(body.printerId), 10);
    if (tipo !== 'ticket_diario' && tipo !== 'lista_compras') return json({ ok: false, error: 'tipo invalido (ticket_diario|lista_compras)' }, 400);
    if (!zona) return json({ ok: false, error: 'falta zona' }, 400);
    if (!printerId || printerId <= 0) return json({ ok: false, error: 'printerId invalido' }, 400);

    // 1) Traer los datos con la RPC determinística (service_role → sin RLS).
    let data: any, raw: string, title: string;
    if (tipo === 'ticket_diario') {
      const fecha = body.fecha ? String(body.fecha) : undefined;
      const r = await rpcMos('zona_ticket_dia', { zona, ...(fecha ? { fecha } : {}) });
      data = (r && r.data) || r || {};
      data.zona = data.zona || zona;
      raw = buildTicketDiario(data);
      title = 'RIZ Ticket ' + zona;
    } else {
      const semana = body.semana != null ? body.semana : undefined;
      const r = await rpcMos('zona_lista_compras', { zona, ...(semana != null ? { semana } : {}) });
      data = (r && r.data) || r || {};
      data.zona = data.zona || zona;
      raw = buildListaCompras(data);
      title = 'RIZ Lista compras ' + zona;
    }

    // 2) Enviar a PrintNode.
    const key = Deno.env.get('PRINTNODE_API_KEY');
    if (!key) return json({ ok: false, error: 'PRINTNODE_API_KEY no configurado' }, 500);

    const pn = await fetch('https://api.printnode.com/printjobs', {
      method: 'POST',
      headers: { 'Authorization': 'Basic ' + btoa(key + ':'), 'Content-Type': 'application/json' },
      body: JSON.stringify({
        printerId,
        title,
        contentType: 'raw_base64',
        content: toBase64(raw),
        source: 'MOS-riz-print',
      }),
    });
    const txt = await pn.text();
    if (pn.status !== 201) return json({ ok: false, error: 'PrintNode ' + pn.status + ': ' + txt }, 502);
    return json({ ok: true, printJobId: txt });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
