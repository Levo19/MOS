// Edge Function `ticket-guia` — ARMA el ticket ESC/POS 80mm de una guía WH (100% Postgres) y, salvo
// soloBase64, lo manda a PrintNode. Reemplaza el salto a GAS imprimirTicketGuia para el ciclo "cero-GAS".
//
// El armado de bytes ESC/POS (b1/bStr/bLn, lineaDet/lineaProd/lineaKV, fmtVenc, _wrapPalabras,
// _clasificarDetallesPorPickup y TODO el bloque de construcción header/cuadro/secciones/totales/feed+corte)
// es COPIA LITERAL de gas/Reporte.gs::imprimirTicketGuia — el layout debe quedar idéntico byte-por-byte.
//
// AUTORIZACIÓN: la plataforma verifica la FIRMA del JWT (verify_jwt=true). Acá exigimos claim app ∈ APPS_OK.
//
// LECTURA: 100% Supabase Postgres vía PostgREST con SERVICE_ROLE:
//   wh.guias (id_guia) · wh.guia_detalle (id_guia, filtra observacion='ANULADO') · mos.proveedores (nombre).
//
// SECRETS requeridos:
//   SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY (inyectados por la plataforma) · PRINTNODE_API_KEY (set manual).

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

// Decodifica el payload del JWT (la FIRMA ya la validó la plataforma; acá solo leemos claims).
function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1];
    if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64));
  } catch {
    return null;
  }
}

// ── PostgREST lector con SERVICE_ROLE ────────────────────────────────────────
const SB_URL = Deno.env.get('SUPABASE_URL') || '';
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';

// deno-lint-ignore no-explicit-any
async function sbSelect(profile: string, table: string, query: string): Promise<any[]> {
  const url = `${SB_URL}/rest/v1/${table}?${query}`;
  const resp = await fetch(url, {
    headers: {
      'apikey': SB_KEY,
      'Authorization': 'Bearer ' + SB_KEY,
      'Accept-Profile': profile,
      'Content-Type': 'application/json',
    },
  });
  if (!resp.ok) throw new Error('PostgREST ' + resp.status + ' ' + table + ': ' + (await resp.text()));
  return await resp.json();
}

// ── _wrapPalabras — COPIA LITERAL de gas/Reporte.gs:1623 ─────────────────────
function _wrapPalabras(texto: string, anchoPrimero: number, anchoResto?: number): string[] {
  texto = String(texto || '').trim();
  if (!texto) return [''];
  if (anchoResto == null) anchoResto = anchoPrimero;

  var palabras = texto.split(/\s+/);
  var lineas: string[] = [];
  var cur = '';
  var ancho = anchoPrimero;

  for (var i = 0; i < palabras.length; i++) {
    var p = palabras[i];
    // Palabra más larga que el ancho — partir la palabra como último recurso
    while (p.length > ancho) {
      if (cur) { lineas.push(cur); cur = ''; ancho = anchoResto; }
      lineas.push(p.substring(0, ancho));
      p = p.substring(ancho);
    }
    var sep = cur ? ' ' : '';
    if ((cur + sep + p).length <= ancho) {
      cur = cur + sep + p;
    } else {
      lineas.push(cur);
      cur = p;
      ancho = anchoResto;
    }
  }
  if (cur) lineas.push(cur);
  return lineas;
}

// ── _padLine48 — COPIA LITERAL de gas/Reporte.gs:181 ─────────────────────────
function _padLine48(left: string, right: string): string {
  var l = String(left || '');
  var r = String(right || '');
  var pad = 48 - l.length - r.length;
  if (pad < 1) pad = 1;
  return l + Array(pad + 1).join(' ') + r;
}

// ── _clasificarDetallesPorPickup — COPIA del clasificador de gas/Reporte.gs:69 ─
// ⚠️ CÓDIGO MUERTO (NO se ejecuta). Se conserva para reactivar cuando el GAS también
// clasifique pickups de Supabase. HOY el GAS muestra la lista simple → este Edge hace
// lo mismo (ver "CUADRO 2: productos" donde se fuerza pickupClasif.hasPickup=false).
// DIFERENCIA OBLIGADA (cuando se reactive): el GAS lee la hoja PICKUPS por su API de
// Sheet. Acá no hay Sheet; el pickup vive como JSON en wh.pickups.items.
// deno-lint-ignore no-explicit-any no-unused-vars
function _clasificarDetallesPorPickup(g: any, dets: any[], pickupItems: any[] | null) {
  var out: any = { hasPickup: false, ok: [], extras: [], faltantes: [] };
  var comentario = String(g.comentario || '');
  var m = comentario.match(/\[pickup:([^\]]+)\]/);
  if (!m) return out;
  if (!pickupItems || !Array.isArray(pickupItems)) return out;

  out.hasPickup = true;

  // Mapa codigoBarra (upper) → { item del pickup, índice }
  var codToItem: any = {};
  pickupItems.forEach(function (it: any, idx: number) {
    var codos = (it.codigosOriginales || []);
    codos.forEach(function (c: any) {
      if (!c) return;
      codToItem[String(c).trim().toUpperCase()] = { item: it, idx: idx };
    });
    if (it.skuBase) codToItem[String(it.skuBase).trim().toUpperCase()] = { item: it, idx: idx };
    if (it.despachadoPorCodigo && typeof it.despachadoPorCodigo === 'object') {
      Object.keys(it.despachadoPorCodigo).forEach(function (c) {
        if (!c) return;
        codToItem[String(c).trim().toUpperCase()] = { item: it, idx: idx };
      });
    }
  });

  // Acumular despachado por item del pickup
  var despPorIdx: any = {};
  var detsExtra: any[] = [];

  dets.forEach(function (d: any) {
    var cb = String(d.codigoProducto || '').trim().toUpperCase();
    var hit = codToItem[cb];
    if (hit) {
      despPorIdx[hit.idx] = (despPorIdx[hit.idx] || 0) + (parseFloat(d.cantidad) || 0);
      d._pickupIdx = hit.idx;
    } else {
      detsExtra.push(d);
    }
  });

  // Clasificar cada detalle individual de la guía.
  dets.forEach(function (d: any) {
    if (typeof d._pickupIdx === 'undefined') return; // ya está en detsExtra
    var it = pickupItems[d._pickupIdx];
    if (it && it.nombre) d.descripcion = String(it.nombre);
    var sol = parseFloat(it.solicitado) || 0;
    var desp = parseFloat(despPorIdx[d._pickupIdx]) || 0;
    if (desp > sol + 1e-9) {
      out.extras.push(d);
    } else {
      out.ok.push(d);
    }
  });

  // Los detalles cuyo código no estaba en el pickup → "extras"
  detsExtra.forEach(function (d: any) { out.extras.push(d); });

  // Items del pickup que NO se despacharon o parcial → "faltantes"
  pickupItems.forEach(function (it: any, idx: number) {
    var sol = parseFloat(it.solicitado) || 0;
    var desp = parseFloat(despPorIdx[idx]) || 0;
    if (sol > 0 && desp + 1e-9 < sol) {
      out.faltantes.push({
        skuBase: it.skuBase || '',
        nombre: it.nombre || it.skuBase || '(sin nombre)',
        solicitado: sol,
        despachado: desp,
      });
    }
  });

  return out;
}

// ── Encode array de bytes (0-255) → base64 de los BYTES CRUDOS ───────────────
// Equivalente a Utilities.base64Encode(blob.getBytes()) del GAS. String.fromCharCode
// con miles de args puede reventar → construimos el string byte a byte.
function bytesToB64(B: number[]): string {
  var s = '';
  for (var i = 0; i < B.length; i++) s += String.fromCharCode(B[i] & 0xff);
  return btoa(s);
}

// ── Mes corto para fechas (TZ Perú) ──────────────────────────────────────────
const _MESES_CORTO = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
function _fmtFechaPeru(d: Date): string {
  // 'dd MMM yyyy' en America/Lima — espeja Utilities.formatDate del GAS.
  const fmt = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'America/Lima', day: '2-digit', month: 'short', year: 'numeric',
  });
  const parts = fmt.formatToParts(d);
  const get = (t: string) => (parts.find((p) => p.type === t)?.value || '');
  return `${get('day')} ${get('month')} ${get('year')}`;
}
function _fmtHoraPeru(d: Date): string {
  const fmt = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'America/Lima', hour: '2-digit', minute: '2-digit', hour12: false,
  });
  return fmt.format(d); // 'HH:mm'
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);

  try {
    // ── AUTH ──────────────────────────────────────────────────────────────
    const APPS_OK = new Set(['warehouseMos', 'mosExpress']);
    const auth = req.headers.get('Authorization') || '';
    const token = auth.replace(/^Bearer\s+/i, '').trim();
    const claims = jwtClaims(token);
    if (!claims || !APPS_OK.has(String(claims.app))) {
      return json({ ok: false, error: 'no autorizado (claim app)' }, 401);
    }

    const body = await req.json().catch(() => ({}));
    const idGuia = String(body.idGuia || '');
    if (!idGuia) return json({ ok: false, error: 'idGuia requerido' }, 400);

    if (!SB_URL || !SB_KEY) {
      return json({ ok: false, error: 'SUPABASE_URL / SERVICE_ROLE_KEY no configurados' }, 500);
    }

    // ── LECTURA 100% Supabase ──────────────────────────────────────────────
    // wh.guias → 1 fila
    const grows = await sbSelect('wh', 'guias', 'id_guia=eq.' + encodeURIComponent(idGuia) + '&limit=1');
    if (!grows || !grows.length) return json({ ok: false, error: 'Guía no encontrada' }, 404);
    const r = grows[0];

    // snake_case (Postgres) → camelCase (mismo shape que _cargarGuiaDesdeSupabase_ / _sheetToObjects)
    const g: any = {
      idGuia: String(r.id_guia || ''),
      tipo: String(r.tipo || ''),
      estado: String(r.estado || ''),
      fecha: r.fecha || '',
      usuario: String(r.usuario || ''),
      comentario: String(r.comentario || ''),
      idProveedor: String(r.id_proveedor || ''),
      idZona: String(r.id_zona || ''),
      numeroDocumento: String(r.numero_documento || ''),
      idPreingreso: String(r.id_preingreso || ''),
      montoTotal: r.monto_total,
      foto: String(r.foto || ''),
    };

    // wh.guia_detalle → array, filtrando observacion='ANULADO', ordenado por linea.
    const drows = await sbSelect('wh', 'guia_detalle', 'id_guia=eq.' + encodeURIComponent(idGuia) + '&order=linea');
    const detRows = (drows || []).filter((d: any) => String(d.observacion || '') !== 'ANULADO');

    // ── RESOLUCIÓN DE DESCRIPCIÓN POR CATÁLOGO ────────────────────────────────
    // Replica EXACTAMENTE la prioridad de gas/Reporte.gs::imprimirTicketGuia (líneas
    // 317-387). El GAS arma 3 mapas leyendo PRODUCTOS + EQUIVALENCIAS + PRODUCTO_NUEVO
    // del Sheet; acá leemos las MISMAS fuentes vía PostgREST (mos.productos, mos.equivalencias)
    // y wh.producto_nuevo, y construimos los mapas con la misma lógica.
    //
    // PRIORIDAD GAS por código `cod` (= cod_producto del detalle):
    //   esPN       = !!pnMap[cod] || cod.startsWith('NLEV')
    //   enCatalogo = !!prodMap[cod]
    //   desc       = esPN ? (pnMap[cod]?.desc ?? cod) : (enCatalogo ? prodMap[cod] : cod)
    //   esIncompleto = !esPN && !enCatalogo
    // donde prodMap se llena por idProducto, codigoBarra y skuBase (todos → desc del
    // CANÓNICO de su skuBase), y luego EQUIVALENCIAS sobreescribe prodMap[codigoBarra].
    const prodMap: Record<string, string> = {};
    const pnMap: Record<string, { desc: string; estado: string }> = {};
    try {
      // Códigos del detalle (los que hay que resolver). encodeURIComponent escapa comas/paréntesis.
      const codes = Array.from(new Set(
        detRows.map((d: any) => String(d.cod_producto || '').trim()).filter((c: string) => c),
      ));
      const inList = (vals: string[]) => '(' + vals.map((v) => '"' + String(v).replace(/"/g, '\\"') + '"').join(',') + ')';

      // (a) mos.productos por codigo_barra IN (codes) — trae sku_base, descripcion, factor, estado.
      //     De aquí derivamos prodMap[codigoBarra] y prodMap[idProducto/codigo_barra] al canónico.
      // (b) mos.productos por sku_base IN (skus) con factor=1 & estado=true → desc CANÓNICA por skuBase.
      // (c) mos.equivalencias por codigo_barra IN (codes) → sobreescribe prodMap[codigoBarra] al canónico.
      let prodsByCode: any[] = [];
      let equivs: any[] = [];
      if (codes.length) {
        prodsByCode = await sbSelect(
          'mos', 'productos',
          'codigo_barra=in.' + encodeURIComponent(inList(codes)) +
          '&select=id_producto,codigo_barra,sku_base,descripcion,factor_conversion,estado',
        );
        equivs = await sbSelect(
          'mos', 'equivalencias',
          'codigo_barra=in.' + encodeURIComponent(inList(codes)) +
          '&select=codigo_barra,sku_base,descripcion',
        );
      }

      // Conjunto de skuBase relevantes: los de los productos hallados + los de las equivalencias,
      // para pedir el nombre CANÓNICO (factor=1, activo) en batch.
      const skus = new Set<string>();
      prodsByCode.forEach((p: any) => { if (p.sku_base) skus.add(String(p.sku_base).trim().toUpperCase()); });
      equivs.forEach((e: any) => { if (e.sku_base) skus.add(String(e.sku_base).trim().toUpperCase()); });

      // PASO 1 GAS — canonicoPorSku: skuBase(upper) → desc del canónico (factor=1, estado activo).
      const canonicoPorSku: Record<string, string> = {};
      if (skus.size) {
        const skuArr = Array.from(skus);
        const canon = await sbSelect(
          'mos', 'productos',
          'sku_base=in.' + encodeURIComponent(inList(skuArr)) +
          '&factor_conversion=eq.1&estado=is.true&select=sku_base,descripcion,id_producto',
        );
        canon.forEach((p: any) => {
          const sk = String(p.sku_base || '').trim().toUpperCase();
          if (!sk) return;
          // GAS: descripcion || idProducto || sk
          canonicoPorSku[sk] = String(p.descripcion || p.id_producto || sk);
        });
      }

      // PASO 2 GAS — prodMap por codigo_barra (y skuBase) apuntando al canónico de su skuBase.
      // (El GAS también indexa por idProducto; acá los detalles usan codigo_barra, así que
      //  basta indexar por codigo_barra y skuBase — que es lo que un cod_producto puede ser.)
      prodsByCode.forEach((p: any) => {
        const sk = String(p.sku_base || '').trim().toUpperCase();
        // GAS PASO 2: canonicoPorSku[sk] || p.descripcion || p.idProducto
        const desc = canonicoPorSku[sk] || String(p.descripcion || '') || String(p.id_producto || '');
        if (!desc) return;
        if (p.id_producto) prodMap[String(p.id_producto).trim()] = desc;
        if (p.codigo_barra) prodMap[String(p.codigo_barra).trim()] = desc;
        if (sk) prodMap[sk] = desc;
      });

      // PASO 3 GAS — equivalencias: SIEMPRE al canónico de su skuBase; sobreescribe lo anterior.
      equivs.forEach((e: any) => {
        if (!e.codigo_barra) return;
        const sk = String(e.sku_base || '').trim().toUpperCase();
        // GAS PASO 3: canonicoPorSku[sk] || prodMap[sk] || e.descripcion || e.codigoBarra
        const desc = canonicoPorSku[sk] || prodMap[sk] || String(e.descripcion || '') || String(e.codigo_barra);
        prodMap[String(e.codigo_barra).trim()] = desc;
      });

      // PASO 4 GAS — producto nuevo (wh.producto_nuevo): codigo_barra → { desc, estado }.
      if (codes.length) {
        try {
          const pns = await sbSelect(
            'wh', 'producto_nuevo',
            'codigo_barra=in.' + encodeURIComponent(inList(codes)) +
            '&select=codigo_barra,descripcion,marca,estado',
          );
          pns.forEach((pn: any) => {
            const cod = String(pn.codigo_barra || '');
            if (cod) pnMap[cod] = { desc: String(pn.descripcion || pn.marca || cod), estado: String(pn.estado || '') };
          });
        } catch (_) { /* producto_nuevo opcional: si falla, esPN cae a startsWith('NLEV') */ }
      }
    } catch (_) { /* sin catálogo → fallback cod (igual que el GAS cuando prodMap falla) */ }

    // Builder dets — prioridad IDÉNTICA a imprimirTicketGuia (líneas 369-386).
    const dets = detRows.map((d: any) => {
      const cod = String(d.cod_producto || '');
      const enCatalogo = !!prodMap[cod];
      // [fix arroz/565656] El CATÁLOGO manda sobre producto_nuevo: si el código ya está en mos.productos
      // NO es "nuevo", aunque quede una fila vieja PENDIENTE en wh.producto_nuevo. Antes el PN ganaba → un
      // producto ya catalogado (565656 = AJI PANCA) salía como "[n] arroz" (su fila PN vieja sin limpiar).
      const esPN = !enCatalogo && (!!pnMap[cod] || cod.indexOf('NLEV') === 0);
      const desc = esPN ? (pnMap[cod] ? pnMap[cod].desc : cod)
        : enCatalogo ? prodMap[cod] : cod;
      return {
        codigoProducto: cod,
        descripcion: desc, // pickup/sombra sobrescriben con it.nombre cuando aplica
        cantidad: parseFloat(d.cant_recibida ?? d.cant_esperada ?? 0) || 0,
        fechaVencimiento: String(d.fecha_vencimiento || '').split('T')[0],
        esProductoNuevo: esPN,
        esIncompleto: !esPN && !enCatalogo,
        estadoPN: esPN && pnMap[cod] ? pnMap[cod].estado : '',
      };
    });

    // Proveedor (mos.proveedores) → nombre (no usado en el layout base, se carga por paridad)
    let provName = '';
    try {
      if (g.idProveedor) {
        const prows = await sbSelect('mos', 'proveedores', 'id_proveedor=eq.' + encodeURIComponent(g.idProveedor) + '&select=nombre&limit=1');
        if (prows && prows.length) provName = String(prows[0].nombre || '');
      }
    } catch (_) { /* noop */ }
    void provName;

    const TIPO_LABELS: Record<string, string> = {
      INGRESO_PROVEEDOR: 'Ingreso Proveedor', INGRESO_JEFATURA: 'Ingreso Jefatura',
      SALIDA_ZONA: 'Salida Zona', SALIDA_DEVOLUCION: 'Devolucion',
      SALIDA_JEFATURA: 'Salida Jefatura', SALIDA_ENVASADO: 'Envasado', SALIDA_MERMA: 'Merma',
    };

    const fecha = _fmtFechaPeru(new Date(g.fecha || new Date()));
    const hora = _fmtHoraPeru(new Date());
    const tipoLabel = TIPO_LABELS[g.tipo] || String(g.tipo || '—');

    const reporteUrl = String(body.reporteUrl || '');

    // ════════════════════════════════════════════════════════════════════════
    // ── ESC/POS byte array — COPIA LITERAL de imprimirTicketGuia ─────────────
    // ════════════════════════════════════════════════════════════════════════
    let B: number[] = [];
    function b1(v: number) { B.push(v & 0xff); }
    function bStr(s: string) { for (var i = 0; i < s.length; i++) B.push(s.charCodeAt(i) & 0xff); }
    function bLn(s: string) { bStr(s); b1(0x0a); }

    // 48 chars: tag(2) + nombre(38) + cant(rest)
    function lineaDet(tag: string, nombre: any, cant: any): string {
      var pre = (tag && tag !== ' ' ? tag.substring(0, 1) : ' ') + ' ';
      var n = String(nombre).substring(0, 38);
      var c = String(cant);
      var pad = 48 - pre.length - n.length - c.length;
      if (pad < 1) pad = 1;
      return pre + n + Array(pad + 1).join(' ') + c;
    }
    // deno-lint-ignore no-unused-vars
    function lineaProd(nombre: any, cant: any): string { return lineaDet(' ', nombre, cant); }

    // Formato simple de fecha "YYYY-MM-DD" → "15 ago 2027"
    function fmtVenc(raw: any): any {
      if (!raw) return '';
      var parts = String(raw).split('-');
      if (parts.length !== 3) return raw;
      var meses = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
      var m = parseInt(parts[1], 10) - 1;
      return parts[2] + ' ' + (meses[m] || parts[1]) + ' ' + parts[0];
    }

    // Línea etiqueta: label fijo 10 chars + valor
    // deno-lint-ignore no-unused-vars
    function lineaKV(label: any, valor: any): string {
      var l = String(label);
      var v = String(valor).substring(0, 48 - l.length);
      return l + v;
    }

    var SEP = '================================================';
    var SEP2 = '------------------------------------------------';

    // Init
    b1(0x1b); b1(0x40);

    // ── HEADER: WAREHOUSE / MOS ─────────────────────────────────
    b1(0x1b); b1(0x61); b1(0x01);
    b1(0x1b); b1(0x21); b1(0x38);
    bLn('WAREHOUSE');
    bLn('MOS');
    b1(0x1b); b1(0x21); b1(0x00);
    b1(0x1b); b1(0x61); b1(0x00);

    bLn(SEP);

    // ── CUADRO 1: info compacta de la guía ──────────────────────
    var tipoCorto = tipoLabel.toUpperCase().replace(/^SALIDA\s+/, '').replace(/^INGRESO\s+/, '');

    // Línea 1: tipo (centrado + bold + doble-alto)
    b1(0x1b); b1(0x61); b1(0x01);  // center
    b1(0x1b); b1(0x21); b1(0x10);  // double-height
    b1(0x1b); b1(0x45); b1(0x01);  // bold
    bLn(tipoCorto);
    b1(0x1b); b1(0x45); b1(0x00);
    b1(0x1b); b1(0x21); b1(0x00);

    // Línea 2: fecha + hora juntos (centrado, bold)
    b1(0x1b); b1(0x45); b1(0x01);
    bLn(fecha.toUpperCase() + '  ' + hora);
    b1(0x1b); b1(0x45); b1(0x00);

    // Línea 3: estado (centrado)
    bLn((g.estado || '—').toUpperCase());

    b1(0x1b); b1(0x61); b1(0x00);  // left

    // Nota: si hay comentario, word-wrap inteligente
    if (g.comentario) {
      var notaLines = _wrapPalabras('Nota: ' + String(g.comentario), 48);
      notaLines.forEach(function (ln) { bLn(ln); });
    }

    bLn(SEP);

    // ── CUADRO 2: productos ─────────────────────────────────────
    // PARIDAD CON EL GAS ACTUAL: el GAS hoy NO clasifica los pickups de Supabase;
    // muestra la LISTA SIMPLE "PRODUCTOS" igual que para guías no-pickup. Por eso aquí
    // NO leemos wh.pickups y NO ejecutamos _clasificarDetallesPorPickup: forzamos la
    // ruta de lista única para que la salida quede byte-idéntica al GAS también en GPCK_.
    // (El lector de wh.pickups y el clasificador quedan como CÓDIGO MUERTO más abajo;
    //  NO se ejecutan. Reactivar SOLO cuando el GAS también clasifique pickups.)
    const pickupItems: any[] | null = null;
    void pickupItems;
    var pickupClasif: any = { hasPickup: false, ok: [], extras: [], faltantes: [] };

    // Helper para renderizar un detalle de la guía con cantidad bold + word-wrap
    function _imprimirItemDetalle(d: any) {
      var tag = d.esProductoNuevo ? 'n' : d.esIncompleto ? 'i' : ' ';
      var nombre = String(d.descripcion || '').toUpperCase();
      var cant = d.cantidad % 1 === 0 ? String(Math.round(d.cantidad)) : String(d.cantidad);
      var marca = (tag === 'n' ? '[N] ' : tag === 'i' ? '[!] ' : '');
      var prefix = cant + 'x ';
      var anchoP = 48 - prefix.length;
      var anchoR = 48 - 4;
      var lineas = _wrapPalabras(marca + nombre, anchoP, anchoR);
      b1(0x1b); b1(0x45); b1(0x01);
      bStr(prefix);
      b1(0x1b); b1(0x45); b1(0x00);
      bLn(lineas[0] || '');
      for (var li = 1; li < lineas.length; li++) bLn('    ' + lineas[li]);
      if (d.codigoProducto) bLn('    ' + String(d.codigoProducto));
      if (d.fechaVencimiento) bLn('    Venc: ' + fmtVenc(d.fechaVencimiento));
    }

    // Helper para items "faltantes" del pickup — ⚠️ CÓDIGO MUERTO (solo lo usaba la
    // rama de clasificación por pickup, ahora desactivada). Aquí vivía la "basura de
    // float" '(pidio ' + sol + ', llego ' + desp + ')'; al no ejecutarse, no se imprime.
    // deno-lint-ignore no-unused-vars
    function _imprimirItemFaltante(it: any) {
      var nombre = String(it.nombre || '').toUpperCase();
      var sol = parseFloat(it.solicitado) || 0;
      var desp = parseFloat(it.despachado) || 0;
      var falta = sol - desp;
      var qFalta = falta % 1 === 0 ? String(Math.round(falta)) : String(falta);
      var prefix = '-' + qFalta + ' ';
      var anchoP = 48 - prefix.length;
      var anchoR = 48 - 4;
      var lineas = _wrapPalabras(nombre, anchoP, anchoR);
      b1(0x1b); b1(0x45); b1(0x01);
      bStr(prefix);
      b1(0x1b); b1(0x45); b1(0x00);
      bLn(lineas[0] || '');
      for (var li = 1; li < lineas.length; li++) bLn('    ' + lineas[li]);
      bLn('    (pidio ' + sol + ', llego ' + desp + ')');
    }

    // [v2.13.28] CLASIFICACIÓN SOMBRA — si vino sombraSnapshot, comparamos.
    // DIFERENCIA OBLIGADA: el GAS resuelve cada det a su skuBase canónico vía catálogo
    // (PRODUCTOS + EQUIVALENCIAS del Sheet). El Edge no tiene catálogo → la resolución
    // por skuBase no es posible aquí. Mantenemos el bloque INERTE (devuelve null) salvo
    // que el caller mande la sombra YA resuelta. En la práctica WH llama sin sombraSnapshot
    // para tickets de guía (la sombra la imprime otra ruta), así que esto no se ejercita.
    function _clasificarPorSombra(): any { return null; }
    var sombraClasif = _clasificarPorSombra();

    // Helper para renderizar línea sombra
    // deno-lint-ignore no-unused-vars
    function _imprimirItemSombra(it: any, marca: string) {
      var nombre = String(it.nombre || '').toUpperCase();
      var ped = it.pedido % 1 === 0 ? String(Math.round(it.pedido)) : String(it.pedido);
      var desp = it.despachado % 1 === 0 ? String(Math.round(it.despachado)) : String(it.despachado);
      var cantTxt = ped + '/' + desp + ' ' + marca;
      var prefix = '  ';
      var ancho = 48 - prefix.length - cantTxt.length - 1;
      var nombreCorto = nombre.length > ancho ? nombre.substring(0, ancho) : nombre;
      var pad = 48 - prefix.length - nombreCorto.length - cantTxt.length;
      if (pad < 1) pad = 1;
      bLn(prefix + nombreCorto + Array(pad + 1).join(' ') + cantTxt);
    }

    if (sombraClasif) {
      // ─── Header especial para sombra ───
      b1(0x1b); b1(0x61); b1(0x01); b1(0x1b); b1(0x45); b1(0x01);
      bLn('DESPACHO POR LISTA SOMBRA');
      b1(0x1b); b1(0x45); b1(0x00); b1(0x1b); b1(0x61); b1(0x00);
      var totalItems = sombraClasif.items.length;
      var totalAtendidos = sombraClasif.ok.length + sombraClasif.parciales.length;
      bLn('Items lista: ' + totalItems + '  Atendidos: ' + totalAtendidos);
      bLn(SEP2);
      bLn('  PRODUCTO                    PED/DESP');
      bLn(SEP2);
      sombraClasif.ok.forEach(function (it: any) { _imprimirItemSombra(it, '[OK]'); });
      sombraClasif.parciales.forEach(function (it: any) { _imprimirItemSombra(it, '[!! ]'); });
      sombraClasif.sin.forEach(function (it: any) { _imprimirItemSombra(it, '[NO]'); });
      bLn(SEP);

      // Extras (fuera de la sombra)
      if (sombraClasif.extras.length) {
        b1(0x1b); b1(0x61); b1(0x01); b1(0x1b); b1(0x45); b1(0x01);
        bLn('EXTRAS (' + sombraClasif.extras.length + ') fuera de lista');
        b1(0x1b); b1(0x45); b1(0x00); b1(0x1b); b1(0x61); b1(0x00);
        bLn(SEP2);
        sombraClasif.extras.forEach(_imprimirItemDetalle);
        bLn(SEP);
      }

      // Totales finales
      var totalPedido = sombraClasif.items.reduce(function (s: number, it: any) { return s + (parseFloat(it.cantidad) || 0); }, 0);
      var totalDesp = sombraClasif.ok.reduce(function (s: number, it: any) { return s + it.despachado; }, 0)
        + sombraClasif.parciales.reduce(function (s: number, it: any) { return s + it.despachado; }, 0);
      var faltan = Math.max(0, totalPedido - totalDesp);
      b1(0x1b); b1(0x61); b1(0x01); b1(0x1b); b1(0x45); b1(0x01);
      bLn('PEDIDO ' + Math.round(totalPedido) + ' uds  ATENDIDO ' + Math.round(totalDesp) + ' uds');
      if (faltan > 0) {
        bLn('FALTAN ' + Math.round(faltan) + ' uds  (' + sombraClasif.sin.length + ' items sin)');
      } else {
        bLn('LISTA COMPLETA');
      }
      b1(0x1b); b1(0x45); b1(0x00); b1(0x1b); b1(0x61); b1(0x00);
      bLn(SEP);
    } else if (pickupClasif.hasPickup) {
      // ─── Sección 1: DESPACHADO OK ───
      b1(0x1b); b1(0x61); b1(0x01); b1(0x1b); b1(0x45); b1(0x01);
      bLn('DESPACHADO OK (' + pickupClasif.ok.length + ')');
      b1(0x1b); b1(0x45); b1(0x00); b1(0x1b); b1(0x61); b1(0x00);
      bLn(SEP2);
      if (pickupClasif.ok.length) {
        pickupClasif.ok.forEach(_imprimirItemDetalle);
      } else {
        bLn('  (ninguno coincidio exacto)');
      }
      bLn(SEP);

      // ─── Sección 2: EXTRAS / SOBRANTES ───
      b1(0x1b); b1(0x61); b1(0x01); b1(0x1b); b1(0x45); b1(0x01);
      bLn('EXTRAS / SOBRANTES (' + pickupClasif.extras.length + ')');
      b1(0x1b); b1(0x45); b1(0x00); b1(0x1b); b1(0x61); b1(0x00);
      if (pickupClasif.extras.length) {
        bLn('(producto pedido en mayor cant.');
        bLn(' o no estaba en el pickup)');
        bLn(SEP2);
        pickupClasif.extras.forEach(_imprimirItemDetalle);
      } else {
        bLn(SEP2);
        bLn('  (sin extras)');
      }
      bLn(SEP);

      // ─── Sección 3: FALTANTES ───
      b1(0x1b); b1(0x61); b1(0x01); b1(0x1b); b1(0x45); b1(0x01);
      bLn('NO DESPACHADO (' + pickupClasif.faltantes.length + ')');
      b1(0x1b); b1(0x45); b1(0x00); b1(0x1b); b1(0x61); b1(0x00);
      if (pickupClasif.faltantes.length) {
        bLn('(quedaron pendientes)');
        bLn(SEP2);
        pickupClasif.faltantes.forEach(_imprimirItemFaltante);
      } else {
        bLn(SEP2);
        bLn('  Sin faltantes - PICKUP COMPLETO');
      }
      bLn(SEP);
    } else {
      // Comportamiento clásico — lista única "PRODUCTOS"
      b1(0x1b); b1(0x61); b1(0x01); b1(0x1b); b1(0x45); b1(0x01);
      bLn('PRODUCTOS');
      b1(0x1b); b1(0x45); b1(0x00); b1(0x1b); b1(0x61); b1(0x00);
      bLn(SEP2);
      dets.forEach(_imprimirItemDetalle);
      if (!dets.length) bLn('  (sin items registrados)');
      bLn(SEP);
    }

    // ── CUADRO 3: QR Code para reporte en tiempo real ───────────
    function _imprimirQR(url: string, titulo: string, sub1?: string, sub2?: string) {
      b1(0x1b); b1(0x61); b1(0x01);  // centrar
      b1(0x1b); b1(0x45); b1(0x01);
      bLn(titulo);
      b1(0x1b); b1(0x45); b1(0x00);

      var qrLen = url.length + 3;
      var qrpL = qrLen & 0xff;
      var qrpH = (qrLen >> 8) & 0xff;

      b1(0x1d); b1(0x28); b1(0x6b); b1(0x04); b1(0x00); b1(0x31); b1(0x41); b1(0x32); b1(0x00);
      b1(0x1d); b1(0x28); b1(0x6b); b1(0x03); b1(0x00); b1(0x31); b1(0x43); b1(0x05);
      b1(0x1d); b1(0x28); b1(0x6b); b1(0x03); b1(0x00); b1(0x31); b1(0x45); b1(0x31);
      b1(0x1d); b1(0x28); b1(0x6b); b1(qrpL); b1(qrpH); b1(0x31); b1(0x50); b1(0x30);
      bStr(url);
      b1(0x1d); b1(0x28); b1(0x6b); b1(0x03); b1(0x00); b1(0x31); b1(0x51); b1(0x30);

      b1(0x1b); b1(0x21); b1(0x00);
      if (sub1) bLn(sub1);
      if (sub2) bLn(sub2);
      b1(0x1b); b1(0x61); b1(0x00);
      bLn(SEP);
    }

    if (reporteUrl) {
      _imprimirQR(reporteUrl, 'REPORTE EN TIEMPO REAL',
        'Escanea con la camara',
        'para ver el detalle al instante');
    }

    // ── BLOQUE PREINGRESO ─────────────────────────────────────────────
    // DIFERENCIA OBLIGADA: el GAS lee la hoja PREINGRESOS por su API. El Edge no lo
    // porta (el ticket de preingreso tiene su propia ruta). Mantenemos el patrón de
    // buffer Bpre (vacío) para que el ensamblado final quede idéntico cuando no hay
    // preingreso — que es el caso para guías directas G_L… vía este Edge.
    var Bpre: number[] = [];
    var _Bmain = B;
    B = Bpre;
    // (bloque preingreso NO portado — ver nota arriba)
    // Restaurar el buffer principal (la guía) y anteponer el preingreso si hubo.
    B = _Bmain;
    if (Bpre.length) {
      B = Bpre.concat([0x1b, 0x4a, 60]).concat(_Bmain);
    }

    // Feed + corte
    b1(0x1b); b1(0x4a); b1(160);
    b1(0x1d); b1(0x56); b1(0x00);

    // Encode (base64 de los BYTES CRUDOS — equiv a Utilities.base64Encode(blob.getBytes()))
    const b64 = bytesToB64(B);

    // ── printerId ──────────────────────────────────────────────────────────
    // override > mos.config WH_TICKET_PRINTER_ID (NUNCA por nombre de impresora).
    let printerId: number;
    if (body.printerIdOverride) {
      printerId = parseInt(String(body.printerIdOverride), 10);
    } else {
      try {
        const cfg = await sbSelect('mos', 'config', 'clave=eq.WH_TICKET_PRINTER_ID&select=valor&limit=1');
        printerId = parseInt(String(cfg && cfg.length ? cfg[0].valor : ''), 10);
      } catch (e) {
        return json({ ok: false, error: 'No se pudo leer WH_TICKET_PRINTER_ID: ' + String((e as Error)?.message || e) }, 500);
      }
    }
    if (!printerId || printerId <= 0) {
      return json({ ok: false, error: 'printerId inválido' }, 400);
    }

    const detallesImpresos = dets.length;

    // ── soloBase64: diff-test, NO manda a PrintNode ──────────────────────────
    if (body.soloBase64 === true) {
      return json({ ok: true, base64: b64, printerId, detallesImpresos, idGuia });
    }

    // ── Envío a PrintNode (igual que imprimir/index.ts) ──────────────────────
    const key = Deno.env.get('PRINTNODE_API_KEY');
    if (!key) return json({ ok: false, error: 'PRINTNODE_API_KEY no configurada (secret)' }, 500);

    const pn = await fetch('https://api.printnode.com/printjobs', {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + btoa(key + ':'),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        printerId,
        title: 'Ticket ' + idGuia,
        contentType: 'raw_base64',
        content: b64,
        source: 'warehouseMos-Edge',
      }),
    });
    const text = await pn.text();
    if (pn.status !== 201) {
      return json({ ok: false, error: 'PrintNode ' + pn.status + ': ' + text }, 502);
    }
    return json({ ok: true, jobId: text, detallesImpresos });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
