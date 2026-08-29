// Edge Function `emitir-cpe` — emite el CPE (boleta/factura) a SUNAT vía NubeFact, con el token en un SECRET
// (server-side, nunca en el navegador). Reemplaza el salto a GAS para el CPE → casi tan rápido como la NV
// (NubeFact devuelve el QR/hash al instante; SUNAT acepta después, async, de eso se encarga NubeFact).
//
// Port FIEL de gas/NubeFact.gs `emitirNubeFact` (+ consulta para idempotencia por duplicado). La lógica de IGV
// vive acá (un solo lugar, no duplicada en JS del navegador). Compliance-crítico → detrás de flag en el front.
//
// AUTORIZACIÓN: firma JWT verificada por la plataforma + claim app=mosExpress (la anon key pública no pasa).
// SECRETS requeridos (set por el usuario, NO en el repo):
//   supabase secrets set NUBEFACT_TOKEN=<token> NUBEFACT_RUC=<ruc> --project-ref rzbzdeipbtqkzjqdchqk

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// [Lote2-B · C1] Kill-switch server-side: ¿está ME_CPE_DIRECTO='1' en mos.config?
// El flag del frontend NO basta — sin esto, cualquier token ME podía invocar la Edge.
// Lee con la service-role key (server-side, en secret) vía PostgREST. Fail-CLOSED:
// ante cualquier error o flag ausente → false (no emite).
async function cpeDirectoOn(): Promise<boolean> {
  try {
    const url = Deno.env.get('SUPABASE_URL');
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !key) return false;
    const r = await fetch(`${url}/rest/v1/config?select=valor&clave=eq.ME_CPE_DIRECTO`, {
      headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Accept-Profile': 'mos' },
    });
    if (!r.ok) return false;
    const rows = await r.json().catch(() => []);
    return Array.isArray(rows) && rows[0] && String(rows[0].valor) === '1';
  } catch { return false; }
}
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
const r2 = (n: number) => Math.round(n * 100) / 100;

// NubeFact: consultar_comprobante (mismo endpoint, distingue por `operacion`). Para idempotencia por duplicado.
async function consultar(serie: string, numero: number, tipoComprobante: number, ruta: string, token: string) {
  const endpoint = ruta;   // ruta dedicada NubeFact (api/v1/<UUID>) — MISMA URL para boleta/factura/consulta
  try {
    const resp = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Authorization': 'Token ' + token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ operacion: 'consultar_comprobante', tipo_de_comprobante: tipoComprobante, serie, numero }),
    });
    const body = await resp.json().catch(() => ({}));
    if (resp.status === 200 || resp.status === 201) {
      const aceptada = body.aceptada_por_sunat === true;
      const sunatDesc = String(body.sunat_description || '').trim();
      const respCode = body.sunat_responsecode;
      // [500x-2b] distinguir RECHAZADO (aceptada=false CON error SUNAT) de PENDIENTE (aceptada=false sin error)
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
    const auth = req.headers.get('Authorization') || '';
    const claims = jwtClaims(auth.replace(/^Bearer\s+/i, '').trim());
    // generar (emitir) = solo mosExpress (POS). consultar (trazar/reconciliar) = mosExpress o MOS (panel admin).
    const appClaim = claims && claims.app;
    if (!claims || (appClaim !== 'mosExpress' && appClaim !== 'MOS')) return json({ ok: false, error: 'no autorizado (claim app)' }, 401);

    // [Lote2-B · C1] Kill-switch server-side ANTES de tocar NubeFact.
    if (!(await cpeDirectoOn())) return json({ ok: false, error: 'CPE_DIRECTO_DESACTIVADO' }, 403);

    // [go-live prod] TOKEN POR LOCAL: NubeFact da un token por establecimiento; la RUTA es la
    // misma (cuenta/RUC). NUBEFACT_TOKENS = JSON { "<serie>": "<token>", ... } — p.ej.
    // {"BM01":"...","FM01":"...","BM02":"...","FM02":"..."}. pickToken(serie) elige el correcto.
    // Fallback a NUBEFACT_TOKEN (un solo token) → retrocompat demo, no rompe nada.
    const ruta = Deno.env.get('NUBEFACT_RUTA');   // URL dedicada NubeFact (api/v1/<UUID>), en SECRET
    let tokensMap: Record<string, string> = {};
    try {
      const raw = JSON.parse(Deno.env.get('NUBEFACT_TOKENS') || '{}');
      // [hardening fiscal] normalizar claves (trim + UPPER): un typo de mayúsculas/espacio en el
      // secret ({"bm02":…} o {"FM02 ":…}) haría fallar el match y caer al local equivocado.
      tokensMap = Object.fromEntries(Object.entries(raw).map(([k, v]) => [String(k).trim().toUpperCase(), v as string]));
    } catch { tokensMap = {}; }
    const fallbackTok = Deno.env.get('NUBEFACT_TOKEN') || '';
    // [hardening fiscal] MULTI-LOCAL: si hay mapa poblado, una serie NO mapeada debe FALLAR CERRADO
    // (devuelve '') — jamás caer al fallback único, que emitiría en el LOCAL EQUIVOCADO en silencio.
    // El fallback único solo aplica en modo un-solo-token (mapa vacío / demo).
    const pickToken = (serie: string): string => {
      const s = String(serie || '').trim().toUpperCase();
      return Object.keys(tokensMap).length ? (tokensMap[s] || '') : fallbackTok;
    };
    if (!ruta || (!fallbackTok && Object.keys(tokensMap).length === 0)) {
      return json({ ok: false, error: 'NubeFact no configurado (secrets NUBEFACT_RUTA + NUBEFACT_TOKENS o NUBEFACT_TOKEN)' }, 500);
    }

    const inp = await req.json().catch(() => ({}));
    const data = inp.data || {};
    const correlativo = String(inp.correlativo || '');
    const header = data.header || {};
    const items = data.items || [];
    const tipoDoc = header.tipoDoc || inp.tipoDoc;

    // ── [TRAZABILIDAD cero-GAS] operacion='consultar': re-consulta el estado SUNAT de un CPE ya emitido ──
    // No genera nada; solo lee de NubeFact el estado actual (aceptada_por_sunat + CDR/XML + motivo).
    // Lo usa la reconciliación de MOS (panel Tributario / cron) sin pasar por GAS. Read-only y idempotente.
    if (String(inp.operacion || '') === 'consultar') {
      if (!correlativo || !/^[A-Za-z0-9]+-\d+$/.test(correlativo)) return json({ ok: false, error: 'correlativo requerido/malformado: ' + correlativo }, 400);
      if (tipoDoc !== 'BOLETA' && tipoDoc !== 'FACTURA') return json({ ok: false, error: 'tipoDoc inválido (BOLETA|FACTURA)' }, 400);
      const ps = correlativo.split('-');
      const sNum = parseInt(ps[ps.length - 1], 10);
      if (!sNum || sNum < 1) return json({ ok: false, error: 'número de correlativo inválido' }, 400);
      const tc = (tipoDoc === 'FACTURA') ? 1 : 2;
      const tok = pickToken(ps[0]);
      if (!tok) return json({ ok: false, error: 'sin token NubeFact para la serie ' + ps[0] }, 500);
      const cons = await consultar(ps[0], sNum, tc, ruta, tok);
      if (!cons.ok) return json({ ok: false, ...cons }, cons.noExiste ? 404 : 502);
      const estC = cons.aceptada ? 'EMITIDO' : (cons.rechazado ? 'RECHAZADO' : 'PENDIENTE');
      return json({ ok: true, consultado: true, estado: estC, ...cons });
    }

    // ── [BAJA CPE cero-GAS] operacion='baja': comunica la anulación del CPE a SUNAT vía NubeFact ──
    // Espejo de EditarVenta.gs::bajaCPEVenta: lee la venta (service role, autoritativo) → valida BOLETA/FACTURA
    // + nf_estado=EMITIDO → parte el correlativo → NubeFact generar_anulacion → patchea nf_estado. Idempotente.
    if (String(inp.operacion || '') === 'baja') {
      const idVenta = String(inp.idVenta || '').trim();
      const motivo = String(inp.motivo || '').trim();
      if (!idVenta) return json({ status: 'error', error: 'idVenta requerido' }, 400);
      if (motivo.length < 3) return json({ status: 'error', error: 'motivo es obligatorio para SUNAT' }, 400);
      const sbUrl = Deno.env.get('SUPABASE_URL'); const sbKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
      // [audit 2026-07-13 · cero-caída] BAJA_CPE es MASTER-only e irreversible ante SUNAT: se re-verifica
      // la clave admin server-side (mismo bcrypt sincronizado + cascada de nivel). Reusa el helper SQL
      // mos.reverificar_clave_admin (flag MOS_STRICT_ADMIN_REVERIFY gobierna la transición). FAIL-CLOSED.
      {
        const rvResp = await fetch(`${sbUrl}/rest/v1/rpc/reverificar_clave_admin`, {
          method: 'POST',
          headers: { 'apikey': sbKey!, 'Authorization': 'Bearer ' + sbKey!, 'Content-Profile': 'mos', 'Content-Type': 'application/json' },
          body: JSON.stringify({ p_clave: String(inp.claveAdmin || ''), p_accion: 'BAJA_CPE', p_ref: idVenta, p_app: String(appClaim || 'MOS') }),
        });
        const rvj = rvResp.ok ? await rvResp.json().catch(() => ({ error: 'reverify parse' })) : { error: 'reverify HTTP ' + rvResp.status };
        // null = autorizado (o transición con clave ausente). No-null = rechazo.
        if (rvj !== null && rvj) return json({ status: 'error', autorizado: false, error: String(rvj.error || 'Clave admin (MASTER) requerida para baja CPE') }, 403);
      }
      const vr = await fetch(`${sbUrl}/rest/v1/ventas?select=tipo_doc,nf_estado,correlativo&id_venta=eq.${encodeURIComponent(idVenta)}&limit=1`, {
        headers: { 'apikey': sbKey!, 'Authorization': 'Bearer ' + sbKey!, 'Accept-Profile': 'me' } });
      const vrows = await vr.json().catch(() => []);
      if (!Array.isArray(vrows) || !vrows.length) return json({ status: 'error', error: 'Venta ' + idVenta + ' no encontrada' }, 404);
      const v = vrows[0];
      const td = String(v.tipo_doc || ''); const nfe = String(v.nf_estado || ''); const corr = String(v.correlativo || '');
      if (td !== 'BOLETA' && td !== 'FACTURA') return json({ status: 'error', error: 'Solo se da de baja BOLETA o FACTURA. Esta venta es ' + td }, 400);
      // [505] NOTA: la REVERSA DEL PAGO (forma_pago='ANULADO' + stock + pickup) la hace el front por la vía
      // de anulación (me.anular_venta_directo), offline-safe. Acá SOLO se resuelve el lado FISCAL con SUNAT.
      const patchNf = (estado: string) => fetch(`${sbUrl}/rest/v1/ventas?id_venta=eq.${encodeURIComponent(idVenta)}`, {
        method: 'PATCH',
        headers: { 'apikey': sbKey!, 'Authorization': 'Bearer ' + sbKey!, 'Content-Profile': 'me', 'Content-Type': 'application/json' },
        body: JSON.stringify({ nf_estado: estado }) }).catch(() => {});
      // Idempotencia: ya en un estado terminal de baja/anulación → no re-comunicar.
      if (nfe.startsWith('BAJA_') || nfe === 'ANULADO') return json({ status: 'success', nuevoEstado: nfe, dedup: true });
      // EMITIDO (aceptado por SUNAT) → comunicar la baja YA.
      if (nfe === 'EMITIDO') {
        const pb = corr.split('-'); if (pb.length < 2) return json({ status: 'error', error: 'Correlativo inválido: ' + corr }, 400);
        const bSerie = pb[0]; const bNum = parseInt(pb[pb.length - 1], 10);
        if (!bNum || bNum < 1) return json({ status: 'error', error: 'número de correlativo inválido' }, 400);
        const bTok = pickToken(bSerie);
        if (!bTok) return json({ status: 'error', error: 'sin token NubeFact para la serie ' + bSerie }, 500);
        const bResp = await fetch(ruta, { method: 'POST',
          headers: { 'Authorization': 'Token ' + bTok, 'Content-Type': 'application/json' },
          body: JSON.stringify({ operacion: 'generar_anulacion', tipo_de_comprobante: (td === 'FACTURA') ? 1 : 2, serie: bSerie, numero: bNum, motivo: motivo.substring(0, 250) }) });
        const bBody = await bResp.json().catch(() => ({}));
        const bOk = (bResp.status === 200 || bResp.status === 201);
        const bAcept = bBody.aceptada_por_sunat === true || bBody.anulado === true;
        const nuevoEstado = bOk ? (bAcept ? 'BAJA_ACEPTADA' : 'BAJA_SOLICITADA') : 'BAJA_ERROR';
        await patchNf(nuevoEstado);
        if (!bOk) return json({ status: 'error', error: 'NubeFact baja HTTP ' + bResp.status, nuevoEstado, detalle: JSON.stringify(bBody).substring(0, 200) }, 502);
        return json({ status: 'success', nuevoEstado, aceptada: bAcept, pendiente: false });
      }
      // RECHAZADO (SUNAT lo rechazó) → no hay comprobante válido que dar de baja; marcar terminal.
      if (nfe === 'RECHAZADO') {
        await patchNf('ANULADO');
        return json({ status: 'success', nuevoEstado: 'ANULADO', pendiente: false, nota: 'CPE estaba RECHAZADO — sin baja que comunicar.' });
      }
      // PENDIENTE / EMITIENDO / '' / ANULADO_PEND_BAJA → aún no aceptado por SUNAT: se AGENDA. La reconciliación
      // (me.cpe_recon_candidatos + auto-baja) comunicará la baja SOLA apenas SUNAT lo acepte. Cubre "sin internet".
      await patchNf('ANULADO_PEND_BAJA');
      return json({ status: 'success', nuevoEstado: 'ANULADO_PEND_BAJA', pendiente: true,
        nota: 'CPE aún no aceptado por SUNAT — la baja se comunicará automáticamente al aceptarse.' });
    }

    // ── generar (emitir) — POS directo; el panel MOS puede emitir RE-VERIFICANDO la clave admin (misma
    //    barrera server-side que la BAJA, reverificar_clave_admin es stateless/bcrypt). Así la conversión
    //    NV→CPE desde MOS firma AL INSTANTE (con QR) en vez de quedar PENDIENTE. FAIL-CLOSED. ──
    if (appClaim !== 'mosExpress') {
      // [fix A1 · revisión senior] FAIL-CLOSED de verdad: MOS emite SOLO con clave admin PRESENTE. Sin esto,
      //  reverificar_clave_admin devuelve null (=permitido) ante clave vacía cuando MOS_STRICT_ADMIN_REVERIFY='0'
      //  (default) → se podría emitir sin PIN. Aquí se exige la clave, y luego reverificar la valida (bcrypt).
      if (!String(inp.claveAdmin || '').trim()) return json({ ok: false, autorizado: false, error: 'Clave admin requerida para emitir CPE desde MOS' }, 403);
      const _su = Deno.env.get('SUPABASE_URL'); const _sk = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
      const _rv = await fetch(`${_su}/rest/v1/rpc/reverificar_clave_admin`, {
        method: 'POST',
        headers: { 'apikey': _sk!, 'Authorization': 'Bearer ' + _sk!, 'Content-Profile': 'mos', 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_clave: String(inp.claveAdmin || ''), p_accion: 'CONVERTIR_NV_CPE', p_ref: String(correlativo || ''), p_app: String(appClaim || 'MOS') }),
      });
      const _rvj = _rv.ok ? await _rv.json().catch(() => ({ error: 'reverify parse' })) : { error: 'reverify HTTP ' + _rv.status };
      if (_rvj !== null && _rvj) return json({ ok: false, autorizado: false, error: String(_rvj.error || 'Clave admin requerida para emitir CPE desde MOS') }, 403);
    }
    if (!correlativo) return json({ ok: false, error: 'correlativo requerido' }, 400);
    // [Lote2-B · A4] Validar formato del correlativo. Antes `parseInt || 1` convertía
    // un correlativo malformado en el número 1 de la serie → duplicado en NubeFact →
    // el dedup devolvía el documento equivocado como "éxito" de la venta nueva.
    if (!/^[A-Za-z0-9]+-\d+$/.test(correlativo)) return json({ ok: false, error: 'correlativo malformado: ' + correlativo }, 400);
    if (tipoDoc !== 'BOLETA' && tipoDoc !== 'FACTURA') return json({ ok: false, error: 'tipoDoc inválido (BOLETA|FACTURA)' }, 400);

    // "B001-000000042" → serie=B001, numero=42
    const partes = correlativo.split('-');
    const serie = partes[0] || '';
    const numero = parseInt(partes[partes.length - 1], 10);
    if (!numero || numero < 1) return json({ ok: false, error: 'número de correlativo inválido' }, 400);
    const tipoComprobante = (tipoDoc === 'FACTURA') ? 1 : 2;

    // [F1 · review 100x · defensa-en-profundidad] La emisión es el ÚNICO punto fiscal que confía en el
    // caller (el frontend ya bloquea, y convertir_nv_cpe tiene el guard fuerte). Guard server-side extra:
    // NO emitir un CPE de una venta ANULADA. Best-effort: si figura ANULADO% → 409; si no se puede leer
    // (no encontrada / error de red) NO bloquea (fail-open) para no romper emisiones legítimas.
    try {
      const sbUrl = Deno.env.get('SUPABASE_URL'); const sbKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
      if (sbUrl && sbKey) {
        const q = await fetch(`${sbUrl}/rest/v1/ventas?select=forma_pago&correlativo=eq.${encodeURIComponent(correlativo)}&limit=1`,
          { headers: { 'apikey': sbKey, 'Authorization': 'Bearer ' + sbKey, 'Accept-Profile': 'me' } });
        const rows = await q.json().catch(() => null);
        const fp = Array.isArray(rows) && rows[0] ? String(rows[0].forma_pago || '').toUpperCase() : '';
        if (fp.startsWith('ANULADO')) {
          return json({ ok: false, error: 'VENTA_ANULADA: no se emite CPE de una venta anulada (' + correlativo + ')' }, 409);
        }
      }
    } catch (_) { /* fail-open: la protección primaria vive en el RPC/frontend */ }

    // ── Cálculo de totales por tipo de IGV (Catálogo 07 SUNAT) — FIEL a emitirNubeFact ──
    let totalGravada = 0, totalIVAP = 0, totalImpIVAP = 0, totalExonerada = 0, totalInafecta = 0;
    const nfItems = items.map((item: Record<string, unknown>) => {
      const tipoIgv = parseInt(String(item.tipo_igv ?? 1), 10);
      const cantidad = parseFloat(String(item.cantidad ?? 1));
      const precioTotal = parseFloat(String(item.subtotal ?? 0));
      // El valor unitario se DERIVA del subtotal realmente cobrado, no del que manda el POS.
      // El POS calcula precio/1.18 redondeado a 2 decimales; en GRANEL el subtotal no siempre es
      // precio × cantidad (0.050 kg de laurel a S/120 el kilo da S/6.00, pero se cobró S/7.50).
      // Multiplicar el valor_unitario recibido por la cantidad daba un valor de venta que no
      // cuadraba con el total y NubeFact rechazaba: "Error de cálculo de 'igv'". Este era el
      // TERCER motivo de rechazo (BM01-000212, BM01-000230, FM02-000036) — ~1 comprobante al día
      // antes del bug del IGV, y seguía abierto en la emisión original aunque el reintento del
      // servidor ya lo tenía resuelto. Misma matemática que reconciliar-cpe, que SUNAT ya aceptó.
      const subtotalVU = (tipoIgv === 1 || tipoIgv === 17) ? r2(precioTotal / (tipoIgv === 17 ? 1.04 : 1.18)) : r2(precioTotal);
      const valorUnitario = cantidad > 0 ? (subtotalVU / cantidad) : subtotalVU;
      let igvItem: number;
      // Catálogo NubeFact: 1 gravado · 8 exonerado · 9/10/11 inafecto · 17 IVAP.
      // Antes acá el 8 se sumaba a IVAP y el 9/10 a exonerada — al revés de lo que NubeFact
      // entiende. Con la traducción vieja (exonerado→9) el monto iba a total_exonerada mientras
      // la línea declaraba inafecto, y el rechazo era "Total INAFECTA debe ser mayor a cero".
      if (tipoIgv === 1) { igvItem = r2(precioTotal - subtotalVU); totalGravada += subtotalVU; }
      else if (tipoIgv === 17) { igvItem = r2(precioTotal - subtotalVU); totalIVAP += subtotalVU; totalImpIVAP += igvItem; }
      else if (tipoIgv === 8) { igvItem = 0; totalExonerada += precioTotal; }
      else { igvItem = 0; totalInafecta += precioTotal; }
      return {
        unidad_de_medida: String(item.unidad_de_medida || 'NIU'),
        codigo: String(item.sku || ''), codigo_producto_sunat: String(item.cod_sunat || ''),
        descripcion: String(item.nombre || ''), cantidad,
        // 6 decimales: con cantidades fraccionarias (0.050 kg) redondear a 2 rompe la línea.
        valor_unitario: Math.round(valorUnitario * 1e6) / 1e6,
        precio_unitario: cantidad > 0 ? Math.round((precioTotal / cantidad) * 1e6) / 1e6 : precioTotal,
        descuento: '', subtotal: subtotalVU, tipo_de_igv: tipoIgv, igv: igvItem, total: precioTotal,
        anticipo_regularizacion: false, anticipo_documento_serie: '', anticipo_documento_numero: '',
      };
    });
    totalGravada = r2(totalGravada); totalIVAP = r2(totalIVAP); totalImpIVAP = r2(totalImpIVAP);
    totalExonerada = r2(totalExonerada); totalInafecta = r2(totalInafecta);
    const totalGeneral = parseFloat(String(header.total ?? 0));
    const totalIgv = r2(totalGeneral - totalGravada - totalIVAP - totalExonerada - totalInafecta);

    const cliente = header.cliente || {};
    const now = new Date();
    // dd-MM-yyyy en hora Perú (UTC-5, sin DST)
    const lima = new Date(now.getTime() - 5 * 3600 * 1000);
    const fechaHoy = `${String(lima.getUTCDate()).padStart(2, '0')}-${String(lima.getUTCMonth() + 1).padStart(2, '0')}-${lima.getUTCFullYear()}`;

    const payload = {
      operacion: 'generar_comprobante', tipo_de_comprobante: tipoComprobante, serie, numero,
      sunat_transaction: 1,
      cliente_tipo_de_documento: parseInt(String(cliente.tipo ?? 0), 10),
      // [SUNAT] tipo 0 = consumidor sin documento (boleta VARIOS < S/700) → número '0', no el 66666 interno.
      cliente_numero_de_documento: (parseInt(String(cliente.tipo ?? 0), 10) === 0) ? '0' : String(cliente.doc || '0'),
      cliente_denominacion: String(cliente.nombre || 'CLIENTE ANONIMO'),
      cliente_direccion: String(cliente.direccion || ''), cliente_email: '',
      fecha_de_emision: fechaHoy, fecha_de_vencimiento: '', moneda: 1, tipo_de_cambio: '',
      porcentaje_de_igv: 18,
      total_gravada: totalGravada > 0 ? totalGravada : '', total_ivap: totalIVAP > 0 ? totalIVAP : '',
      total_imp_ivap: totalImpIVAP > 0 ? totalImpIVAP : '', total_exonerada: totalExonerada > 0 ? totalExonerada : '',
      total_inafecta: totalInafecta > 0 ? totalInafecta : '', total_igv: totalIgv > 0 ? totalIgv : '',
      total_precio_de_venta: totalGeneral, total_descuentos: '', total_otros_cargos: '', total: totalGeneral,
      detraccion: false, enviar_automaticamente_a_la_sunat: true, enviar_automaticamente_al_cliente: false,
      formato_de_pdf: 'TICKET', items: nfItems,
    };

    const endpoint = ruta;   // ruta dedicada NubeFact — el body lleva tipo_de_comprobante (1=factura,2=boleta)
    const tok = pickToken(serie);   // [go-live] token del local segun la serie (BM01/FM01=Z1, BM02/FM02=Z2)
    if (!tok) return json({ ok: false, error: 'sin token NubeFact para la serie ' + serie }, 500);
    let resp = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Authorization': 'Token ' + tok, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    let body = await resp.json().catch(() => ({}));
    // [FM01-000059 · 19-ago] "Código de Producto SUNAT incorrecto": un producto del catálogo traía
    // un código UNSPSC que NubeFact no reconoce (50111509). El código de producto SUNAT es
    // OPCIONAL en el comprobante —la reemisión del servidor ya lo manda vacío y SUNAT acepta—,
    // así que si esa es la única queja se reintenta UNA vez sin códigos, en el acto, y la venta
    // no se queda una hora esperando al cron. El catálogo se corrige aparte.
    if (resp.status === 400 && /c[oó]digo de producto sunat/i.test(String((body && (body.errors || body.message || body.error)) || ''))) {
      const payload2 = { ...payload, items: nfItems.map((it) => ({ ...it, codigo_producto_sunat: '' })) };
      resp = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Authorization': 'Token ' + tok, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload2),
      });
      body = await resp.json().catch(() => ({}));
    }

    if (resp.status === 200 || resp.status === 201) {
      // El comprobante SE GENERÓ (NubeFact firmó + dio QR/hash/PDF). La aceptación SUNAT es ASÍNCRONA:
      //   · aceptada_por_sunat=true                          → EMITIDO (CDR recibido)
      //   · false CON sunat_description/responsecode de error → RECHAZADO real
      //   · false SIN error (description/code null/vacío)     → PENDIENTE (SUNAT aún procesa; en demo puede
      //     quedar así). NO es rechazo: el QR/hash son válidos para el ticket; la reconciliación lo flipea.
      const aceptada = body.aceptada_por_sunat === true;
      const sunatDesc = String(body.sunat_description || '').trim();
      const respCode = body.sunat_responsecode;
      const tieneErrSunat = !!sunatDesc || (respCode !== null && respCode !== undefined &&
        String(respCode).trim() !== '' && String(respCode).trim() !== '0');
      const comun = {
        hash: String(body.codigo_hash || ''), enlace: String(body.enlace_del_pdf || ''),
        qrString: String(body.cadena_para_codigo_qr || ''), sunatDescription: sunatDesc,
        sunat_code: (respCode != null ? String(respCode) : ''),   // [500x-2b] capturar codigo SUNAT del rechazo
        enlace_xml: String(body.enlace_del_xml || ''), enlace_cdr: String(body.enlace_del_cdr || ''),
        numero_orden_sunat: String(body.numero_de_orden_sunat || ''),
      };
      if (!aceptada && tieneErrSunat) {
        // SUNAT rechazó el comprobante que NubeFact sí aceptó: aviso al MASTER al instante.
        try {
          const sbUrl3 = Deno.env.get('SUPABASE_URL'), sbKey3 = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
          if (sbUrl3 && sbKey3) await fetch(`${sbUrl3}/rest/v1/rpc/cpe_avisar_rechazo`, {
            method: 'POST',
            headers: { 'apikey': sbKey3, 'Authorization': 'Bearer ' + sbKey3, 'Content-Profile': 'me', 'Content-Type': 'application/json' },
            body: JSON.stringify({ p: { correlativo, origen: 'SUNAT', http: String(respCode ?? ''), motivo: (sunatDesc || ('código ' + respCode)).slice(0, 300),
                                        total: parseFloat(String(header.total ?? 0)) || 0 } }),
          });
        } catch (_) { /* best-effort */ }
        return json({ ok: false, rechazadoPorSunat: true, error: 'SUNAT rechazó: ' + (sunatDesc || ('código ' + respCode)), ...comun });
      }
      // EMITIDO (aceptada) o PENDIENTE (async) — ambos con comprobante válido.
      return json({ ok: true, aceptada, estado: aceptada ? 'EMITIDO' : 'PENDIENTE', ...comun });
    }

    // Duplicado (HTTP 400 "ya fue informado") → consultar el existente y devolver como éxito (idempotencia)
    const errMsg = String(body.errors || body.message || '');
    if (/ya\s+fue\s+informado|duplicad|comprobante\s+ya\s+existe|already\s+exists/i.test(errMsg)) {
      const cons = await consultar(serie, numero, tipoComprobante, ruta, tok);
      if (cons.ok) {
        // [500x-2b] si el duplicado fue RECHAZADO por SUNAT, propagar el rechazo (no degradar a PENDIENTE)
        if (cons.rechazado) return json({ ok: false, rechazadoPorSunat: true, dedupNubeFact: true, error: 'SUNAT rechazó: ' + (cons.sunatDescription || ('código ' + cons.sunat_code)), ...cons });
        return json({ ...cons, estado: cons.aceptada ? 'EMITIDO' : 'PENDIENTE', dedupNubeFact: true });
      }
    }
    // NubeFact rechazó y NO es duplicado: avisar AL INSTANTE, con el motivo. Antes esto volvía
    // a la caja como {ok:false}, la venta quedaba PENDIENTE muda, y el dueño se enteraba a los
    // 20 min por el vigilante (sin motivo) y del motivo recién una hora después, cuando el cron
    // reintentaba y volvía a fallar. NubeFact lo dijo con todas las letras en el segundo cero.
    // Best-effort: si el aviso falla, la respuesta a la caja no cambia.
    try {
      const sbUrl2 = Deno.env.get('SUPABASE_URL'), sbKey2 = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
      if (sbUrl2 && sbKey2) {
        await fetch(`${sbUrl2}/rest/v1/rpc/cpe_avisar_rechazo`, {
          method: 'POST',
          headers: { 'apikey': sbKey2, 'Authorization': 'Bearer ' + sbKey2, 'Content-Profile': 'me', 'Content-Type': 'application/json' },
          body: JSON.stringify({ p: { correlativo, http: String(resp.status), motivo: errMsg.slice(0, 300),
                                      total: parseFloat(String(header.total ?? 0)) || 0 } }),
        });
      }
    } catch (_) { /* el aviso es best-effort */ }
    return json({ ok: false, error: 'HTTP ' + resp.status + ': ' + errMsg.slice(0, 250) }, 502);
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
