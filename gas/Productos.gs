// ============================================================
// ProyectoMOS — Productos.gs
// CRUD catálogo maestro: PRODUCTOS_MASTER + EQUIVALENCIAS
// + historial de precios + publicación de precio
// ============================================================

// ── DEFENSA: solo origenes autorizados pueden modificar PRODUCTOS_MASTER / EQUIVALENCIAS ──
var _SOURCES_AUTORIZADOS = [
  'MOS_MODAL_PRODUCTO',  // guardarProducto (crear/editar desde modal)
  'MOS_MODAL_PRECIO',    // publicarPrecio (modal de cambio de precio)
  'MOS_TOGGLE',          // toggleProductoActivo (encender/apagar)
  'MOS_TOGGLE_CASCADA',  // _prenderHijos / cascada de presentaciones
  'MOS_EQUIV_MODAL',     // crear equivalencia desde modal
  'MOS_PN_APROBACION',   // lanzarProductoNuevo (crea producto al aprobar PN)
  'MOS_PN_CORRECCION',   // lanzarProductoNuevo tipo CORREGIR_CODIGO
  'MOS_PROV_MINMAX',     // edición inline de stockMinimo/stockMaximo desde proveedores
  'MOS_MIGRACION',       // import bulk
  'MOS_SEGMENTOS_PRECIO' // [v2.41.97] editor de pricing por segmentos (graneles)
];

function _validarSource(params, accion, tabla) {
  var src = params && params._source;
  if (_SOURCES_AUTORIZADOS.indexOf(src) >= 0) return null;
  // No autorizado: registrar alerta CON contexto de auditoría
  try {
    var audit = (params && params._audit) || {};
    var appOrigen = audit.app || 'MOS';
    _registrarAlerta(
      'MOD_NO_AUTORIZADA',
      'CRITICA',
      'Intento de ' + accion + ' en ' + tabla + ' desde origen ' + (src || 'DESCONOCIDO') +
        (audit.usuario ? ' · usuario: ' + audit.usuario : ''),
      appOrigen,
      JSON.stringify({
        accion:        accion,
        tabla:         tabla,
        source:        src || null,
        // Contexto de quién/cuándo/dónde
        usuario:       audit.usuario || null,
        idPersonal:    audit.idPersonal || null,
        rol:           audit.rol || null,
        idSesion:      audit.idSesion || null,
        idDispositivo: audit.idDispositivo || null,
        appOrigen:     appOrigen,
        userAgent:     audit.userAgent || null,
        url:           audit.url || null,
        timestampApp:  audit.timestamp || null,
        timestampSrv:  new Date().toISOString(),
        params:        _safePreviewParams(params)
      })
    );
  } catch(_){}
  return { ok: false, error: 'Operacion bloqueada: origen no autorizado (' + (src || 'sin _source') + ')' };
}

function _safePreviewParams(p) {
  try {
    var s = JSON.stringify(p || {});
    return s.length > 500 ? s.slice(0, 500) + '…' : s;
  } catch(_){ return '{}'; }
}

// ── PRODUCTOS_MASTER ─────────────────────────────────────────
function getProductosMaster(params) {
  var rows = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  if (params.estado)    rows = rows.filter(function(r){ return String(r.estado) === String(params.estado); });
  if (params.skuBase)   rows = rows.filter(function(r){ return r.skuBase === params.skuBase; });
  if (params.categoria) rows = rows.filter(function(r){ return r.idCategoria === params.categoria; });
  if (params.q) {
    var q = params.q.toLowerCase();
    rows = rows.filter(function(r){
      return (r.descripcion || '').toLowerCase().indexOf(q) >= 0 ||
             (r.codigoBarra || '').indexOf(q) >= 0 ||
             (r.skuBase     || '').toLowerCase().indexOf(q) >= 0;
    });
  }
  return { ok: true, data: rows };
}

function getProductoMaster(codigo) {
  var rows = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var prod = rows.find(function(p){
    return p.idProducto === codigo || p.codigoBarra === codigo || p.skuBase === codigo;
  });
  if (!prod) return { ok: false, error: 'Producto no encontrado: ' + codigo };
  return { ok: true, data: prod };
}

// ── LOOKUP POR CÓDIGO DE BARRAS (para MosExpress en venta) ───
// Recibe el código escaneado → devuelve el producto base + info de presentación.
// ME debe mostrar el BASE en el carrito y guardar el codigoBarra original en DETALLE_VENTAS.
function getProductoPorCodigo(params) {
  var codigo = String(params.codigo || '').trim();
  if (!codigo) return { ok: false, error: 'Requiere codigo' };

  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var activos   = productos.filter(function(p){ return String(p.estado) === '1'; });

  // 1. Coincidencia directa en PRODUCTOS_MASTER
  var match = activos.find(function(p){ return p.codigoBarra === codigo; });

  // 2. Si no hay match directo, buscar en EQUIVALENCIAS
  var esEquivalencia = false;
  if (!match) {
    var equivs = _sheetToObjects(getSheet('EQUIVALENCIAS')).filter(function(e){
      return String(e.activo) === '1' && e.codigoBarra === codigo;
    });
    if (equivs.length) {
      match = activos.find(function(p){ return p.idProducto === equivs[0].skuBase; });
      if (match) esEquivalencia = true;
    }
  }

  if (!match) return { ok: false, error: 'Código no encontrado: ' + codigo };

  // 3. Subir al producto base si se escaneó una presentación
  var presentacion = null;
  var base = match;
  if (match.skuBase && match.skuBase !== match.idProducto) {
    var b = activos.find(function(p){ return p.idProducto === match.skuBase; });
    if (b) { base = b; presentacion = match; }
  }

  // 4. Todas las presentaciones del grupo (para que ME muestre opciones si las hay)
  var presentaciones = activos.filter(function(p){
    return p.skuBase === base.idProducto && p.idProducto !== base.idProducto;
  });

  return {
    ok: true,
    data: {
      // Lo que ME debe mostrar en el carrito:
      base: {
        idProducto:      base.idProducto,
        skuBase:         base.skuBase || base.idProducto,
        descripcion:     base.descripcion,
        precioVenta:     base.precioVenta,
        precioCosto:     base.precioCosto,
        unidad:          base.unidad,
        idCategoria:     base.idCategoria,
        factorConversion: presentacion ? parseFloat(presentacion.factorConversion) || 1 : 1,
        Cod_Tributo:     base.Cod_Tributo,
        IGV_Porcentaje:  base.IGV_Porcentaje,
        Tipo_IGV:        base.Tipo_IGV,
        Unidad_Medida:   base.Unidad_Medida
      },
      // Lo que ME debe guardar en DETALLE_VENTAS para ajuste de stock:
      codigoEscaneado:  codigo,
      esEquivalencia:   esEquivalencia,
      esPresentacion:   !!presentacion,
      presentacion:     presentacion ? {
        idProducto:      presentacion.idProducto,
        descripcion:     presentacion.descripcion,
        factorConversion: parseFloat(presentacion.factorConversion) || 1
      } : null,
      todasPresentaciones: presentaciones.map(function(p){
        return { idProducto: p.idProducto, descripcion: p.descripcion, factorConversion: parseFloat(p.factorConversion) || 1, precioVenta: p.precioVenta };
      })
    }
  };
}

// Genera el siguiente número secuencial mirando ambas columnas (idProducto + skuBase)
// Returns { idProducto: 'IDPRO0002316', skuBase: 'LEV0002316', secuencia: 2316 }
function _siguienteSecuenciaProducto(sheet) {
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var idxId  = hdrs.indexOf('idProducto'); if (idxId  < 0) idxId  = 0;
  var idxSku = hdrs.indexOf('skuBase');
  var max = 0;
  for (var i = 1; i < data.length; i++) {
    var id = String(data[i][idxId] || '');
    var m1 = id.match(/^IDPRO(\d+)$/);
    if (m1) max = Math.max(max, parseInt(m1[1], 10));
    if (idxSku >= 0) {
      var sku = String(data[i][idxSku] || '');
      var m2 = sku.match(/^LEV(\d+)$/);
      if (m2) max = Math.max(max, parseInt(m2[1], 10));
    }
  }
  var siguiente = max + 1;
  var pad = String(siguiente).padStart(7, '0');
  return {
    idProducto: 'IDPRO' + pad,
    skuBase:    'LEV'   + pad,
    secuencia:  siguiente
  };
}

// ── Garantía global de formato TEXTO en columnas de identificadores ───
// Aplica setNumberFormat('@') a columnas idProducto, skuBase, codigoBarra
// de PRODUCTOS_MASTER. Idempotente, una sola vez por request.
// REGLA: el codigoBarra es SIEMPRE texto. Sheets no debe convertirlo a número.
var _PM_TEXT_COLS_OK = false;
function _ensurePMTextColumns(sheet) {
  if (_PM_TEXT_COLS_OK) return;
  try {
    sheet = sheet || getSheet('PRODUCTOS_MASTER');
    var hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    ['idProducto', 'skuBase', 'codigoBarra', 'codigoProductoBase'].forEach(function(c){
      var col = hdrs.indexOf(c);
      if (col >= 0) {
        sheet.getRange(2, col + 1, sheet.getMaxRows() - 1, 1).setNumberFormat('@');
      }
    });
    _PM_TEXT_COLS_OK = true;
  } catch(_){}
}

// Garantiza columna 'historialCambios' (JSON array) con fallback a las dos
// columnas legacy 'ultimaEdicionPor' + 'ultimaEdicion' si ya existían.
function _garantizarColumnasAuditoriaProducto(sheet) {
  try {
    sheet = sheet || getSheet('PRODUCTOS_MASTER');
    var hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    if (hdrs.indexOf('historialCambios') < 0) {
      var nextCol = sheet.getLastColumn() + 1;
      sheet.getRange(1, nextCol).setValue('historialCambios').setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
      SpreadsheetApp.flush();
    }
  } catch(_){}
}

// Append una entrada al historial JSON de un producto. Limita a últimas 50.
// entrada = { ts, usuario, source, accion, cambios?: [{campo, antes, despues}], descripcion? }
function _appendHistorialProducto(sheet, rowNum, hdrs, entrada) {
  try {
    var iCol = hdrs.indexOf('historialCambios');
    if (iCol < 0) {
      _garantizarColumnasAuditoriaProducto(sheet);
      hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
      iCol = hdrs.indexOf('historialCambios');
      if (iCol < 0) return;
    }
    var cell = sheet.getRange(rowNum, iCol + 1);
    var raw = String(cell.getValue() || '').trim();
    var arr = [];
    if (raw) {
      try { arr = JSON.parse(raw); } catch(_) { arr = []; }
      if (!Array.isArray(arr)) arr = [];
    }
    arr.push(entrada);
    if (arr.length > 50) arr = arr.slice(-50);
    cell.setNumberFormat('@'); // forzar TEXTO para que no intente parsear como fecha/número
    cell.setValue(JSON.stringify(arr));
  } catch(e) { Logger.log('appendHistorial fail: ' + e.message); }
}

// Endpoint: top N productos con historial de cambios (para panel master "log").
// Lee la columna historialCambios (JSON) y retorna los productos ordenados por
// timestamp de la última entrada del historial. Cada producto trae su historial
// completo (hasta 50 entradas) para que el frontend pueda expandirlo.
function getProductosEditadosRecientes(params) {
  var limit = parseInt((params && params.limit) || 50, 10);
  if (!limit || limit < 1) limit = 50;
  if (limit > 500) limit = 500;
  _garantizarColumnasAuditoriaProducto();
  var rows = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  // Parsear historial + extraer última edición
  rows = rows.map(function(r) {
    var hist = [];
    if (r.historialCambios) {
      try {
        var raw = String(r.historialCambios);
        if (raw) hist = JSON.parse(raw);
      } catch(_) { hist = []; }
      if (!Array.isArray(hist)) hist = [];
    }
    // Compat con datos legacy: si tenía ultimaEdicion + ultimaEdicionPor pero NO hay historial,
    // sintetizar una entrada para no perder ese registro previo.
    if (hist.length === 0 && r.ultimaEdicion) {
      hist.push({
        ts: r.ultimaEdicion instanceof Date ? r.ultimaEdicion.toISOString() : String(r.ultimaEdicion),
        usuario: String(r.ultimaEdicionPor || 'desconocido'),
        source: 'legacy',
        accion: 'editar',
        cambios: []
      });
    }
    r._historial = hist;
    r._ultimaTs = hist.length ? hist[hist.length - 1].ts : null;
    return r;
  }).filter(function(r) { return r._ultimaTs; });
  rows.sort(function(a, b) {
    var ta = new Date(a._ultimaTs).getTime() || 0;
    var tb = new Date(b._ultimaTs).getTime() || 0;
    return tb - ta;
  });
  return { ok: true, data: rows.slice(0, limit).map(function(r) {
    return {
      idProducto:       r.idProducto,
      skuBase:          r.skuBase,
      descripcion:      r.descripcion,
      precioVenta:      r.precioVenta,
      historial:        r._historial,                 // array completo de entradas
      ultimaEntrada:    r._historial[r._historial.length - 1],
      codigoProductoBase: r.codigoProductoBase || '',
      factorConversion: r.factorConversion,
      esEnvasable:      r.esEnvasable
    };
  }) };
}

function crearProductoMaster(params) {
  var bloqueo = _validarSource(params, 'crear', 'PRODUCTOS_MASTER');
  if (bloqueo) return bloqueo;

  // VALIDACIONES OBLIGATORIAS — coherentes entre catálogo y revisión PN
  if (!params.descripcion || !String(params.descripcion).trim()) {
    return { ok: false, error: 'La descripción es requerida' };
  }
  var precioVentaNum = parseFloat(params.precioVenta);
  if (!precioVentaNum || precioVentaNum <= 0) {
    return { ok: false, error: 'El precio de venta es requerido y debe ser mayor a 0' };
  }

  var sheet = getSheet('PRODUCTOS_MASTER');

  // 1. IDs secuenciales (IDPRO0002316 / LEV0002316)
  var seq = _siguienteSecuenciaProducto(sheet);
  var id      = params.idProducto || seq.idProducto;
  var skuBase = params.skuBase    || seq.skuBase;

  // 2. Validación duplicado de codigoBarra
  if (params.codigoBarra) {
    var existing = _sheetToObjects(sheet).find(function(p){
      return String(p.codigoBarra || '').trim() === String(params.codigoBarra).trim();
    });
    if (existing) {
      return { ok: false, error: 'El código de barras ' + params.codigoBarra +
                                  ' ya existe en el producto ' + existing.idProducto +
                                  ' (' + (existing.descripcion || 'sin descripción') + ')' };
    }
  }

  // 3. Defaults SUNAT autorrelleno
  var tipoIGV = (params.Tipo_IGV !== undefined && params.Tipo_IGV !== '')
              ? String(params.Tipo_IGV) : '1';   // 1 = Gravado por default
  // Migrar valores legacy
  var legacyMap = { 'gravado': '1', 'exonerado': '2', 'inafecto': '3' };
  if (legacyMap[String(tipoIGV).toLowerCase()]) tipoIGV = legacyMap[String(tipoIGV).toLowerCase()];

  var igvPct = (params.IGV_Porcentaje !== undefined && params.IGV_Porcentaje !== '')
             ? parseFloat(params.IGV_Porcentaje) : (tipoIGV === '1' ? 18 : 0);
  var codTributo = params.Cod_Tributo || (tipoIGV === '1' ? '1000' : tipoIGV === '2' ? '9997' : tipoIGV === '3' ? '9998' : '');
  var codSunat = params.Cod_SUNAT || '10000000';
  // Unificación: si solo viene uno de los dos, sincronizamos para mantener ambas columnas iguales
  var _unidadIn = params.unidad || params.Unidad_Medida || 'NIU';
  var _unidadMedidaIn = params.Unidad_Medida || params.unidad || 'NIU';
  // Si vinieron ambos pero distintos, prima Unidad_Medida (código SUNAT autoritativo)
  if (params.unidad && params.Unidad_Medida && params.unidad !== params.Unidad_Medida) {
    _unidadIn = _unidadMedidaIn = params.Unidad_Medida;
  }
  var unidad = _unidadIn;
  var unidadMedida = _unidadMedidaIn;

  // 4. factorConversion: 1 si es base (no derivado, no presentación)
  var esDerivado = !!(params.codigoProductoBase && String(params.codigoProductoBase).trim());
  var esPresentacion = !!(params.skuBase && params.skuBase !== id);
  var factorConv;
  if (esPresentacion) {
    factorConv = parseFloat(params.factorConversion) || 1;
  } else if (esDerivado) {
    factorConv = '';  // derivado usa factorConversionBase
  } else {
    factorConv = 1;   // base = factor 1
  }

  // Garantizar columnas de política antes de escribir (idempotente)
  try { _garantizarColumnasPoliticaProductos(); } catch(_){}
  // Garantizar formato texto en columnas de IDs (idempotente)
  _ensurePMTextColumns(sheet);

  // Política override (vacío = hereda de categoría)
  var modoOverride  = String(params.modoVenta || '').toUpperCase();
  if (['MARGEN','FIJO','COMPETITIVO','LIBRE'].indexOf(modoOverride) === -1) modoOverride = '';
  var margenOverride = (params.margenPct !== '' && params.margenPct !== undefined && params.margenPct !== null) ? parseFloat(params.margenPct) : '';
  var topeOverride   = (params.precioTope !== '' && params.precioTope !== undefined && params.precioTope !== null) ? parseFloat(params.precioTope) : '';

  // 5. Construir la fila POR NOMBRE DE COLUMNA del header real del sheet
  //    — evita desfase si la sheet tiene columnas extra (ej: factorConversionBase
  //    insertado entre factorConversion y mermaEsperadaPct).
  var hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var ahora = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd HH:mm:ss');
  var camposPorNombre = {
    idProducto:           String(id),
    skuBase:              String(skuBase),
    codigoBarra:          String(params.codigoBarra || ''),
    descripcion:          params.descripcion || '',
    marca:                params.marca || '',
    idCategoria:          params.idCategoria || '',
    unidad:               unidad,
    precioVenta:          parseFloat(params.precioVenta) || 0,
    precioCosto:          parseFloat(params.precioCosto) || 0,
    Cod_Tributo:          codTributo,
    IGV_Porcentaje:       igvPct,
    Cod_SUNAT:            codSunat,
    Tipo_IGV:             tipoIGV,
    Unidad_Medida:        unidadMedida,
    estado:               '1',
    esEnvasable:          params.esEnvasable || '0',
    codigoProductoBase:   String(params.codigoProductoBase || ''),
    factorConversion:     factorConv,
    factorConversionBase: parseFloat(params.factorConversionBase) || '',
    mermaEsperadaPct:     parseFloat(params.mermaEsperadaPct) || '',
    stockMinimo:          parseFloat(params.stockMinimo) || 0,
    stockMaximo:          parseFloat(params.stockMaximo) || 0,
    zona:                 params.zona || '',
    fechaCreacion:        ahora,
    creadoPor:            params.usuario || '',
    modoVenta:            modoOverride,
    margenPct:            isNaN(margenOverride) ? '' : margenOverride,
    precioTope:           isNaN(topeOverride) ? '' : topeOverride
  };
  // Construir el array según el orden REAL del header del sheet
  var values = hdrs.map(function(h){
    return camposPorNombre[h] !== undefined ? camposPorNombre[h] : '';
  });

  var nextRow = sheet.getLastRow() + 1;
  sheet.getRange(nextRow, 1, 1, values.length).setValues([values]);

  if (parseFloat(params.precioVenta) > 0) {
    _registrarHistorialPrecio(id, skuBase, params.codigoBarra || '',
      params.descripcion || '', 0, parseFloat(params.precioVenta),
      params.usuario || '', 'Precio inicial', 'MOS');
  }

  // Auditoría: registrar entrada inicial en historialCambios
  try {
    _garantizarColumnasAuditoriaProducto(sheet);
    var hdrsActual = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    var auditUser = params.usuario;
    if (!auditUser && params._audit && params._audit.usuario) auditUser = params._audit.usuario;
    if (!auditUser) auditUser = 'desconocido';
    _appendHistorialProducto(sheet, nextRow, hdrsActual, {
      ts: new Date().toISOString(),
      usuario: String(auditUser),
      source: String(params._source || 'unknown'),
      accion: 'crear',
      descripcion: String(params.descripcion || ''),
      codigoBarra: String(params.codigoBarra || ''),
      precioVenta: parseFloat(params.precioVenta) || 0
    });
  } catch(_){}

  return { ok: true, data: { idProducto: id, skuBase: skuBase, secuencia: seq.secuencia } };
}

function actualizarProductoMaster(params) {
  var bloqueo = _validarSource(params, 'actualizar', 'PRODUCTOS_MASTER');
  if (bloqueo) return bloqueo;

  // Sincronización: si el frontend manda solo `unidad` o solo `Unidad_Medida`,
  // copiar el valor al otro campo para mantener ambas columnas alineadas.
  if (params.unidad && params.Unidad_Medida === undefined) {
    params.Unidad_Medida = params.unidad;
  } else if (params.Unidad_Medida && params.unidad === undefined) {
    params.unidad = params.Unidad_Medida;
  } else if (params.unidad && params.Unidad_Medida && params.unidad !== params.Unidad_Medida) {
    // Si vinieron ambos pero distintos, prima Unidad_Medida
    params.unidad = params.Unidad_Medida;
  }

  // Validación: si están actualizando precioVenta, no aceptar 0 ni vacío
  if (params.precioVenta !== undefined && params.precioVenta !== '') {
    var pv = parseFloat(params.precioVenta);
    if (!pv || pv <= 0) {
      return { ok: false, error: 'El precio de venta no puede ser 0 ni vacío' };
    }
  }

  var sheet = getSheet('PRODUCTOS_MASTER');
  // Garantizar formato texto en columnas de IDs antes de cualquier escritura
  _ensurePMTextColumns(sheet);
  // Garantizar columnas de auditoría (ultimaEdicionPor + ultimaEdicion) — idempotente
  _garantizarColumnasAuditoriaProducto(sheet);
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];

  for (var i = 1; i < data.length; i++) {
    // Match SOLO por idProducto cuando viene (más seguro que el OR codigoBarra)
    var match = params.idProducto
      ? (data[i][0] === params.idProducto)
      : (data[i][2] === params.codigoBarra);
    if (!match) continue;

    var precioAnterior = data[i][hdrs.indexOf('precioVenta')];

    // Garantizar columnas de política antes de actualizar (idempotente)
    try { _garantizarColumnasPoliticaProductos(); hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0]; } catch(_){}

    var campos = ['skuBase','codigoBarra','descripcion','marca','idCategoria','unidad',
                  'precioVenta','precioCosto','Cod_Tributo','IGV_Porcentaje','Cod_SUNAT','Tipo_IGV',
                  'Unidad_Medida','estado','esEnvasable','codigoProductoBase',
                  'factorConversion','factorConversionBase','mermaEsperadaPct',
                  'stockMinimo','stockMaximo','zona',
                  'modoVenta','margenPct','precioTope'];
    var _numCampos = ['precioVenta','precioCosto','factorConversion','factorConversionBase',
                      'mermaEsperadaPct','stockMinimo','stockMaximo','IGV_Porcentaje',
                      'margenPct','precioTope'];
    // Campos críticos que NUNCA deben sobrescribirse con vacío. Si el frontend
    // manda params[campo] = '' o null, IGNORAR. Si querés borrar de verdad, usar
    // el flag explícito params._permitirVaciar = ['campo1','campo2'].
    // Esto previene el bug en que el modal manda todo el form con vacíos no intencionales.
    var _camposNoVaciables = ['skuBase', 'codigoBarra', 'descripcion',
                              'factorConversion', 'codigoProductoBase', 'factorConversionBase',
                              'idCategoria', 'unidad', 'Unidad_Medida'];
    var _permitirVaciar = Array.isArray(params._permitirVaciar) ? params._permitirVaciar : [];
    // Campos que deben preservarse como TEXTO (evitar conversión a número que pierde
    // ceros a la izquierda, formato GS1, etc.)
    var _camposTexto = ['skuBase', 'codigoBarra', 'codigoProductoBase'];
    var _huboCambioReal = false;
    var _cambiosDetectados = []; // [{campo, antes, despues}]
    // Compara dos valores ignorando diferencias de formato (coma vs punto, trim,
    // tolerancia numérica de 0.001). Evita registrar cambios "fantasma" como
    // 9,50 → 9.5 que en realidad son el mismo valor.
    function _valoresIguales(a, b) {
      if (a === b) return true;
      if (a == null && b == null) return true;
      var sa = String(a == null ? '' : a).trim();
      var sb = String(b == null ? '' : b).trim();
      if (sa === sb) return true;
      // Intento numérico (acepta coma decimal)
      var na = parseFloat(sa.replace(',', '.'));
      var nb = parseFloat(sb.replace(',', '.'));
      if (!isNaN(na) && !isNaN(nb) && isFinite(na) && isFinite(nb)) {
        return Math.abs(na - nb) < 0.001;
      }
      return false;
    }
    campos.forEach(function(campo) {
      if (params[campo] !== undefined) {
        var col = hdrs.indexOf(campo);
        if (col < 0) return;
        var llegoVacio = (params[campo] === '' || params[campo] === null);
        // Si es campo protegido contra vaciado y llega vacío sin flag explícito → ignorar
        if (llegoVacio &&
            _camposNoVaciables.indexOf(campo) >= 0 &&
            _permitirVaciar.indexOf(campo) < 0) {
          return;
        }
        var cell = sheet.getRange(i + 1, col + 1);
        var valorActual = data[i][col];
        if (_camposTexto.indexOf(campo) >= 0) {
          cell.setNumberFormat('@');
          var nuevoVal = String(params[campo] || '');
          // Para campos texto: comparación trimmed (códigos sí distinguen "001" vs "1")
          if (String(valorActual || '').trim() !== nuevoVal.trim()) {
            _huboCambioReal = true;
            _cambiosDetectados.push({ campo: campo, antes: String(valorActual || ''), despues: nuevoVal });
          }
          cell.setValue(nuevoVal);
        } else {
          var val = (_numCampos.indexOf(campo) >= 0 && params[campo] !== '')
            ? parseFloat(params[campo])
            : params[campo];
          var nuevoFinal = isNaN(val) ? params[campo] : val;
          if (!_valoresIguales(valorActual, nuevoFinal)) {
            _huboCambioReal = true;
            _cambiosDetectados.push({ campo: campo, antes: valorActual, despues: nuevoFinal });
          }
          cell.setValue(nuevoFinal);
        }
      }
    });

    // Estandarizar: si después del update el producto es CANÓNICO y factorConversion
    // está vacío, escribir 1 explícitamente (modelo normalizado).
    try {
      var iCpb = hdrs.indexOf('codigoProductoBase');
      var iFc  = hdrs.indexOf('factorConversion');
      var cpbActual = String(sheet.getRange(i + 1, iCpb + 1).getValue() || '').trim();
      var fcActual  = sheet.getRange(i + 1, iFc + 1).getValue();
      if (!cpbActual && (fcActual === '' || fcActual === null || fcActual === undefined)) {
        sheet.getRange(i + 1, iFc + 1).setValue(1);
      }
    } catch(_){}

    // Auditoría: append entrada al historialCambios (JSON array).
    // Cada entrada captura quién, cuándo, fuente, acción, y diff de campos.
    if (_huboCambioReal) {
      try {
        var auditUser = params.usuario;
        if (!auditUser && params._audit && params._audit.usuario) auditUser = params._audit.usuario;
        if (!auditUser) auditUser = params._noPropagar ? 'sistema · propagación' : 'desconocido';
        var entrada = {
          ts: new Date().toISOString(),
          usuario: String(auditUser),
          source: String(params._source || 'unknown'),
          accion: params._noPropagar ? 'editar (auto)' : 'editar',
          cambios: _cambiosDetectados
        };
        if (params.motivoPrecio) entrada.motivo = String(params.motivoPrecio);
        _appendHistorialProducto(sheet, i + 1, hdrs, entrada);
      } catch(_){}
    }

    // Historial si cambió el precio
    var cambioPrecioVenta = (params.precioVenta !== undefined &&
        parseFloat(params.precioVenta) !== parseFloat(precioAnterior));
    if (cambioPrecioVenta) {
      _registrarHistorialPrecio(
        data[i][0], data[i][1], data[i][2], data[i][3],
        precioAnterior, params.precioVenta,
        params.usuario || '', params.motivoPrecio || 'Actualización', 'MOS'
      );
    }

    // Si cambió precioVenta y este producto es CANÓNICO, propagar a presentaciones
    // por factor de conversión. Excluye presentaciones con modoVenta=FIJO o LIBRE.
    // Se evita recursión con el flag _noPropagar.
    var presentacionesActualizadas = 0;
    if (cambioPrecioVenta && !params._noPropagar) {
      try {
        var prodActualizado = {
          idProducto: data[i][hdrs.indexOf('idProducto')],
          skuBase: data[i][hdrs.indexOf('skuBase')],
          codigoProductoBase: data[i][hdrs.indexOf('codigoProductoBase')],
          factorConversion: data[i][hdrs.indexOf('factorConversion')]
        };
        if (_esCanonico(prodActualizado) && prodActualizado.skuBase) {
          presentacionesActualizadas = _propagarPrecioVentaAPresentaciones(
            prodActualizado, parseFloat(params.precioVenta), params.usuario, params.motivoPrecio
          );
        }
      } catch(eP) { Logger.log('Propagación falló: ' + eP.message); }
    }

    return { ok: true, data: { presentacionesActualizadas: presentacionesActualizadas } };
  }
  return { ok: false, error: 'Producto no encontrado' };
}

// Propaga el precio de venta del canónico a sus presentaciones, según factor.
// Reglas:
//   - Solo presentaciones (mismo skuBase, factor != 1, sin codigoProductoBase)
//   - Excluye las que tienen modoVenta = FIJO o LIBRE (precios protegidos)
//   - precioPresentación = precioCanónico × factorConversion
// Retorna cantidad de presentaciones actualizadas.
function _propagarPrecioVentaAPresentaciones(canonico, precioNuevoCanonico, usuario, motivoOrig) {
  if (!canonico || !canonico.skuBase || !(precioNuevoCanonico > 0)) return 0;
  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var skuRef = String(canonico.skuBase).toUpperCase();
  var idCanonRef = String(canonico.idProducto || '').toUpperCase();

  var presentaciones = productos.filter(function(p) {
    if (String(p.skuBase || '').toUpperCase() !== skuRef) return false;
    if (String(p.idProducto || '').toUpperCase() === idCanonRef) return false; // excluir el propio canónico
    if (String(p.codigoProductoBase || '').trim()) return false;               // derivados se manejan aparte
    var f = parseFloat(p.factorConversion);
    return !isNaN(f) && f > 0 && f !== 1;
  });

  var actualizadas = 0;
  presentaciones.forEach(function(p) {
    var modo = String(p.modoVenta || '').toUpperCase();
    if (modo === 'FIJO' || modo === 'LIBRE') return; // respetar precios protegidos
    var f = parseFloat(p.factorConversion);
    var precioPres = Math.round(precioNuevoCanonico * f * 100) / 100;
    if (precioPres <= 0) return;
    try {
      actualizarProductoMaster({
        _source:      'MOS_MODAL_PRODUCTO',
        _noPropagar:  true,  // evitar recursión
        idProducto:   p.idProducto,
        precioVenta:  precioPres,
        usuario:      usuario || '',
        motivoPrecio: 'Propagado desde canónico ' + (canonico.idProducto || '') + (motivoOrig ? ' · ' + motivoOrig : '')
      });
      actualizadas++;
    } catch(_){}
  });
  return actualizadas;
}

// ── EQUIVALENCIAS ─────────────────────────────────────────────
function getEquivalencias(params) {
  var rows = _sheetToObjects(getSheet('EQUIVALENCIAS'));
  if (params.skuBase)     rows = rows.filter(function(r){ return r.skuBase === params.skuBase; });
  if (params.codigoBarra) rows = rows.filter(function(r){ return r.codigoBarra === params.codigoBarra; });
  if (params.activo)      rows = rows.filter(function(r){ return String(r.activo) === String(params.activo); });
  return { ok: true, data: rows };
}

function crearEquivalencia(params) {
  var bloqueo = _validarSource(params, 'crear', 'EQUIVALENCIAS');
  if (bloqueo) return bloqueo;
  if (!params.skuBase || !params.codigoBarra) {
    return { ok: false, error: 'Requiere skuBase y codigoBarra' };
  }
  var sheet = getSheet('EQUIVALENCIAS');
  var id = _generateId('EQ');
  var nextRow = sheet.getLastRow() + 1;
  sheet.getRange(nextRow, 2, 1, 2).setNumberFormat('@');
  var values = [id, String(params.skuBase || ''), String(params.codigoBarra || ''), params.descripcion || '', '1'];
  sheet.getRange(nextRow, 1, 1, values.length).setValues([values]);
  // Auditoría: registrar entrada en el historial del producto base
  try {
    _registrarEnHistorialProductoPorSkuBase(params.skuBase, {
      ts: new Date().toISOString(),
      usuario: String(params.usuario || (params._audit && params._audit.usuario) || 'desconocido'),
      source: String(params._source || 'unknown'),
      accion: 'agregar equivalencia',
      codigoEquivalente: String(params.codigoBarra),
      descripcionEquiv: String(params.descripcion || '')
    });
  } catch(_){}
  return { ok: true, data: { idEquiv: id } };
}

function actualizarEquivalencia(params) {
  var bloqueo = _validarSource(params, 'actualizar', 'EQUIVALENCIAS');
  if (bloqueo) return bloqueo;
  if (!params.idEquiv) return { ok: false, error: 'Requiere idEquiv' };
  var sheet = getSheet('EQUIVALENCIAS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) !== String(params.idEquiv)) continue;
    var skuBase = String(data[i][hdrs.indexOf('skuBase')] || '');
    var cambios = [];
    var campos = ['codigoBarra', 'descripcion', 'activo'];
    campos.forEach(function(c) {
      if (params[c] !== undefined) {
        var col = hdrs.indexOf(c);
        if (col < 0) return;
        var prev = data[i][col];
        var cell = sheet.getRange(i + 1, col + 1);
        var nuevo = c === 'codigoBarra' ? String(params[c] || '') : params[c];
        if (String(prev) !== String(nuevo)) cambios.push({ campo: 'equiv.' + c, antes: prev, despues: nuevo });
        if (c === 'codigoBarra') {
          cell.setNumberFormat('@');
          cell.setValue(String(params[c] || ''));
        } else {
          cell.setValue(params[c]);
        }
      }
    });
    // Auditoría: registrar cambios en historial del producto base
    if (cambios.length && skuBase) {
      try {
        _registrarEnHistorialProductoPorSkuBase(skuBase, {
          ts: new Date().toISOString(),
          usuario: String(params.usuario || (params._audit && params._audit.usuario) || 'desconocido'),
          source: String(params._source || 'unknown'),
          accion: String(params.activo) === '0' ? 'desactivar equivalencia' : 'editar equivalencia',
          cambios: cambios,
          idEquiv: params.idEquiv
        });
      } catch(_){}
    }
    return { ok: true };
  }
  return { ok: false, error: 'Equivalencia no encontrada: ' + params.idEquiv };
}

// Helper: append entrada al historial del producto cuyo skuBase coincide.
// Útil para auditar cambios de equivalencias en el log del producto base.
function _registrarEnHistorialProductoPorSkuBase(skuBase, entrada) {
  if (!skuBase) return;
  var sheet = getSheet('PRODUCTOS_MASTER');
  _garantizarColumnasAuditoriaProducto(sheet);
  var data = sheet.getDataRange().getValues();
  var hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var iSku = hdrs.indexOf('skuBase');
  var iCpb = hdrs.indexOf('codigoProductoBase');
  var iFc  = hdrs.indexOf('factorConversion');
  if (iSku < 0) return;
  var skuRef = String(skuBase).toUpperCase();
  // Match al CANÓNICO (mismo skuBase, sin codigoProductoBase, factor=1 o vacío)
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iSku] || '').toUpperCase() !== skuRef) continue;
    var cpb = iCpb >= 0 ? String(data[i][iCpb] || '').trim() : '';
    var fc  = iFc  >= 0 ? data[i][iFc] : 1;
    var esCanon = !cpb && (fc === '' || fc === null || fc === undefined || parseFloat(fc) === 1);
    if (!esCanon) continue;
    _appendHistorialProducto(sheet, i + 1, hdrs, entrada);
    return;
  }
}

// ── HISTORIAL DE PRECIOS ─────────────────────────────────────
function getHistorialPrecios(params) {
  var rows = _sheetToObjects(getSheet('HISTORIAL_PRECIOS'));
  if (params.skuBase)     rows = rows.filter(function(r){ return r.skuBase === params.skuBase; });
  if (params.codigoBarra) rows = rows.filter(function(r){ return r.codigoBarra === params.codigoBarra; });
  if (params.limit)       rows = rows.slice(-parseInt(params.limit));
  return { ok: true, data: rows };
}

// Publicar precio: actualiza catálogo + registra historial + genera alerta para imprimir membretes
function publicarPrecio(params) {
  var _precioNuevo = parseFloat(params.precioNuevo);
  if (!_precioNuevo || _precioNuevo <= 0) return { ok: false, error: 'Requiere precioNuevo válido' };
  if (!params.idProducto && !params.codigoBarra && !params.skuBase) {
    return { ok: false, error: 'Requiere idProducto, codigoBarra o skuBase' };
  }

  // Resolver usuario: explícito > _audit (auto-inyectado por api.js) > 'desconocido'
  var usuarioFinal = params.usuario;
  if (!usuarioFinal && params._audit && params._audit.usuario) usuarioFinal = params._audit.usuario;

  var res = actualizarProductoMaster({
    _source:      'MOS_MODAL_PRECIO',
    _audit:       params._audit,    // propagar contexto de auditoría
    idProducto:   params.idProducto,
    codigoBarra:  params.codigoBarra,
    precioVenta:  _precioNuevo,
    usuario:      usuarioFinal || '',
    motivoPrecio: params.motivo || 'Publicación de precio'
  });
  if (!res.ok) return res;

  // Alerta para imprimir membretes de precio en almacén
  if (params.imprimirMembretes === 'true' || params.imprimirMembretes === true) {
    _registrarAlerta('PRECIO_CAMBIADO', 'ALTA',
      'Nuevo precio: S/. ' + params.precioNuevo + ' — ' + (params.descripcion || params.skuBase || ''),
      'MOS',
      JSON.stringify({ skuBase: params.skuBase, codigoBarra: params.codigoBarra,
                       precio: params.precioNuevo, zonas: params.zonas || 'TODAS' })
    );
  }

  // ⚡ Generar etiquetas pendientes para cada zona (excepto ALMACÉN)
  // Se ejecuta SIEMPRE que cambia el precio (no requiere flag explícito).
  // Los cajeros/vendedores las verán en su badge y el auto-print al
  // abrir caja se encargará del resto.
  var etiqResult = null;
  try {
    if (typeof _etiqGenerarParaZonas === 'function') {
      etiqResult = _etiqGenerarParaZonas({
        idProducto:     params.idProducto || '',
        codigoBarra:    params.codigoBarra || '',
        skuBase:        params.skuBase || '',
        descripcion:    params.descripcion || '',
        precioAnterior: parseFloat(params.precioAnterior) || 0,
        precioNuevo:    _precioNuevo,
        usuario:        usuarioFinal || ''
      });
    }
  } catch(eEtiq) { Logger.log('[publicarPrecio] _etiqGenerarParaZonas: ' + eEtiq.message); }

  return { ok: true, data: {
    precioNuevo: params.precioNuevo,
    alertaGenerada: !!params.imprimirMembretes,
    etiquetas: etiqResult ? etiqResult.data : null
  }};
}

function _registrarHistorialPrecio(idProd, skuBase, codBarra, desc, anterior, nuevo, usuario, motivo, app) {
  var sheet = getSheet('HISTORIAL_PRECIOS');
  var nextRow = sheet.getLastRow() + 1;
  // Columnas 2 (skuBase) y 3 (codigoBarra) deben quedar como TEXTO para preservar
  // ceros a la izquierda y evitar que Sheets las convierta a número.
  sheet.getRange(nextRow, 2, 1, 2).setNumberFormat('@');
  var values = [
    _generateId('HP'),
    String(skuBase  || ''),
    String(codBarra || ''),
    desc, anterior, nuevo, usuario, motivo, app, new Date()
  ];
  sheet.getRange(nextRow, 1, 1, values.length).setValues([values]);
}

function _registrarAlerta(tipo, urgencia, mensaje, appOrigen, datos) {
  var sheet = getSheet('ALERTAS_LOG');
  sheet.appendRow([_generateId('AL'), tipo, urgencia, mensaje, appOrigen, datos || '', new Date(), '0']);
}

// ============================================================
// [v2.41.97] PRICING POR SEGMENTOS — solo productos KGM (graneles)
// Permite definir tramos sobre la cantidad en gramos que aplican
// un ajuste porcentual al precio canónico por kg.
//
// Estructura interna (siempre en GRAMOS):
//   [{ id, nombre, min, max, minIncl, maxIncl, ajustePct, creadoEn }]
//
// Reglas:
//   - min/max en gramos. max=null = infinito.
//   - minIncl/maxIncl bool (cerrado/abierto).
//   - ajustePct entre -50 y +50, NO puede ser 0 (sino el segmento no tiene sentido).
//   - No solapan entre sí.
//   - min < max (si max no es null).
// ============================================================
function _validarSegmentosPrecio(segmentos) {
  if (!Array.isArray(segmentos)) return { ok: false, error: 'Debe ser un array' };
  if (segmentos.length === 0) return { ok: true, segmentos: [] };
  // Validar cada segmento
  var limpios = [];
  for (var i = 0; i < segmentos.length; i++) {
    var s = segmentos[i];
    if (typeof s.min !== 'number' || isNaN(s.min) || s.min < 0) {
      return { ok: false, error: 'Segmento ' + (i+1) + ': min debe ser número >= 0' };
    }
    if (s.max !== null && (typeof s.max !== 'number' || isNaN(s.max) || s.max <= s.min)) {
      return { ok: false, error: 'Segmento ' + (i+1) + ': max debe ser > min (o null para infinito)' };
    }
    if (typeof s.ajustePct !== 'number' || isNaN(s.ajustePct)) {
      return { ok: false, error: 'Segmento ' + (i+1) + ': ajustePct requerido' };
    }
    if (s.ajustePct === 0) {
      return { ok: false, error: 'Segmento ' + (i+1) + ': el ajuste no puede ser 0% (sería redundante)' };
    }
    if (s.ajustePct < -50 || s.ajustePct > 50) {
      return { ok: false, error: 'Segmento ' + (i+1) + ': ajustePct debe estar entre -50 y +50' };
    }
    limpios.push({
      id:        String(s.id || ('seg-' + Date.now() + '-' + i)),
      nombre:    String(s.nombre || '').substring(0, 40),
      min:       Math.round(s.min),
      max:       s.max === null ? null : Math.round(s.max),
      minIncl:   s.minIncl !== false,
      maxIncl:   s.maxIncl === true,
      ajustePct: Math.round(s.ajustePct * 100) / 100,
      creadoEn:  String(s.creadoEn || new Date().toISOString())
    });
  }
  // Detectar solapamientos: para cada par, ver si se intersectan
  for (var a = 0; a < limpios.length; a++) {
    for (var b = a + 1; b < limpios.length; b++) {
      if (_segmentosSolapan(limpios[a], limpios[b])) {
        return { ok: false, error: 'Solapamiento entre "' + (limpios[a].nombre || a+1) + '" y "' + (limpios[b].nombre || b+1) + '"' };
      }
    }
  }
  return { ok: true, segmentos: limpios };
}

function _segmentosSolapan(a, b) {
  // Normalizar: convertir bounds inclusivos/exclusivos a "ranges abiertos"
  // para comparación. min con minIncl=true es [min, ...) y minIncl=false es (min, ...)
  // max con maxIncl=true es [..., max] y maxIncl=false es [..., max)
  var aMaxEff = a.max === null ? Infinity : a.max;
  var bMaxEff = b.max === null ? Infinity : b.max;
  // ¿a y b tienen algún punto en común?
  // No solapan si a termina antes (o exactamente en frontera abierta) de que b empiece.
  if (aMaxEff < b.min) return false;
  if (aMaxEff === b.min) {
    // Frontera: solapan solo si AMBOS extremos son cerrados
    if (!a.maxIncl || !b.minIncl) return false;
  }
  if (bMaxEff < a.min) return false;
  if (bMaxEff === a.min) {
    if (!b.maxIncl || !a.minIncl) return false;
  }
  return true;
}

// Helper: determina si una cantidad (en gramos) cae dentro de un segmento.
function _gramosEnSegmento(gramos, s) {
  var cumpleMin = s.minIncl ? gramos >= s.min : gramos > s.min;
  if (!cumpleMin) return false;
  if (s.max === null) return true;
  return s.maxIncl ? gramos <= s.max : gramos < s.max;
}

// Helper público: calcula el precio total de X gramos de un granel dado su
// precio canónico/kg y los segmentos configurados. Usado por ME al vender.
function calcularPrecioGranel(precioCanonico, gramos, segmentos) {
  var pc = parseFloat(precioCanonico) || 0;
  var g  = parseFloat(gramos) || 0;
  if (pc <= 0 || g <= 0) return { precio: 0, ajustePct: 0, segmento: null };
  var lista = Array.isArray(segmentos) ? segmentos : [];
  var aplicado = null;
  for (var i = 0; i < lista.length; i++) {
    if (_gramosEnSegmento(g, lista[i])) {
      aplicado = lista[i];
      break;
    }
  }
  var ajuste = aplicado ? aplicado.ajustePct : 0;
  var precioKg = pc * (1 + ajuste / 100);
  var precioTotal = Math.round(precioKg * (g / 1000) * 100) / 100;
  return {
    precio: precioTotal,
    precioKg: Math.round(precioKg * 100) / 100,
    ajustePct: ajuste,
    segmento: aplicado ? { id: aplicado.id, nombre: aplicado.nombre, min: aplicado.min, max: aplicado.max } : null
  };
}

// ── Endpoint: actualizarSegmentosPrecio ──
// Persiste segmentos validados en columna `segmentos_precio` de PRODUCTOS_MASTER.
// Solo aplicable si el producto tiene Unidad_Medida === 'KGM'.
function actualizarSegmentosPrecio(params) {
  var bloqueo = _validarSource(params, 'segmentos', 'PRODUCTOS_MASTER');
  if (bloqueo) return bloqueo;
  if (!params.idProducto) return { ok: false, error: 'idProducto requerido' };

  // Validar segmentos
  var val = _validarSegmentosPrecio(params.segmentos || []);
  if (!val.ok) return val;

  var sheet = getSheet('PRODUCTOS_MASTER');
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  // Auto-crear columna segmentos_precio si no existe (idempotente)
  var idxSeg = hdrs.indexOf('segmentos_precio');
  if (idxSeg < 0) {
    sheet.getRange(1, sheet.getLastColumn() + 1).setValue('segmentos_precio').setFontWeight('bold');
    SpreadsheetApp.flush();
    hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    idxSeg = hdrs.indexOf('segmentos_precio');
  }
  var idxUM = hdrs.indexOf('Unidad_Medida');
  var idxFC = hdrs.indexOf('factorConversion');

  for (var i = 1; i < data.length; i++) {
    if (data[i][0] !== params.idProducto) continue;
    // Validar que sea granel (KGM)
    var um = String(data[i][idxUM] || '').toUpperCase();
    if (um !== 'KGM') {
      return { ok: false, error: 'Solo productos KGM (granel) admiten segmentos · este es ' + (um || 'sin unidad') };
    }
    // Validar que sea canónico (factor=1) — los segmentos viven en el canónico
    var fc = parseFloat(data[i][idxFC] || 1);
    if (fc !== 1) {
      return { ok: false, error: 'Los segmentos se configuran en el canónico (factor=1), no en presentaciones' };
    }
    // Persistir
    var json = JSON.stringify(val.segmentos);
    sheet.getRange(i + 1, idxSeg + 1).setValue(json);
    SpreadsheetApp.flush();
    // Audit
    try {
      var ts = new Date().toISOString();
      var aud = params._audit || {};
      var entrada = {
        ts: ts,
        usuario: aud.usuario || params.usuario || 'admin',
        source: 'MOS_SEGMENTOS_PRECIO',
        accion: 'actualizar_segmentos',
        cambios: [{ campo: 'segmentos_precio', cantidad: val.segmentos.length }]
      };
      var idxHist = hdrs.indexOf('historialCambios');
      if (idxHist >= 0) {
        var existente = String(data[i][idxHist] || '[]');
        var arr;
        try { arr = JSON.parse(existente); } catch(_) { arr = []; }
        if (!Array.isArray(arr)) arr = [];
        arr.push(entrada);
        sheet.getRange(i + 1, idxHist + 1).setValue(JSON.stringify(arr.slice(-50)));
      }
    } catch(_) {}
    return { ok: true, segmentos: val.segmentos, total: val.segmentos.length };
  }
  return { ok: false, error: 'Producto no encontrado: ' + params.idProducto };
}
