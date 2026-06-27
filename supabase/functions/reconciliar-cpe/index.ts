// Edge Function `reconciliar-cpe` — reconciliación BATCH del estado SUNAT de los CPE, 100% Supabase (cero-GAS).
// ════════════════════════════════════════════════════════════════════════════════════════════════════
// Lo dispara el pg_cron (me.cpe_reconciliar_cron → net.http_post con el header x-cpe-cron). Lee de la DB los
// CPE en PENDIENTE (aceptados por NubeFact, esperando el CDR de SUNAT), re-consulta NubeFact (token en SECRET)
// y persiste el estado fresco vía me.set_cpe_nf. NO emite nada — solo CONSULTA (read-only en NubeFact) + patch.
// Reemplaza la reconciliación GAS (NubeFact.gs reconciliarCPEsPendientes que escaneaba la Hoja).
//
// AUTORIZACIÓN: header `x-cpe-cron` == secret CPE_CRON_SECRET (compartido con el cron, en Vault).
// Sin él → 401. Kill-switch: ME_CPE_DIRECTO='1' (cpeDirectoOn). Inerte si no hay pendientes.
// SECRETS: NUBEFACT_TOKEN, NUBEFACT_RUTA, CPE_CRON_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cpe-cron',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
const r2 = (n: number) => Math.round(n * 100) / 100;

async function cpeDirectoOn(url: string, key: string): Promise<boolean> {
  try {
    const r = await fetch(`${url}/rest/v1/config?select=valor&clave=eq.ME_CPE_DIRECTO`, {
      headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Accept-Profile': 'mos' },
    });
    if (!r.ok) return false;
    const rows = await r.json().catch(() => []);
    return Array.isArray(rows) && rows[0] && String(rows[0].valor) === '1';
  } catch { return false; }
}

// NubeFact: consultar_comprobante (read-only). Devuelve el estado SUNAT actual del comprobante.
async function consultar(serie: string, numero: number, tipoComprobante: number, ruta: string, token: string) {
  try {
    const resp = await fetch(ruta, {
      method: 'POST',
      headers: { 'Authorization': 'Token ' + token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ operacion: 'consultar_comprobante', tipo_de_comprobante: tipoComprobante, serie, numero }),
    });
    const body = await resp.json().catch(() => ({}));
    if (resp.status === 200 || resp.status === 201) {
      const aceptada = body.aceptada_por_sunat === true;
      const sunatDesc = String(body.sunat_description || '').trim();
      const respCode = body.sunat_responsecode;
      const tieneErr = !!sunatDesc || (respCode != null && String(respCode).trim() !== '' && String(respCode).trim() !== '0');
      return {
        ok: true, aceptada, rechazado: (!aceptada && tieneErr),
        hash: String(body.codigo_hash || ''), enlace: String(body.enlace_del_pdf || ''),
        qrString: String(body.cadena_para_codigo_qr || ''), enlace_xml: String(body.enlace_del_xml || ''),
        enlace_cdr: String(body.enlace_del_cdr || ''), numero_orden_sunat: String(body.numero_de_orden_sunat || ''),
        sunatDescription: sunatDesc, sunat_code: (respCode != null ? String(respCode) : ''),
      };
    }
    const errMsg = String(body.errors || body.message || '');
    if (/no\s+(existe|encontrado|registrado)/i.test(errMsg)) return { ok: false, noExiste: true, error: errMsg.slice(0, 200) };
    return { ok: false, error: 'HTTP ' + resp.status + ': ' + errMsg.slice(0, 200) };
  } catch (e) { return { ok: false, error: 'NETWORK: ' + String((e as Error)?.message || e) }; }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const url = Deno.env.get('SUPABASE_URL');
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const token = Deno.env.get('NUBEFACT_TOKEN');
    const ruta = Deno.env.get('NUBEFACT_RUTA');
    const cronSecret = Deno.env.get('CPE_CRON_SECRET');
    if (!url || !key) return json({ ok: false, error: 'plataforma no configurada' }, 500);
    if (!cronSecret || req.headers.get('x-cpe-cron') !== cronSecret) return json({ ok: false, error: 'no autorizado (cron secret)' }, 401);
    if (!token || !ruta) return json({ ok: false, error: 'NubeFact no configurado' }, 500);
    if (!(await cpeDirectoOn(url, key))) return json({ ok: false, error: 'CPE_DIRECTO_DESACTIVADO' }, 403);

    const inp = await req.json().catch(() => ({}));
    // [500x-2b] ventana >= 45d (cubre el sweep GAS de 35d + margen); SUNAT puede aceptar dias despues.
    const dias = Math.min(Math.max(parseInt(String(inp.dias ?? 45), 10) || 45, 1), 90);
    const limite = Math.min(Math.max(parseInt(String(inp.limite ?? 50), 10) || 50, 1), 200);
    const desde = new Date(Date.now() - dias * 86400 * 1000).toISOString().slice(0, 10);

    // CPE en PENDIENTE (aceptados por NubeFact, sin CDR de SUNAT aún). nf_estado NULL/EMITIENDO incluidos.
    const q = `${url}/rest/v1/ventas?select=ref_local,correlativo,tipo_doc,nf_estado`
      + `&tipo_doc=in.(BOLETA,FACTURA)`
      + `&or=(nf_estado.eq.PENDIENTE,nf_estado.eq.EMITIENDO,nf_estado.is.null)`
      + `&correlativo=neq.&fecha=gte.${desde}&limit=${limite}`;
    const rp = await fetch(q, { headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Accept-Profile': 'me' } });
    if (!rp.ok) return json({ ok: false, error: 'lectura pendientes HTTP ' + rp.status }, 502);
    const pend = await rp.json().catch(() => []);
    if (!Array.isArray(pend) || pend.length === 0) return json({ ok: true, revisados: 0, emitidos: 0, rechazados: 0, sin_cambio: 0, detalle: [] });

    let emitidos = 0, rechazados = 0, sinCambio = 0;
    const detalle: unknown[] = [];
    for (const row of pend) {
      const corr = String(row.correlativo || '');
      const m = /^([A-Za-z0-9]+)-(\d+)$/.exec(corr);
      if (!m) { detalle.push({ correlativo: corr, accion: 'correlativo_malformado' }); continue; }
      const tipoComprobante = (row.tipo_doc === 'FACTURA') ? 1 : 2;
      const cons = await consultar(m[1], parseInt(m[2], 10), tipoComprobante, ruta, token);
      if (!cons.ok) { sinCambio++; detalle.push({ correlativo: corr, accion: cons.noExiste ? 'no_existe_nubefact' : 'consulta_fallo' }); continue; }
      const nuevoEstado = cons.aceptada ? 'EMITIDO' : (cons.rechazado ? 'RECHAZADO' : 'PENDIENTE');
      if (nuevoEstado === 'PENDIENTE') { sinCambio++; detalle.push({ correlativo: corr, accion: 'sigue_pendiente' }); continue; }
      // persistir vía set_cpe_nf (no degrada EMITIDO; merge de trazabilidad). PostgREST con service-role.
      const nf = {
        nf_estado: nuevoEstado, nf_hash: cons.hash, nf_enlace: cons.enlace, nf_qr: cons.qrString,
        aceptada: cons.aceptada === true, sunat_desc: cons.sunatDescription, sunat_code: cons.sunat_code,
        enlace_xml: cons.enlace_xml, enlace_cdr: cons.enlace_cdr, numero_orden_sunat: cons.numero_orden_sunat,
        consultado: true,
      };
      const sp = await fetch(`${url}/rest/v1/rpc/set_cpe_nf`, {
        method: 'POST',
        headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Profile': 'me', 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_ref_local: row.ref_local, p_nf: nf }),
      });
      if (sp.ok) { if (nuevoEstado === 'EMITIDO') emitidos++; else rechazados++; detalle.push({ correlativo: corr, accion: nuevoEstado }); }
      else { sinCambio++; detalle.push({ correlativo: corr, accion: 'set_cpe_nf_HTTP_' + sp.status }); }
    }
    return json({ ok: true, revisados: pend.length, emitidos, rechazados, sin_cambio: sinCambio, detalle });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
