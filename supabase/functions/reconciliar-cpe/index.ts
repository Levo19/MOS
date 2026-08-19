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

// ══════════════════════════════════════════════════════════════════════════════════════
// REEMITIR. Esto es lo que no existía y por lo que 31 facturas se quedaron sin llegar a
// SUNAT: cuando la emisión original falla, MosExpress deja la venta PENDIENTE confiando en
// que "la reconciliación la re-emite". No la re-emitía — este archivo solo consultaba.
//
// La matemática de totales es la MISMA de emitir-cpe, campo por campo. Y antes de mandar
// nada hay un cerrojo: se recalcula el total desde los ítems y si no cuadra al céntimo con
// el total de la venta guardada, NO se emite. Un comprobante con otro monto que la venta es
// peor que un comprobante que falta.
//
// Diferencia deliberada con emitir-cpe: la fecha_de_emision es la de la VENTA, no la de hoy.
// El comprobante documenta esa venta, de ese día. Reemitir con fecha de hoy movería el
// período — y eso lo decide el contador, no este código.
// ══════════════════════════════════════════════════════════════════════════════════════
function armarPayloadNF(data: Record<string, any>, serie: string, numero: number,
                        tipoComprobante: number, fechaEmision: string, legacy = true) {
  const header = data.header || {};
  const items = data.items || [];
  let totalGravada = 0, totalIVAP = 0, totalImpIVAP = 0, totalExonerada = 0, totalInafecta = 0;
  // ── LA TRADUCCIÓN QUE FALTABA ─────────────────────────────────────────────────────
  // El catálogo guarda 9 para EXONERADO. Pero en NubeFact 9 es INAFECTO — su rechazo lo dice
  // con todas las letras: "codigo Tributo: 9998", que es el código SUNAT de inafecto. En
  // NubeFact el exonerado es 8. Por eso, desde el 14-ago (el día en que se pasaron 87
  // productos a 9), TODO comprobante con un exonerado fue rechazado en la pre-validación:
  // el monto se declaraba en total_exonerada mientras la línea decía "inafecto", y NubeFact
  // contestaba "Total INAFECTA debe ser mayor a cero".
  // `legacy` = la venta es anterior al arreglo del 866. Entre el 14 y el 18 de agosto el
  // catálogo entregaba 9 para EXONERADO, y en NubeFact el 9 es inafecto. Desde el 866 entrega
  // 8 = exonerado y 9 = inafecto, que ya son los códigos de NubeFact y pasan tal cual.
  // Sin esta distinción, reemitir una venta vieja la mandaría como inafecta y una nueva con
  // exonerado se mandaría como IVAP: el mismo número significa cosas distintas a cada lado
  // de la fecha de corte.
  const aNubeFact = (t: number): number => legacy ? (t === 9 ? 8 : t === 11 ? 9 : t === 8 ? 17 : t) : t;
  const nfItems = items.map((item: Record<string, unknown>) => {
    const tipoIgv = aNubeFact(parseInt(String(item.tipo_igv ?? 1), 10));
    const cantidad = parseFloat(String(item.cantidad ?? 1));
    const precioTotal = parseFloat(String(item.subtotal ?? 0));
    // El valor unitario se DERIVA del subtotal realmente cobrado, no del precio de lista.
    // En granel el subtotal no siempre es precio × cantidad: 0.050 kg de laurel a S/120 el kilo
    // da S/6.00, pero se cobró S/7.50. Multiplicar el valor_unitario guardado por la cantidad
    // daba un valor de venta que no cuadraba con el total, y NubeFact rechazaba por
    // "Error de cálculo de 'igv'". Derivándolo del subtotal, la línea siempre cierra y el
    // monto que pagó el cliente se respeta exacto — que es lo único que no se puede mover.
    const subtotalVU = (tipoIgv === 1 || tipoIgv === 17) ? r2(precioTotal / 1.18) : r2(precioTotal);
    const valorUnitario = cantidad > 0 ? (subtotalVU / cantidad) : subtotalVU;
    let igvItem: number;
    // Los totales se agrupan por el código de NubeFact, no por el nuestro:
    //   1 gravado · 8 exonerado · 9/10/11 inafecto · 17 IVAP
    if (tipoIgv === 1) { igvItem = r2(precioTotal - subtotalVU); totalGravada += subtotalVU; }
    else if (tipoIgv === 17) { igvItem = r2(precioTotal - subtotalVU); totalIVAP += subtotalVU; totalImpIVAP += igvItem; }
    else if (tipoIgv === 8) { igvItem = 0; totalExonerada += precioTotal; }
    else { igvItem = 0; totalInafecta += precioTotal; }
    return {
      unidad_de_medida: String(item.unidad_de_medida || 'NIU'),
      codigo: String(item.sku || ''), codigo_producto_sunat: String(item.cod_sunat || ''),
      descripcion: String(item.nombre || ''), cantidad,
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
  // EL CERROJO: la suma de las líneas tiene que dar el total de la venta, al céntimo.
  const sumaLineas = r2(nfItems.reduce((a: number, it: Record<string, any>) => a + parseFloat(String(it.total ?? 0)), 0));
  if (Math.abs(sumaLineas - totalGeneral) > 0.009) {
    return { error: 'DESCUADRE: items suman ' + sumaLineas.toFixed(2) + ' y la venta dice ' + totalGeneral.toFixed(2) };
  }
  const cliente = header.cliente || {};
  return { payload: {
    operacion: 'generar_comprobante', tipo_de_comprobante: tipoComprobante, serie, numero,
    sunat_transaction: 1,
    cliente_tipo_de_documento: parseInt(String(cliente.tipo ?? 0), 10),
    cliente_numero_de_documento: (parseInt(String(cliente.tipo ?? 0), 10) === 0) ? '0' : String(cliente.doc || '0'),
    cliente_denominacion: String(cliente.nombre || 'CLIENTE ANONIMO'),
    cliente_direccion: String(cliente.direccion || ''), cliente_email: '',
    fecha_de_emision: fechaEmision, fecha_de_vencimiento: '', moneda: 1, tipo_de_cambio: '',
    porcentaje_de_igv: 18,
    total_gravada: totalGravada > 0 ? totalGravada : '', total_ivap: totalIVAP > 0 ? totalIVAP : '',
    total_imp_ivap: totalImpIVAP > 0 ? totalImpIVAP : '', total_exonerada: totalExonerada > 0 ? totalExonerada : '',
    total_inafecta: totalInafecta > 0 ? totalInafecta : '', total_igv: totalIgv > 0 ? totalIgv : '',
    total_precio_de_venta: totalGeneral, total_descuentos: '', total_otros_cargos: '', total: totalGeneral,
    detraccion: false, enviar_automaticamente_a_la_sunat: true, enviar_automaticamente_al_cliente: false,
    formato_de_pdf: 'TICKET', items: nfItems,
  } };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const url = Deno.env.get('SUPABASE_URL');
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const ruta = Deno.env.get('NUBEFACT_RUTA');
    const cronSecret = Deno.env.get('CPE_CRON_SECRET');
    // [fix go-live] TOKEN POR LOCAL: NubeFact da un token por establecimiento (por serie). El go-live
    // usa NUBEFACT_TOKENS = JSON { "<serie>": "<token>" }, con fallback a NUBEFACT_TOKEN (demo/único).
    // Antes este Edge leía SOLO NUBEFACT_TOKEN → al pasar al mapa por local ese secret quedó vacío y
    // TODA reconciliación moría en "NubeFact no configurado" (500) → las boletas jamás salían de
    // PENDIENTE aunque SUNAT ya las aceptara por resumen. Ahora idéntico a emitir-cpe: token por serie.
    let tokensMap: Record<string, string> = {};
    try {
      const raw = JSON.parse(Deno.env.get('NUBEFACT_TOKENS') || '{}');
      // [hardening fiscal] normalizar claves (trim + UPPER) — igual que emitir-cpe.
      tokensMap = Object.fromEntries(Object.entries(raw).map(([k, v]) => [String(k).trim().toUpperCase(), v as string]));
    } catch { tokensMap = {}; }
    const fallbackTok = Deno.env.get('NUBEFACT_TOKEN') || '';
    // [hardening fiscal] MULTI-LOCAL: serie no mapeada → FALLAR CERRADO (''), nunca al fallback único
    // (evita reconciliar/comunicar baja contra el local equivocado). Fallback solo en modo un-token.
    const pickToken = (serie: string): string => {
      const s = String(serie || '').trim().toUpperCase();
      return Object.keys(tokensMap).length ? (tokensMap[s] || '') : fallbackTok;
    };
    if (!url || !key) return json({ ok: false, error: 'plataforma no configurada' }, 500);
    if (!cronSecret || req.headers.get('x-cpe-cron') !== cronSecret) return json({ ok: false, error: 'no autorizado (cron secret)' }, 401);
    if (!ruta || (!fallbackTok && Object.keys(tokensMap).length === 0)) return json({ ok: false, error: 'NubeFact no configurado (NUBEFACT_RUTA + NUBEFACT_TOKENS o NUBEFACT_TOKEN)' }, 500);
    if (!(await cpeDirectoOn(url, key))) return json({ ok: false, error: 'CPE_DIRECTO_DESACTIVADO' }, 403);

    const inp = await req.json().catch(() => ({}));
    // [500x-2b] ventana >= 45d (cubre el sweep GAS de 35d + margen); SUNAT puede aceptar dias despues.
    const dias = Math.min(Math.max(parseInt(String(inp.dias ?? 45), 10) || 45, 1), 90);
    const limite = Math.min(Math.max(parseInt(String(inp.limite ?? 50), 10) || 50, 1), 200);
    // CENSO: consulta y reporta, sin escribir NADA y sin comunicar ninguna baja. Sirve para
    // saber, antes de tocar SUNAT, cuáles comprobantes existen allá y cuáles no.
    const censo = inp.censo === true;
    // REEMITIR: para los que NubeFact confirma que no existen, emitirlos de verdad.
    const reemitir = inp.reemitir === true && !censo;
    // Permite acotar la corrida a una lista concreta — para empezar por UNO y mirar el resultado
    // antes de soltar los 55.
    const solo: string[] = Array.isArray(inp.soloCorrelativos)
      ? inp.soloCorrelativos.map((x: unknown) => String(x).trim().toUpperCase()).filter(Boolean) : [];

    // [505] Candidatos vía RPC (me.cpe_recon_candidatos): pendientes NORMALES + ANULADAS que aún deben
    // comunicar la baja. Cada fila trae `anulada` (forma_pago='ANULADO') → decide la acción fiscal.
    const rp = await fetch(`${url}/rest/v1/rpc/cpe_recon_candidatos`, {
      method: 'POST',
      headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Profile': 'me', 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_dias: dias, p_limite: limite }),
    });
    if (!rp.ok) return json({ ok: false, error: 'lectura candidatos HTTP ' + rp.status }, 502);
    let pend = await rp.json().catch(() => []);
    if (Array.isArray(pend) && solo.length) {
      pend = pend.filter((r: Record<string, unknown>) => solo.includes(String(r.correlativo || '').trim().toUpperCase()));
    }
    if (!Array.isArray(pend) || pend.length === 0) return json({ ok: true, revisados: 0, emitidos: 0, rechazados: 0, bajas: 0, agendadas: 0, sin_cambio: 0, detalle: [] });

    // helper: persistir un nf_estado simple (baja/anulación) vía service-role.
    const setEstado = (ref: string, nf: Record<string, unknown>) => censo
      ? Promise.resolve({ ok: true, status: 200 } as Response)
      : fetch(`${url}/rest/v1/rpc/set_cpe_nf`, {
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
      const tok = pickToken(m[1]);   // [fix] token por serie/local
      if (!tok) { sinCambio++; detalle.push({ correlativo: corr, accion: 'sin_token_para_serie_' + m[1] }); continue; }
      const cons = await consultar(m[1], parseInt(m[2], 10), tipoComprobante, ruta, tok);
      if (!cons.ok) {
        // La consulta falló (red, o NubeFact dice "no existe"). Si la venta está ANULADA, dejarla en
        // ANULADO_PEND_BAJA (visible + se reintenta el próximo ciclo) en vez de terminal: "no existe" puede
        // ser transitorio, y marcar ANULADO nos haría PERDER la baja si el comprobante sí existía y se acepta.
        if (anulada && row.nf_estado !== 'ANULADO_PEND_BAJA') { await setEstado(row.ref_local, { nf_estado: 'ANULADO_PEND_BAJA' }); }
        if (anulada) { agendadas++; detalle.push({ correlativo: corr, accion: (cons.noExiste ? 'anulada_no_existe_reintenta' : 'anulada_consulta_fallo') }); }
        else if (cons.noExiste && reemitir) {
          // ACÁ está el agujero que dejó 31 facturas fuera de SUNAT: NubeFact confirma que el
          // comprobante nunca llegó. Antes se contaba como "sin cambio" y se seguía de largo.
          const pay = await fetch(`${url}/rest/v1/rpc/cpe_payload_reemision`, {
            method: 'POST',
            headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Profile': 'me', 'Content-Type': 'application/json' },
            body: JSON.stringify({ p: { correlativo: corr } }),
          });
          const pj = await pay.json().catch(() => null);
          if (!pj || pj.ok !== true) { sinCambio++; detalle.push({ correlativo: corr, accion: 'reemision_sin_payload', error: (pj && pj.error) || 'HTTP ' + pay.status }); continue; }
          // NubeFact solo acepta comprobantes con fecha de HOY. Un comprobante de ayer ya no
          // se puede emitir con su fecha original, y emitirlo con la de hoy movería el período
          // fiscal — eso lo decide el contador. Así que el reintento automático cubre SOLO el
          // día en curso: es donde sirve y donde no hay que decidir nada.
          const hoyLima = new Date(Date.now() - 5 * 3600 * 1000);
          const hoyStr = `${String(hoyLima.getUTCDate()).padStart(2,'0')}-${String(hoyLima.getUTCMonth()+1).padStart(2,'0')}-${hoyLima.getUTCFullYear()}`;
          const fechaUsar = String(inp.fechaHoy === true ? hoyStr : pj.data.fecha_venta);
          if (fechaUsar !== hoyStr) {
            await setEstado(row.ref_local, {
              nf_estado: 'PENDIENTE', consultado: true,
              sunat_desc: 'FUERA DE PLAZO: NubeFact solo acepta comprobantes con fecha de HOY. '
                        + 'Este es del ' + pj.data.fecha_venta + ' y requiere decisión del contador.',
              sunat_code: 'PLAZO',
            });
            sinCambio++;
            detalle.push({ correlativo: corr, accion: 'fuera_de_plazo_requiere_decision', fecha: pj.data.fecha_venta, total: pj.data.data.header.total });
            continue;
          }
          const armado = armarPayloadNF(pj.data.data, m[1], parseInt(m[2], 10), tipoComprobante,
                                        fechaUsar, pj.data.igv_legacy !== false);
          if ((armado as Record<string, unknown>).error) {
            sinCambio++; detalle.push({ correlativo: corr, accion: 'reemision_descuadre', error: (armado as Record<string, string>).error }); continue;
          }
          let em: Record<string, unknown> = {};
          try {
            const rr = await fetch(ruta, {
              method: 'POST',
              headers: { 'Authorization': 'Token ' + tok, 'Content-Type': 'application/json' },
              body: JSON.stringify((armado as Record<string, unknown>).payload),
            });
            const bb = await rr.json().catch(() => ({}));
            const acept = bb.aceptada_por_sunat === true;
            const sdesc = String(bb.sunat_description || bb.errors || '').trim();
            if (rr.status === 200 || rr.status === 201) {
              em = { nf_estado: acept ? 'EMITIDO' : 'PENDIENTE', nf_hash: String(bb.codigo_hash || ''),
                     nf_enlace: String(bb.enlace_del_pdf || ''), nf_qr: String(bb.cadena_para_codigo_qr || ''),
                     aceptada: acept, sunat_desc: sdesc,
                     sunat_code: (bb.sunat_responsecode != null ? String(bb.sunat_responsecode) : ''),
                     enlace_xml: String(bb.enlace_del_xml || ''), enlace_cdr: String(bb.enlace_del_cdr || ''),
                     numero_orden_sunat: String(bb.numero_de_orden_sunat || ''), consultado: true };
            } else {
              // EL MOTIVO SE GUARDA. Antes el rechazo de NubeFact moría en el log de un cron que
              // nadie leía: el comprobante quedaba "sin emitir" en Tributario, sin decir por qué,
              // y no había forma de enterarse. Ahora el motivo viaja a nf_sunat_desc y lo pinta
              // el card, junto al push del vigilante.
              await setEstado(row.ref_local, {
                nf_estado: 'PENDIENTE', consultado: true,
                sunat_desc: 'RECHAZO NubeFact (' + rr.status + '): ' + sdesc.slice(0, 300),
                sunat_code: 'NF_' + rr.status,
              });
              sinCambio++; detalle.push({ correlativo: corr, accion: 'reemision_rechazada', http: rr.status, error: sdesc.slice(0, 180) }); continue;
            }
          } catch (e) {
            sinCambio++; detalle.push({ correlativo: corr, accion: 'reemision_error_red', error: String((e as Error)?.message || e).slice(0, 120) }); continue;
          }
          const sp2 = await setEstado(row.ref_local, em);
          if (sp2.ok) { emitidos++; detalle.push({ correlativo: corr, accion: 'REEMITIDO_' + String(em.nf_estado), fecha: pj.data.fecha_venta, total: pj.data.data.header.total }); }
          else { sinCambio++; detalle.push({ correlativo: corr, accion: 'reemitido_pero_no_persistio_HTTP_' + sp2.status }); }
          continue;
        }
        else { sinCambio++; detalle.push({ correlativo: corr, accion: cons.noExiste ? 'no_existe_nubefact' : 'consulta_fallo' }); }
        continue;
      }

      // ── Rama ANULADA: la venta ya no cuenta (pago reversado); resolver el lado fiscal ──
      if (anulada) {
        if (cons.aceptada) {
          if (censo) { sinCambio++; detalle.push({ correlativo: corr, accion: 'censo_anulada_aceptada_falta_baja' }); continue; }
          // SUNAT lo aceptó → comunicar la baja YA (auto-baja).
          const b = await generarBaja(m[1], parseInt(m[2], 10), tipoComprobante, ruta, tok);
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
    return json({ ok: true, modo: censo ? 'censo' : (reemitir ? 'reemitir' : 'normal'),
                  revisados: pend.length, emitidos, rechazados, bajas, agendadas, sin_cambio: sinCambio, detalle });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
