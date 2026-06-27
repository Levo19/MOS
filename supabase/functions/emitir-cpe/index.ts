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
      return {
        ok: true, aceptada: body.aceptada_por_sunat === true,
        hash: String(body.codigo_hash || ''), enlace: String(body.enlace_del_pdf || ''),
        qrString: String(body.cadena_para_codigo_qr || ''), enlace_xml: String(body.enlace_del_xml || ''),
        enlace_cdr: String(body.enlace_del_cdr || ''), numero_orden_sunat: String(body.numero_de_orden_sunat || ''),
        sunatDescription: String(body.sunat_description || ''),
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
    if (!claims || claims.app !== 'mosExpress') return json({ ok: false, error: 'no autorizado (claim app)' }, 401);

    // [Lote2-B · C1] Kill-switch server-side ANTES de tocar NubeFact.
    if (!(await cpeDirectoOn())) return json({ ok: false, error: 'CPE_DIRECTO_DESACTIVADO' }, 403);

    const token = Deno.env.get('NUBEFACT_TOKEN');
    const ruta = Deno.env.get('NUBEFACT_RUTA');   // URL dedicada NubeFact (api/v1/<UUID>), en SECRET
    if (!token || !ruta) return json({ ok: false, error: 'NubeFact no configurado (secrets NUBEFACT_TOKEN/NUBEFACT_RUTA)' }, 500);

    const inp = await req.json().catch(() => ({}));
    const data = inp.data || {};
    const correlativo = String(inp.correlativo || '');
    const header = data.header || {};
    const items = data.items || [];
    const tipoDoc = header.tipoDoc;
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

    // ── Cálculo de totales por tipo de IGV (Catálogo 07 SUNAT) — FIEL a emitirNubeFact ──
    let totalGravada = 0, totalIVAP = 0, totalImpIVAP = 0, totalExonerada = 0, totalInafecta = 0;
    const nfItems = items.map((item: Record<string, unknown>) => {
      const tipoIgv = parseInt(String(item.tipo_igv ?? 1), 10);
      const cantidad = parseFloat(String(item.cantidad ?? 1));
      const valorUnitario = parseFloat(String(item.valor_unitario ?? 0));
      const subtotalVU = r2(valorUnitario * cantidad);
      const precioTotal = parseFloat(String(item.subtotal ?? 0));
      let igvItem: number;
      if (tipoIgv === 1) { igvItem = r2(precioTotal - subtotalVU); totalGravada += subtotalVU; }
      else if (tipoIgv === 8) { igvItem = r2(precioTotal - subtotalVU); totalIVAP += subtotalVU; totalImpIVAP += igvItem; }
      else if (tipoIgv === 9 || tipoIgv === 10) { igvItem = 0; totalExonerada += precioTotal; }
      else { igvItem = 0; totalInafecta += precioTotal; }
      return {
        unidad_de_medida: String(item.unidad_de_medida || 'NIU'),
        codigo: String(item.sku || ''), codigo_producto_sunat: String(item.cod_sunat || ''),
        descripcion: String(item.nombre || ''), cantidad,
        valor_unitario: r2(valorUnitario), precio_unitario: parseFloat(String(item.precio ?? 0)),
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
      cliente_numero_de_documento: String(cliente.doc || '0'),
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
    const resp = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Authorization': 'Token ' + token, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const body = await resp.json().catch(() => ({}));

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
        enlace_xml: String(body.enlace_del_xml || ''), enlace_cdr: String(body.enlace_del_cdr || ''),
        numero_orden_sunat: String(body.numero_de_orden_sunat || ''),
      };
      if (!aceptada && tieneErrSunat) {
        return json({ ok: false, rechazadoPorSunat: true, error: 'SUNAT rechazó: ' + (sunatDesc || ('código ' + respCode)), ...comun });
      }
      // EMITIDO (aceptada) o PENDIENTE (async) — ambos con comprobante válido.
      return json({ ok: true, aceptada, estado: aceptada ? 'EMITIDO' : 'PENDIENTE', ...comun });
    }

    // Duplicado (HTTP 400 "ya fue informado") → consultar el existente y devolver como éxito (idempotencia)
    const errMsg = String(body.errors || body.message || '');
    if (/ya\s+fue\s+informado|duplicad|comprobante\s+ya\s+existe|already\s+exists/i.test(errMsg)) {
      const cons = await consultar(serie, numero, tipoComprobante, ruta, token);
      if (cons.ok) return json({ ...cons, dedupNubeFact: true });
    }
    return json({ ok: false, error: 'HTTP ' + resp.status + ': ' + errMsg.slice(0, 250) }, 502);
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
