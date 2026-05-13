// ============================================================
// ProyectoMOS — Etiquetas.gs
// Cola persistente de membretes (etiquetas) por zona cuando se
// cambia un precio en el catálogo.
//
// Flujo:
//   1. Admin cambia precio → publicarPrecio() llama _etiqGenerarParaZonas()
//   2. Se crea 1 fila PENDIENTE por cada zona ACTIVA NO-ALMACÉN
//   3. Cajero abre caja → ME llama imprimirBatchEtiquetasZona() → estado IMPRESA
//   4. Cajero/vendedor click en badge → marcarVistoEtiqueta() actualiza visto_csv
//   5. Cajero/vendedor click "Pegada" → marcarPegadaEtiqueta() cierra como PEGADA
//   6. Cron 1h: si pendiente >2h sin todos vistos → push (cajeros+vend); >4h sin
//      pegar → push (admin/master)
// ============================================================

var _ETIQ_SHEET = 'ETIQUETAS_ZONA';
var _ETIQ_HDRS  = [
  'idEtiq', 'idZona', 'zonaNombre', 'idProducto', 'descripcion',
  'codigoBarra', 'skuBase', 'precioAnterior', 'precioNuevo',
  'ts_cambio', 'cambiadoPor', 'estado',
  'visto_csv', 'ts_impresa', 'impresaPor', 'jobId',
  'ts_pegada', 'pegadaPor', 'comentario'
];

// ── Helpers ────────────────────────────────────────────────
function _etiqGetSheet() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName(_ETIQ_SHEET);
  if (sh) return sh;
  sh = ss.insertSheet(_ETIQ_SHEET);
  sh.getRange(1, 1, 1, _ETIQ_HDRS.length).setValues([_ETIQ_HDRS]);
  sh.getRange(1, 1, 1, _ETIQ_HDRS.length)
    .setBackground('#0891b2').setFontColor('#fff').setFontWeight('bold').setFontSize(10);
  sh.setFrozenRows(1);
  // Texto en columnas críticas
  try {
    sh.getRange(2, 1, 5000, 1).setNumberFormat('@'); // idEtiq
    sh.getRange(2, 6, 5000, 1).setNumberFormat('@'); // codigoBarra
    sh.getRange(2, 7, 5000, 1).setNumberFormat('@'); // skuBase
  } catch(_){}
  return sh;
}

// Detecta zonas tipo almacén (excluidas del flujo de etiquetas)
function _etiqEsZonaAlmacen(zona) {
  if (!zona) return false;
  var id  = String(zona.idZona || '').toUpperCase();
  var nom = String(zona.nombre || '').toUpperCase()
              .normalize('NFD').replace(/[̀-ͯ]/g,'');
  return id.indexOf('ALMACEN') >= 0 || nom.indexOf('ALMACEN') >= 0
      || id === 'ALM' || nom.indexOf('ALMACÉN') >= 0;
}

function _etiqHoy() {
  return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
}

function _etiqNowIso() {
  return Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
}

// ── HOOK: crear filas al cambiar precio ────────────────────
// Llamado desde publicarPrecio (Productos.gs)
// REGLA: solo canónicos (factor=1) generan etiquetas. Las presentaciones
// y derivados NO generan etiquetas porque el cliente ve el precio del
// producto base en el estante, no el del paquete/display.
function _etiqGenerarParaZonas(params) {
  // params: { idProducto, codigoBarra, skuBase, descripcion,
  //          precioAnterior, precioNuevo, usuario }

  // ── FILTRO: solo canónicos ──
  // Un producto es canónico si su factorConversion === 1 (o si no tiene
  // factor, asumimos canónico). Leemos PRODUCTOS_MASTER para confirmar.
  try {
    var prodSheet = getSheet('PRODUCTOS_MASTER');
    var prodRows = _sheetToObjects(prodSheet);
    var prod = null;
    if (params.idProducto) {
      prod = prodRows.find(function(p){ return String(p.idProducto) === String(params.idProducto); });
    }
    if (!prod && params.codigoBarra) {
      prod = prodRows.find(function(p){ return String(p.codigoBarra) === String(params.codigoBarra); });
    }
    if (prod) {
      var factor = parseFloat(prod.factorConversion);
      if (isNaN(factor)) factor = 1;
      if (factor !== 1) {
        // Es presentación o derivado → no se generan etiquetas
        return { ok: true, data: { creadas: 0, msg: 'No-canónico (factor=' + factor + '): no genera etiquetas' } };
      }
    }
    // Si no encontramos el producto, dejamos pasar (asumir canónico por nombre)
  } catch(ePc) { Logger.log('[Etiq] Validación canónico fallo: ' + ePc.message); }

  var sh = _etiqGetSheet();
  var zonas;
  try {
    zonas = _sheetToObjects(getSheet('ZONAS'))
      .filter(function(z){
        var act = String(z.estado || '').trim();
        return (act === '1' || act === 'true' || act === '') && !_etiqEsZonaAlmacen(z);
      });
  } catch(e) { Logger.log('[Etiq] No se pudo leer ZONAS: ' + e.message); return { ok: false, error: e.message }; }

  if (!zonas.length) return { ok: true, data: { creadas: 0, msg: 'Sin zonas activas (no-almacén)' } };

  var nowIso = _etiqNowIso();
  var creadas = 0, actualizadas = 0;

  // Para cada zona, hacer UPSERT por (idProducto, idZona) en estado != PEGADA/OBSOLETA
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iIdProd = hdrs.indexOf('idProducto');
  var iIdZona = hdrs.indexOf('idZona');
  var iEstado = hdrs.indexOf('estado');

  zonas.forEach(function(z) {
    var idEtiq = 'ETQ-' + new Date().getTime() + '-' + String(z.idZona).substring(0,6);
    // Buscar fila existente para misma zona y mismo producto que NO esté cerrada
    var existIdx = -1;
    for (var i = 1; i < data.length; i++) {
      var est = String(data[i][iEstado] || '').toUpperCase();
      if (est === 'PEGADA' || est === 'OBSOLETA') continue;
      if (String(data[i][iIdProd]) === String(params.idProducto) &&
          String(data[i][iIdZona]) === String(z.idZona)) {
        existIdx = i;
        break;
      }
    }

    if (existIdx >= 0) {
      // Actualizar precioNuevo y resetear estado (precio cambió antes de pegar)
      var iPrecioNuevo = hdrs.indexOf('precioNuevo');
      var iTsCambio   = hdrs.indexOf('ts_cambio');
      var iCambPor    = hdrs.indexOf('cambiadoPor');
      var iVisto      = hdrs.indexOf('visto_csv');
      sh.getRange(existIdx + 1, iPrecioNuevo + 1).setValue(parseFloat(params.precioNuevo) || 0);
      sh.getRange(existIdx + 1, iTsCambio    + 1).setValue(nowIso);
      sh.getRange(existIdx + 1, iCambPor     + 1).setValue(String(params.usuario || ''));
      sh.getRange(existIdx + 1, iEstado      + 1).setValue('PENDIENTE');
      sh.getRange(existIdx + 1, iVisto       + 1).setValue(''); // reset vistos
      actualizadas++;
    } else {
      // Crear nueva fila
      var nuevaFila = {
        idEtiq:         idEtiq,
        idZona:         String(z.idZona),
        zonaNombre:     String(z.nombre || z.idZona),
        idProducto:     String(params.idProducto || ''),
        descripcion:    String(params.descripcion || ''),
        codigoBarra:    String(params.codigoBarra || ''),
        skuBase:        String(params.skuBase || ''),
        precioAnterior: parseFloat(params.precioAnterior) || 0,
        precioNuevo:    parseFloat(params.precioNuevo) || 0,
        ts_cambio:      nowIso,
        cambiadoPor:    String(params.usuario || ''),
        estado:         'PENDIENTE',
        visto_csv:      '',
        ts_impresa:     '',
        impresaPor:     '',
        jobId:          '',
        ts_pegada:      '',
        pegadaPor:      '',
        comentario:     ''
      };
      var rowArr = hdrs.map(function(h) {
        return nuevaFila[h] !== undefined ? nuevaFila[h] : '';
      });
      sh.appendRow(rowArr);
      creadas++;
    }
  });

  // Push opcional a cajeros conectados de cada zona (auto-print remoto)
  try {
    if (typeof _enviarPushTodos === 'function') {
      _enviarPushTodos(
        '🏷 Nueva etiqueta de precio',
        (params.descripcion || 'Producto') + ' · S/' + parseFloat(params.precioNuevo).toFixed(2),
        {
          rolesPermitidos: ['CAJERO', 'VENDEDOR'],
          idNotif: 'MOS_ETIQUETA_NUEVA',
          excluirUsuario: params.usuario || ''
        }
      );
    }
  } catch(_){}

  return { ok: true, data: { creadas: creadas, actualizadas: actualizadas, zonas: zonas.length } };
}

// ── API: GET pendientes por zona ────────────────────────────
// params: { idZona, usuario } — usuario para flag "visto_por_mi"
// Ventana de visibilidad: 3 días desde ts_cambio. Después se ocultan.
function getEtiquetasPendientes(params) {
  params = params || {};
  var sh = _etiqGetSheet();
  var rows = _sheetToObjects(sh);
  var usuarioN = String(params.usuario || '').toLowerCase().trim();
  var hoy = new Date().getTime();
  var TRES_DIAS_MS = 3 * 24 * 60 * 60 * 1000;

  var filtradas = rows.filter(function(r) {
    var est = String(r.estado || '').toUpperCase();
    if (est === 'PEGADA' || est === 'OBSOLETA') return false;
    if (params.idZona && String(r.idZona) !== String(params.idZona)) return false;
    // Ventana de 3 días: ocultar las más viejas
    var ts; try { ts = new Date(r.ts_cambio).getTime(); } catch(_){ ts = 0; }
    if (ts && (hoy - ts) > TRES_DIAS_MS) return false;
    return true;
  });

  // Calcular antigüedad y flag "visto_por_mi"
  filtradas.forEach(function(r) {
    var ts = 0;
    try { ts = new Date(r.ts_cambio).getTime(); } catch(_){}
    r._minutosDesdeCambio = ts ? Math.round((hoy - ts) / 60000) : 0;
    var vistoList = String(r.visto_csv || '').toLowerCase().split(',').map(function(s){ return s.trim(); }).filter(Boolean);
    r._vistoPorMi = usuarioN ? vistoList.indexOf(usuarioN) >= 0 : false;
    r._cantidadVistos = vistoList.length;
  });

  // Orden: más antiguas primero (más urgentes)
  filtradas.sort(function(a,b){ return b._minutosDesdeCambio - a._minutosDesdeCambio; });

  return { ok: true, data: filtradas };
}

// ── API: marcar visto (lectura individual) ─────────────────
function marcarVistoEtiqueta(params) {
  if (!params || !params.idEtiq) return { ok: false, error: 'Requiere idEtiq' };
  if (!params.usuario)           return { ok: false, error: 'Requiere usuario' };
  var sh = _etiqGetSheet();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iIdEtiq = hdrs.indexOf('idEtiq');
  var iVisto  = hdrs.indexOf('visto_csv');
  var usuarioN = String(params.usuario).toLowerCase().trim();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iIdEtiq]) !== String(params.idEtiq)) continue;
    var actual = String(data[i][iVisto] || '').toLowerCase();
    var list = actual ? actual.split(',').map(function(s){ return s.trim(); }).filter(Boolean) : [];
    if (list.indexOf(usuarioN) < 0) {
      list.push(usuarioN);
      sh.getRange(i + 1, iVisto + 1).setValue(list.join(','));
    }
    return { ok: true, data: { idEtiq: params.idEtiq, vistoPor: list } };
  }
  return { ok: false, error: 'idEtiq no encontrado' };
}

// ── API: marcar pegada (cierre) ────────────────────────────
function marcarPegadaEtiqueta(params) {
  if (!params || !params.idEtiq) return { ok: false, error: 'Requiere idEtiq' };
  var sh = _etiqGetSheet();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iIdEtiq = hdrs.indexOf('idEtiq');
  var iEstado = hdrs.indexOf('estado');
  var iTsPeg  = hdrs.indexOf('ts_pegada');
  var iPegPor = hdrs.indexOf('pegadaPor');
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iIdEtiq]) !== String(params.idEtiq)) continue;
    sh.getRange(i + 1, iEstado + 1).setValue('PEGADA');
    sh.getRange(i + 1, iTsPeg  + 1).setValue(_etiqNowIso());
    sh.getRange(i + 1, iPegPor + 1).setValue(String(params.usuario || ''));
    return { ok: true, data: { idEtiq: params.idEtiq, pegada: true } };
  }
  return { ok: false, error: 'idEtiq no encontrado' };
}

// Marcar varias como pegadas a la vez (botón "todas pegadas")
function marcarPegadasBatch(params) {
  if (!params || !Array.isArray(params.idEtiqs) || !params.idEtiqs.length) {
    return { ok: false, error: 'Requiere idEtiqs[]' };
  }
  var n = 0;
  params.idEtiqs.forEach(function(id) {
    var r = marcarPegadaEtiqueta({ idEtiq: id, usuario: params.usuario || '' });
    if (r && r.ok) n++;
  });
  return { ok: true, data: { pegadas: n, total: params.idEtiqs.length } };
}

// ── Resolver código a imprimir (misma lógica que ME imprimirMembrete) ──
// Si hay equivalencias activas asociadas al skuBase → imprimir SKU_Base
// (porque hay múltiples códigos válidos para el mismo producto).
// Si no hay equivalencias y hay un único codigoBarra → imprimir ese.
// Retorna { codigo, cantEquiv }
function _etiqResolverCodigo(skuBase, codigoBarra) {
  var sku = String(skuBase || '').trim();
  var cb  = String(codigoBarra || '').trim();
  // Buscar equivalencias activas para este sku
  var cantEquiv = 0;
  try {
    var eqRows = _sheetToObjects(getSheet('EQUIVALENCIAS'));
    eqRows.forEach(function(e) {
      var ac = e.activo;
      var activo = (ac === undefined || ac === '' || ac === 1 || ac === '1'
                 || ac === true || String(ac).toLowerCase() === 'true');
      if (!activo) return;
      if (String(e.skuBase || '').trim() === sku) cantEquiv++;
    });
  } catch(_){}
  // Si tiene equivalencias activas → imprimir SKU_Base
  if (cantEquiv > 0 && sku) {
    return { codigo: sku, cantEquiv: cantEquiv, usoSku: true };
  }
  // Si no, usar codigoBarra; fallback al skuBase si codigoBarra está vacío
  return { codigo: cb || sku, cantEquiv: 0, usoSku: !cb };
}

// ── ESC/POS membrete (idéntico al imprimirMembrete de ME) ──
// Formato 80mm × ~30mm: nombre bold doble alto + barcode Code128 + precio doble alto+ancho
// + indicador "+N equiv." si el producto tiene equivalencias asignadas
function _etiqGenerarESCPOS(producto) {
  // producto: { descripcion, skuBase, codigoBarra, precio }
  var MAX_N = 24;
  var desc = String(producto.descripcion || '').toUpperCase();
  var n1 = desc.substring(0, MAX_N);
  var n2 = desc.length > MAX_N ? desc.substring(MAX_N, MAX_N * 2) : '';

  // Decidir qué imprimir como código de barras
  var resolv = _etiqResolverCodigo(producto.skuBase, producto.codigoBarra);
  var codigo = resolv.codigo;
  var precio = parseFloat(producto.precio) || 0;
  var bLen = String.fromCharCode(codigo.length);

  // Línea inferior con +N equiv. si aplica (texto pequeño, no estorba)
  var lineaEquiv = resolv.cantEquiv > 0
    ? '+' + resolv.cantEquiv + ' equiv.\n'
    : '';

  var raw = '\x1b\x40'        // init
          + '\x1b\x33\x10'    // interlineado 16
          + '\x1b\x61\x01'    // center
          + '\x1b\x45\x01'    // bold ON
          + '\x1b\x21\x10'    // alto doble
          + n1 + '\n'
          + (n2 ? n2 + '\n' : '')
          + '\x1b\x21\x00'    // size reset
          + '\x1b\x45\x00'    // bold OFF
          + '\x1d\x68\x30'    // barcode height 48 dots
          + '\x1d\x77\x02'    // barcode width factor 2
          + '\x1d\x48\x02'    // HRI debajo
          + '\x1d\x66\x00'    // HRI font A
          + '\x1d\x6b\x49'    // GS k 73 = Code128
          + bLen + codigo + '\n'
          + '\x1b\x21\x30'    // alto+ancho doble
          + '\x1b\x45\x01'    // bold
          + 'S/ ' + precio.toFixed(2) + '\n'
          + '\x1b\x21\x00'
          + '\x1b\x45\x00'
          + lineaEquiv        // +N equiv. (pequeño, solo si hay)
          + '\x07'            // beep
          + '\x1d\x56\x42\x00'; // corte parcial
  return raw;
}

// Convertir string ESC/POS a base64 (compatibilidad con _printNodeRaw)
function _etiqToBase64(escposStr) {
  var bytes = [];
  for (var i = 0; i < escposStr.length; i++) {
    bytes.push(escposStr.charCodeAt(i) & 0xFF);
  }
  return Utilities.base64Encode(bytes);
}

// ── Imprimir batch de pendientes para 1 zona ──────────────
// params: { idZona, printerId, usuario }
function imprimirBatchEtiquetasZona(params) {
  if (!params || !params.idZona)   return { ok: false, error: 'Requiere idZona' };
  if (!params.printerId)            return { ok: false, error: 'Requiere printerId' };

  var pend = getEtiquetasPendientes({ idZona: params.idZona });
  if (!pend.ok) return pend;
  // Solo las que NO estén ya IMPRESA esperando pegar (para no duplicar tags físicos)
  var aImprimir = pend.data.filter(function(r){ return String(r.estado).toUpperCase() === 'PENDIENTE'; });
  if (!aImprimir.length) return { ok: true, data: { impresas: 0, msg: 'Sin etiquetas PENDIENTE para esta zona' } };

  var pnKey;
  try { pnKey = PropertiesService.getScriptProperties().getProperty('PRINTNODE_API_KEY'); } catch(_){}
  if (!pnKey) return { ok: false, error: 'PRINTNODE_API_KEY no configurado' };

  var nowIso = _etiqNowIso();
  var impresas = 0;
  var errores = [];

  aImprimir.forEach(function(r) {
    try {
      var escpos = _etiqGenerarESCPOS({
        descripcion: r.descripcion || r.skuBase || '',
        skuBase:     r.skuBase || '',
        codigoBarra: r.codigoBarra || '',
        precio:      r.precioNuevo
      });
      var content = _etiqToBase64(escpos);
      var resp = UrlFetchApp.fetch('https://api.printnode.com/printjobs', {
        method:      'post',
        headers:     { 'Authorization': 'Basic ' + Utilities.base64Encode(pnKey + ':') },
        contentType: 'application/json',
        payload:     JSON.stringify({
          printerId:   parseInt(String(params.printerId), 10),
          title:       'Etiqueta ' + (r.descripcion || r.skuBase),
          contentType: 'raw_base64',
          content:     content,
          source:      'ProyectoMOS · Etiqueta'
        }),
        muteHttpExceptions: true
      });
      if (resp.getResponseCode() !== 201) {
        errores.push({ idEtiq: r.idEtiq, error: 'HTTP ' + resp.getResponseCode() });
        return;
      }
      var jobId = resp.getContentText();
      // Marcar como IMPRESA
      _etiqMarcarImpresa(r.idEtiq, params.usuario || 'cajero', jobId);
      impresas++;
    } catch(e) {
      errores.push({ idEtiq: r.idEtiq, error: e.message });
    }
  });

  return { ok: true, data: { impresas: impresas, errores: errores } };
}

function _etiqMarcarImpresa(idEtiq, usuario, jobId) {
  var sh = _etiqGetSheet();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iIdEtiq = hdrs.indexOf('idEtiq');
  var iEstado = hdrs.indexOf('estado');
  var iTsImp  = hdrs.indexOf('ts_impresa');
  var iImpPor = hdrs.indexOf('impresaPor');
  var iJobId  = hdrs.indexOf('jobId');
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iIdEtiq]) !== String(idEtiq)) continue;
    sh.getRange(i + 1, iEstado + 1).setValue('IMPRESA');
    sh.getRange(i + 1, iTsImp  + 1).setValue(_etiqNowIso());
    sh.getRange(i + 1, iImpPor + 1).setValue(String(usuario || ''));
    sh.getRange(i + 1, iJobId  + 1).setValue(String(jobId || ''));
    return true;
  }
  return false;
}

// Reimprimir UNA etiqueta (cajero o vendedor)
function reimprimirEtiqueta(params) {
  if (!params || !params.idEtiq)    return { ok: false, error: 'Requiere idEtiq' };
  if (!params.printerId)             return { ok: false, error: 'Requiere printerId' };
  var sh = _etiqGetSheet();
  var rows = _sheetToObjects(sh);
  var r = rows.find(function(x){ return String(x.idEtiq) === String(params.idEtiq); });
  if (!r) return { ok: false, error: 'idEtiq no encontrado' };
  var pnKey;
  try { pnKey = PropertiesService.getScriptProperties().getProperty('PRINTNODE_API_KEY'); } catch(_){}
  if (!pnKey) return { ok: false, error: 'PRINTNODE_API_KEY no configurado' };
  try {
    var escpos = _etiqGenerarESCPOS({
      descripcion: r.descripcion || r.skuBase || '',
      skuBase:     r.skuBase || '',
      codigoBarra: r.codigoBarra || '',
      precio:      r.precioNuevo
    });
    var content = _etiqToBase64(escpos);
    var resp = UrlFetchApp.fetch('https://api.printnode.com/printjobs', {
      method:      'post',
      headers:     { 'Authorization': 'Basic ' + Utilities.base64Encode(pnKey + ':') },
      contentType: 'application/json',
      payload:     JSON.stringify({
        printerId:   parseInt(String(params.printerId), 10),
        title:       'Reimpresión etiqueta ' + (r.descripcion || r.skuBase),
        contentType: 'raw_base64',
        content:     content,
        source:      'ProyectoMOS · Etiqueta (reimp)'
      }),
      muteHttpExceptions: true
    });
    if (resp.getResponseCode() !== 201) return { ok: false, error: 'PrintNode HTTP ' + resp.getResponseCode() };
    var jobId = resp.getContentText();
    if (String(r.estado).toUpperCase() === 'PENDIENTE') {
      _etiqMarcarImpresa(r.idEtiq, params.usuario || '', jobId);
    }
    return { ok: true, data: { jobId: jobId } };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// ── Dashboard MOS: pendientes por zona ─────────────────────
function getEtiquetasPorZona() {
  var sh = _etiqGetSheet();
  var rows = _sheetToObjects(sh);
  var byZona = {};
  rows.forEach(function(r) {
    var est = String(r.estado || '').toUpperCase();
    if (est === 'PEGADA' || est === 'OBSOLETA') return;
    var idZ = String(r.idZona);
    if (!byZona[idZ]) {
      byZona[idZ] = {
        idZona: idZ,
        zonaNombre: String(r.zonaNombre || idZ),
        pendientes: 0,
        impresas: 0,
        items: []
      };
    }
    if (est === 'PENDIENTE') byZona[idZ].pendientes++;
    if (est === 'IMPRESA')   byZona[idZ].impresas++;
    byZona[idZ].items.push({
      idEtiq: r.idEtiq,
      descripcion: r.descripcion,
      precioAnterior: parseFloat(r.precioAnterior) || 0,
      precioNuevo: parseFloat(r.precioNuevo) || 0,
      estado: est,
      ts_cambio: r.ts_cambio
    });
  });
  return { ok: true, data: Object.values(byZona) };
}

// ── Cron escalación (cada 1h) ──────────────────────────────
function _etiqCronEscalacion() {
  try {
    var sh = _etiqGetSheet();
    var data = sh.getDataRange().getValues();
    var hdrs = data[0];
    var iEstado = hdrs.indexOf('estado');
    var iComent = hdrs.indexOf('comentario');
    var ahora = new Date().getTime();
    var TRES_DIAS_MS = 3 * 24 * 60 * 60 * 1000;
    var nowIso = _etiqNowIso();

    var grpNoVistas = {};
    var grpSinPegar = {};
    var marcadasObsoletas = 0;

    // 1) Pasada de auto-obsoletas (>3 días sin pegar)
    for (var i = 1; i < data.length; i++) {
      var est = String(data[i][iEstado] || '').toUpperCase();
      if (est === 'PEGADA' || est === 'OBSOLETA') continue;
      var tsCambio = data[i][hdrs.indexOf('ts_cambio')];
      var ts; try { ts = new Date(tsCambio).getTime(); } catch(_){ ts = 0; }
      if (ts && (ahora - ts) > TRES_DIAS_MS) {
        sh.getRange(i + 1, iEstado + 1).setValue('OBSOLETA');
        var prevC = String(data[i][iComent] || '');
        sh.getRange(i + 1, iComent + 1).setValue(prevC + (prevC ? ' · ' : '') + 'Auto-obsoleta >3d (' + nowIso + ')');
        marcadasObsoletas++;
      }
    }

    // 2) Re-leer (acabamos de mutar) para escalación
    var rows = _sheetToObjects(sh);
    rows.forEach(function(r) {
      var est = String(r.estado || '').toUpperCase();
      if (est !== 'PENDIENTE' && est !== 'IMPRESA') return;
      var ts; try { ts = new Date(r.ts_cambio).getTime(); } catch(_){ ts = 0; }
      if (!ts) return;
      var minutos = (ahora - ts) / 60000;
      var idZ = String(r.idZona);
      // PENDIENTE >2h sin visto_csv → revisar
      if (est === 'PENDIENTE' && minutos > 120 && !r.visto_csv) {
        if (!grpNoVistas[idZ]) grpNoVistas[idZ] = { zonaNombre: r.zonaNombre, items: [] };
        grpNoVistas[idZ].items.push(r);
      }
      // IMPRESA >4h sin pegar → escalar a admin
      if (est === 'IMPRESA') {
        var tsImp; try { tsImp = new Date(r.ts_impresa).getTime(); } catch(_){ tsImp = 0; }
        var minImp = tsImp ? (ahora - tsImp) / 60000 : 0;
        if (minImp > 240) {
          if (!grpSinPegar[idZ]) grpSinPegar[idZ] = { zonaNombre: r.zonaNombre, items: [] };
          grpSinPegar[idZ].items.push(r);
        }
      }
    });

    // Push a cajeros/vendedores por zonas no vistas
    Object.keys(grpNoVistas).forEach(function(idZ) {
      var g = grpNoVistas[idZ];
      try {
        _enviarPushTodos(
          '🏷 ' + g.items.length + ' etiqueta(s) sin revisar',
          'Zona ' + g.zonaNombre + ' · llevan más de 2h pendientes',
          { rolesPermitidos: ['CAJERO', 'VENDEDOR'], idNotif: 'MOS_ETIQUETA_REVISAR' }
        );
      } catch(_){}
    });
    // Push a admin/master por zonas sin pegar
    Object.keys(grpSinPegar).forEach(function(idZ) {
      var g = grpSinPegar[idZ];
      try {
        _enviarPushTodos(
          '🏷 Zona ' + g.zonaNombre + ' no actualiza',
          g.items.length + ' etiqueta(s) impresa(s) sin pegar hace >4h',
          { soloRolesAdmin: true, idNotif: 'MOS_ETIQUETA_SIN_PEGAR_ADMIN' }
        );
      } catch(_){}
    });

    return { ok: true, data: {
      noVistas:   Object.keys(grpNoVistas).length,
      sinPegar:   Object.keys(grpSinPegar).length,
      obsoletas: marcadasObsoletas
    }};
  } catch(e) { Logger.log('[Etiq] cron error: ' + e.message); return { ok: false, error: e.message }; }
}

function configurarTriggerEtiquetas() {
  ScriptApp.getProjectTriggers().forEach(function(t){
    if (t.getHandlerFunction() === '_etiqCronEscalacion') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('_etiqCronEscalacion').timeBased().everyHours(1).create();
  return { ok: true, msg: 'Trigger creado: _etiqCronEscalacion cada 1h' };
}
