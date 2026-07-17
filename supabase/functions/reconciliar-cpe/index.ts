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

// [505] NubeFact generar_anulacion (Comunicación de Baja) — para las ventas ANULADAS cuyo CPE ya fue
// aceptado por SUNAT (auto-baja). Devuelve el nuevo estado BAJA_*.
async function generarBaja(serie: string, numero: number, tipoComprobante: number, ruta: string, token: string) {
  try {
    const resp = await fetch(ruta, {
      method: 'POST',
      headers: { 'Authorization': 'Token ' + token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ operacion: 'generar_anulacion', tipo_de_comprobante: tipoComprobante, serie, numero, motivo: 'Venta anulada en el punto de venta' }),
    });
    const body = await resp.json().catch(() => ({}));
    const ok = (resp.status === 200 || resp.status === 201);
    const aceptada = body.aceptada_por_sunat === true || body.anulado === true;
    return { estado: ok ? (aceptada ? 'BAJA_ACEPTADA' : 'BAJA_SOLICITADA') : 'BAJA_ERROR' };
  } catch { return { estado: 'BAJA_ERROR' }; }
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

    // [505] Candidatos vía RPC (me.cpe_recon_candidatos): pendientes NORMALES + ANULADAS que aún deben
    // comunicar la baja. Cada fila trae `anulada` (forma_pago='ANULADO') → decide la acción fiscal.
    const rp = await fetch(`${url}/rest/v1/rpc/cpe_recon_candidatos`, {
      method: 'POST',
      headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Profile': 'me', 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_dias: dias, p_limite: limite }),
    });
    if (!rp.ok) return json({ ok: false, error: 'lectura candidatos HTTP ' + rp.status }, 502);
    const pend = await rp.json().catch(() => []);
    if (!Array.isArray(pend) || pend.length === 0) return json({ ok: true, revisados: 0, emitidos: 0, rechazados: 0, bajas: 0, agendadas: 0, sin_cambio: 0, detalle: [] });

    // helper: persistir un nf_estado simple (baja/anulación) vía service-role.
    const setEstado = (ref: string, nf: Record<string, unknown>) => fetch(`${url}/rest/v1/rpc/set_cpe_nf`, {
      method: 'POST',
      headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Profile': 'me', 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_ref_local: ref, p_nf: nf }),
    });

    let emitidos = 0, rechazados = 0, bajas = 0, agendadas = 0, sinCambio = 0;
    const detalle: unknown[] = [];
    for (const row of pend) {
      const corr = String(row.correlativo || '');
      const m = /^([A-Za-z0-9]+)-(\d+)$/.exec(corr);
      if (!m) { detalle.push({ correlativo: corr, accion: 'correlativo_malformado' }); continue; }
      const tipoComprobante = (row.tipo_doc === 'FACTURA') ? 1 : 2;
      const anulada = row.anulada === true;
      const cons = await consultar(m[1], parseInt(m[2], 10), tipoComprobante, ruta, token);
      if (!cons.ok) {
        // La consulta falló (red, o NubeFact dice "no existe"). Si la venta está ANULADA, dejarla en
        // ANULADO_PEND_BAJA (visible + se reintenta el próximo ciclo) en vez de terminal: "no existe" puede
        // ser transitorio, y marcar ANULADO nos haría PERDER la baja si el comprobante sí existía y se acepta.
        if (anulada && row.nf_estado !== 'ANULADO_PEND_BAJA') { await setEstado(row.ref_local, { nf_estado: 'ANULADO_PEND_BAJA' }); }
        if (anulada) { agendadas++; detalle.push({ correlativo: corr, accion: (cons.noExiste ? 'anulada_no_existe_reintenta' : 'anulada_consulta_fallo') }); }
        else { sinCambio++; detalle.push({ correlativo: corr, accion: cons.noExiste ? 'no_existe_nubefact' : 'consulta_fallo' }); }
        continue;
      }

      // ── Rama ANULADA: la venta ya no cuenta (pago reversado); resolver el lado fiscal ──
      if (anulada) {
        if (cons.aceptada) {
          // SUNAT lo aceptó → comunicar la baja YA (auto-baja).
          const b = await generarBaja(m[1], parseInt(m[2], 10), tipoComprobante, ruta, token);
          const sp = await setEstado(row.ref_local, { nf_estado: b.estado, aceptada: true, consultado: true,
            sunat_desc: cons.sunatDescription, sunat_code: cons.sunat_code });
          if (sp.ok && (b.estado === 'BAJA_ACEPTADA' || b.estado === 'BAJA_SOLICITADA')) { bajas++; detalle.push({ correlativo: corr, accion: 'auto_baja_' + b.estado }); }
          else { sinCambio++; detalle.push({ correlativo: corr, accion: 'auto_baja_' + b.estado + (sp.ok ? '' : '_persist_fallo') }); }
        } else if (cons.rechazado) {
          // SUNAT lo rechazó → nada que dar de baja; terminal.
          const sp = await setEstado(row.ref_local, { nf_estado: 'ANULADO', consultado: true, sunat_desc: cons.sunatDescription, sunat_code: cons.sunat_code });
          if (sp.ok) { agendadas++; detalle.push({ correlativo: corr, accion: 'anulado_rechazado' }); } else { sinCambio++; }
        } else {
          // Aún pendiente en SUNAT → esperar; marcar/mantener ANULADO_PEND_BAJA.
          if (row.nf_estado !== 'ANULADO_PEND_BAJA') { await setEstado(row.ref_local, { nf_estado: 'ANULADO_PEND_BAJA', consultado: true }); }
          agendadas++; detalle.push({ correlativo: corr, accion: 'baja_agendada_espera_sunat' });
        }
        continue;
      }

      // ── Rama NORMAL: reconciliar el estado de emisión ──
      const nuevoEstado = cons.aceptada ? 'EMITIDO' : (cons.rechazado ? 'RECHAZADO' : 'PENDIENTE');
      if (nuevoEstado === 'PENDIENTE') { sinCambio++; detalle.push({ correlativo: corr, accion: 'sigue_pendiente' }); continue; }
      const nf = {
        nf_estado: nuevoEstado, nf_hash: cons.hash, nf_enlace: cons.enlace, nf_qr: cons.qrString,
        aceptada: cons.aceptada === true, sunat_desc: cons.sunatDescription, sunat_code: cons.sunat_code,
        enlace_xml: cons.enlace_xml, enlace_cdr: cons.enlace_cdr, numero_orden_sunat: cons.numero_orden_sunat,
        consultado: true,
      };
      const sp = await setEstado(row.ref_local, nf);
      if (sp.ok) { if (nuevoEstado === 'EMITIDO') emitidos++; else rechazados++; detalle.push({ correlativo: corr, accion: nuevoEstado }); }
      else { sinCambio++; detalle.push({ correlativo: corr, accion: 'set_cpe_nf_HTTP_' + sp.status }); }
    }
    return json({ ok: true, revisados: pend.length, emitidos, rechazados, bajas, agendadas, sin_cambio: sinCambio, detalle });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
