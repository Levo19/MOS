// Edge Function `aviso-cajas` — migración cero-GAS del "aviso a cajas" (warehouseMos).
// Reemplaza gas/Reporte.gs::imprimirAvisoCajeros: lee el preingreso + cajas ABIERTAS con
// su printnode DESDE POSTGRES (RPC mos.aviso_cajas_data, service_role), arma el ticket
// ESC/POS server-side (paridad byte con _construirAvisoIngresoBytes) y lo manda a PrintNode
// (1 job por printnode, ya deduplicado en SQL). Idempotente por (idPreingreso, idemKey).
//
// AUTORIZACIÓN: plataforma verifica firma JWT (verify_jwt); exigimos claim app ∈ {warehouseMos,MOS}.
// SECRET: PRINTNODE_API_KEY (ya configurado para las demás Edge de impresión).

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
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

// ── helpers de texto (port de gas/Reporte.gs) ──────────────────────────────
function wrapPalabras(texto: string, anchoPrimero: number, anchoResto?: number): string[] {
  texto = String(texto || '').trim();
  if (!texto) return [''];
  if (anchoResto == null) anchoResto = anchoPrimero;
  const palabras = texto.split(/\s+/);
  const lineas: string[] = [];
  let cur = ''; let ancho = anchoPrimero;
  for (let i = 0; i < palabras.length; i++) {
    let p = palabras[i];
    while (p.length > ancho) {
      if (cur) { lineas.push(cur); cur = ''; ancho = anchoResto; }
      lineas.push(p.substring(0, ancho)); p = p.substring(ancho);
    }
    const sep = cur ? ' ' : '';
    if ((cur + sep + p).length <= ancho) { cur = cur + sep + p; }
    else { lineas.push(cur); cur = p; ancho = anchoResto; }
  }
  if (cur) lineas.push(cur);
  return lineas;
}
function padLine48(left: string, right: string): string {
  const l = String(left || ''); const r = String(right || '');
  let pad = 48 - l.length - r.length; if (pad < 1) pad = 1;
  return l + ' '.repeat(pad) + r;
}
const MESES = ['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
function fechaLima(iso: string): string {
  try {
    if (!iso) return '';
    const d = new Date(iso); if (isNaN(d.getTime())) return '';
    const tz = 'America/Lima';
    const p = (o: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat('en-US', { timeZone: tz, ...o }).format(d);
    const dia = parseInt(p({ day: 'numeric' }), 10);
    const mesIdx = parseInt(p({ month: 'numeric' }), 10) - 1;
    let hh = parseInt(p({ hour: '2-digit', hour12: false }), 10); if (hh === 24) hh = 0;
    const mm = parseInt(p({ minute: '2-digit' }), 10);
    const mes = MESES[mesIdx] || '';
    const ampm = hh >= 12 ? 'pm' : 'am';
    let hh12 = hh % 12; if (hh12 === 0) hh12 = 12;
    const horaTxt = mm === 0 ? (hh12 + ampm) : (hh12 + ':' + (mm < 10 ? '0' : '') + mm + ampm);
    return dia + ' ' + mes + ' ' + horaTxt;
  } catch { return ''; }
}

// ── builder ESC/POS del aviso (paridad con _construirAvisoIngresoBytes) ────
function construirAvisoBytes(pi: any, provName: string, reporteUrl: string): number[] {
  const B: number[] = [];
  const b1 = (v: number) => { B.push(v & 0xff); };
  // [100x MED] sanea bytes de control (< 0x20 y 0x7f) del TEXTO: un comentario/proveedor
  // con bytes crudos (0x1B/0x1D…) podría reprogramar la impresora o forzar corte. Los
  // saltos de línea reales los emite bLn con b1(0x0a), no por acá.
  const bStr = (s: string) => { for (let k = 0; k < s.length; k++) { const c = s.charCodeAt(k) & 0xff; B.push((c < 0x20 || c === 0x7f) ? 0x20 : c); } };
  const bLn = (s: string) => { bStr(s); b1(0x0a); };
  const SEP = '================================================';
  const SEP2 = '------------------------------------------------';

  b1(0x1b); b1(0x40);
  // Header
  b1(0x1b); b1(0x61); b1(0x01);
  b1(0x1b); b1(0x21); b1(0x38);
  bLn('WAREHOUSE'); bLn('MOS');
  b1(0x1b); b1(0x21); b1(0x00);
  b1(0x1b); b1(0x45); b1(0x01);
  bLn('AVISO INGRESO');
  b1(0x1b); b1(0x45); b1(0x00);
  b1(0x1b); b1(0x61); b1(0x00);
  bLn(SEP);
  // Empresa
  if (provName) {
    b1(0x1b); b1(0x61); b1(0x01);
    b1(0x1b); b1(0x21); b1(0x10); b1(0x1b); b1(0x45); b1(0x01);
    const nameLines = wrapPalabras(String(provName).toUpperCase(), 24);
    for (let nl = 0; nl < nameLines.length && nl < 2; nl++) bLn(nameLines[nl]);
    b1(0x1b); b1(0x21); b1(0x00); b1(0x1b); b1(0x45); b1(0x00);
    b1(0x1b); b1(0x61); b1(0x00);
  }
  // Fecha
  const fechaPI = fechaLima(String(pi.fechaISO || ''));
  if (fechaPI) {
    b1(0x1b); b1(0x61); b1(0x01); b1(0x1b); b1(0x45); b1(0x01);
    bLn(fechaPI);
    b1(0x1b); b1(0x45); b1(0x00); b1(0x1b); b1(0x61); b1(0x00);
  }
  bLn(SEP);
  // Monto
  const monto = pi.monto;
  if (monto) {
    b1(0x1b); b1(0x61); b1(0x01); b1(0x1b); b1(0x45); b1(0x01);
    bLn('PREPARAR PARA PAGAR');
    b1(0x1b); b1(0x45); b1(0x00);
    b1(0x1b); b1(0x21); b1(0x38); b1(0x1b); b1(0x45); b1(0x01);
    bLn('S/. ' + monto);
    b1(0x1b); b1(0x21); b1(0x00); b1(0x1b); b1(0x45); b1(0x00);
    b1(0x1b); b1(0x61); b1(0x00);
    bLn(SEP);
  }
  // Cargadores
  let cargs: any[] = [];
  try { cargs = JSON.parse(pi.cargadores || '[]'); } catch { cargs = []; }
  if (cargs.length) {
    bLn('');
    b1(0x1b); b1(0x45); b1(0x01); bLn('Cargadores:'); b1(0x1b); b1(0x45); b1(0x00);
    let totLlenas = 0, totMedias = 0, totVacias = 0, totCarretas = 0;
    cargs.forEach((c: any) => {
      const nombre = (typeof c === 'object') ? (c.nombre || c.idPersonal || '') : String(c);
      if (!nombre) return;
      const carretas = (typeof c === 'object' && c.carretas) ? parseInt(c.carretas) || 0 : 0;
      let estadosArr: string[] = [];
      if (typeof c === 'object' && Array.isArray(c.estados)) {
        estadosArr = c.estados.slice(0, carretas).map((e: string) => (e === 'MEDIA' || e === 'VACIA') ? e : 'LLENA');
      }
      while (estadosArr.length < carretas) estadosArr.push('LLENA');
      let ll = 0, md = 0, vc = 0;
      estadosArr.forEach((e) => { if (e === 'LLENA') ll++; else if (e === 'MEDIA') md++; else if (e === 'VACIA') vc++; });
      totLlenas += ll; totMedias += md; totVacias += vc; totCarretas += carretas;
      if (carretas > 0) {
        b1(0x1b); b1(0x45); b1(0x01);
        bLn(padLine48('  - ' + nombre, carretas + ' carreta' + (carretas === 1 ? '' : 's')));
        b1(0x1b); b1(0x45); b1(0x00);
        const dets: string[] = [];
        if (ll > 0) dets.push(ll + ' LLENA' + (ll === 1 ? '' : 'S'));
        if (md > 0) dets.push(md + ' MEDIA' + (md === 1 ? '' : 'S'));
        if (vc > 0) dets.push(vc + ' CASI VACIA' + (vc === 1 ? '' : 'S'));
        if (dets.length) bLn('      ' + dets.join(' / '));
      } else {
        bLn('  - ' + nombre);
      }
    });
    if (cargs.length > 1 && (totMedias + totVacias > 0)) {
      bLn(SEP2);
      b1(0x1b); b1(0x45); b1(0x01);
      bLn(padLine48('  TOTAL', totCarretas + ' carreta' + (totCarretas === 1 ? '' : 's')));
      const tdets: string[] = [];
      if (totLlenas > 0) tdets.push(totLlenas + ' L');
      if (totMedias > 0) tdets.push(totMedias + ' M');
      if (totVacias > 0) tdets.push(totVacias + ' CV');
      if (tdets.length) bLn('      ' + tdets.join(' / '));
      b1(0x1b); b1(0x45); b1(0x00);
    }
  }
  // Comentario
  if (pi.comentario) {
    bLn(SEP2);
    b1(0x1b); b1(0x45); b1(0x01); bLn('Comentario:'); b1(0x1b); b1(0x45); b1(0x00);
    b1(0x1b); b1(0x21); b1(0x10); b1(0x1b); b1(0x45); b1(0x01);
    const comLines = wrapPalabras(String(pi.comentario), 24);
    for (let ci = 0; ci < comLines.length; ci++) bLn(comLines[ci]);
    b1(0x1b); b1(0x21); b1(0x00); b1(0x1b); b1(0x45); b1(0x00);
  }
  bLn(SEP);
  // Adjuntos
  const nFotos = pi.fotos ? String(pi.fotos).split(',').filter(Boolean).length : 0;
  if (nFotos > 0) {
    b1(0x1b); b1(0x61); b1(0x01);
    bLn(nFotos + ' imagen' + (nFotos !== 1 ? 'es' : '') + ' adjunta' + (nFotos !== 1 ? 's' : ''));
    bLn('ver en el reporte digital');
    b1(0x1b); b1(0x61); b1(0x00);
    bLn(SEP);
  }
  // QR
  if (reporteUrl) {
    b1(0x1b); b1(0x61); b1(0x01); b1(0x1b); b1(0x45); b1(0x01);
    bLn('VER PREINGRESO COMPLETO');
    b1(0x1b); b1(0x45); b1(0x00);
    const qrLen = reporteUrl.length + 3;
    const qrpL = qrLen & 0xff; const qrpH = (qrLen >> 8) & 0xff;
    b1(0x1d); b1(0x28); b1(0x6b); b1(0x04); b1(0x00); b1(0x31); b1(0x41); b1(0x32); b1(0x00);
    b1(0x1d); b1(0x28); b1(0x6b); b1(0x03); b1(0x00); b1(0x31); b1(0x43); b1(0x05);
    b1(0x1d); b1(0x28); b1(0x6b); b1(0x03); b1(0x00); b1(0x31); b1(0x45); b1(0x31);
    b1(0x1d); b1(0x28); b1(0x6b); b1(qrpL); b1(qrpH); b1(0x31); b1(0x50); b1(0x30);
    bStr(reporteUrl);
    b1(0x1d); b1(0x28); b1(0x6b); b1(0x03); b1(0x00); b1(0x31); b1(0x51); b1(0x30);
    bLn('Escanea para fotos y detalles');
    b1(0x1b); b1(0x61); b1(0x00);
    bLn(SEP);
  }
  // Feed + corte
  b1(0x1b); b1(0x4a); b1(160);
  b1(0x1d); b1(0x56); b1(0x00);
  return B;
}
function bytesToB64(arr: number[]): string {
  let bin = '';
  for (let i = 0; i < arr.length; i += 8192) bin += String.fromCharCode(...arr.slice(i, i + 8192));
  return btoa(bin);
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const APPS_OK = new Set(['warehouseMos', 'MOS']);
    const auth = req.headers.get('Authorization') || '';
    const token = auth.replace(/^Bearer\s+/i, '').trim();
    const claims = jwtClaims(token);
    if (!claims || !APPS_OK.has(String(claims.app))) return json({ ok: false, error: 'no autorizado (claim app)' }, 401);

    const body = await req.json().catch(() => ({}));
    const idPreingreso = String(body.idPreingreso || '').trim();
    const idemKey = String(body.idemKey || '').trim();
    const reporteUrl = String(body.reporteUrl || '').trim();
    if (!idPreingreso) return json({ ok: false, error: 'idPreingreso requerido' }, 400);

    const SB_URL = Deno.env.get('SUPABASE_URL');
    const SRV = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const key = Deno.env.get('PRINTNODE_API_KEY');
    if (!SB_URL || !SRV) return json({ ok: false, error: 'entorno Supabase no disponible' }, 500);
    if (!key) return json({ ok: false, error: 'PRINTNODE_API_KEY no configurada' }, 500);

    // 1) datos + reserva idempotente (todo desde Postgres, cero-GAS)
    const rpcRes = await fetch(`${SB_URL}/rest/v1/rpc/aviso_cajas_data`, {
      method: 'POST',
      headers: { 'apikey': SRV, 'Authorization': 'Bearer ' + SRV, 'Accept-Profile': 'mos', 'Content-Profile': 'mos', 'Content-Type': 'application/json' },
      body: JSON.stringify({ p: { idPreingreso, idemKey } }),
    });
    const data = await rpcRes.json().catch(() => null);
    if (!rpcRes.ok || !data || data.ok !== true) {
      return json({ ok: false, error: (data && data.error) || ('RPC ' + rpcRes.status) }, 502);
    }
    if (data.yaImpreso) return json({ ok: true, yaImpreso: true, enviados: 0, cajas: 0, impresiones: [] });
    const cajas: any[] = Array.isArray(data.cajas) ? data.cajas : [];
    if (!cajas.length) return json({ ok: true, enviados: 0, cajas: 0, impresiones: [], mensaje: 'sin cajas abiertas' });

    // 2) armar ESC/POS una vez y mandar 1 job por printnode ÚNICO (dedup acá)
    const bytes = construirAvisoBytes(data.preingreso || {}, String((data.preingreso || {}).proveedor || ''), reporteUrl);
    const b64 = bytesToB64(bytes);
    const okSet = new Set<string>(); const errores: string[] = [];
    const uniq = [...new Set(cajas.map((c) => String(c.printnodeId || '')).filter((x) => parseInt(x, 10) > 0))];
    for (const pidStr of uniq) {
      const pid = parseInt(pidStr, 10);
      try {
        const pn = await fetch('https://api.printnode.com/printjobs', {
          method: 'POST',
          headers: { 'Authorization': 'Basic ' + btoa(key + ':'), 'Content-Type': 'application/json' },
          body: JSON.stringify({ printerId: pid, title: 'Aviso ingreso ' + idPreingreso, contentType: 'raw_base64', content: b64, source: 'warehouseMos-Edge' }),
        });
        if (pn.status === 201) okSet.add(pidStr);
        else errores.push('P' + pid + ':' + pn.status);
      } catch (e) { errores.push('P' + pid + ':' + String((e as Error)?.message || e)); }
    }
    // impresiones por caja (vendedor/zona) para la confirmación de la UI
    const impresiones = cajas.map((c) => ({ ok: okSet.has(String(c.printnodeId || '')), vendedor: String(c.vendedor || ''), zona: String(c.zona || '') }));
    return json({ ok: okSet.size > 0, enviados: okSet.size, cajas: cajas.length, impresiones, errores });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
