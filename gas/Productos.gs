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
  'MOS_MIGRACION'        // import bulk
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

function crearProductoMaster(params) {
  var bloqueo = _validarSource(params, 'crear', 'PRODUCTOS_MASTER');
  if (bloqueo) return bloqueo;
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
  var unidadMedida = params.Unidad_Medida || 'NIU';
  var unidad = params.unidad || 'NIU';

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

  // Política override (vacío = hereda de categoría)
  var modoOverride  = String(params.modoVenta || '').toUpperCase();
  if (['MARGEN','FIJO','COMPETITIVO','LIBRE'].indexOf(modoOverride) === -1) modoOverride = '';
  var margenOverride = (params.margenPct !== '' && params.margenPct !== undefined && params.margenPct !== null) ? parseFloat(params.margenPct) : '';
  var topeOverride   = (params.precioTope !== '' && params.precioTope !== undefined && params.precioTope !== null) ? parseFloat(params.precioTope) : '';

  var values = [
    id,
    skuBase,
    params.codigoBarra          || '',
    params.descripcion          || '',
    params.marca                || '',
    params.idCategoria          || '',
    unidad,
    parseFloat(params.precioVenta)   || 0,
    parseFloat(params.precioCosto)   || 0,
    codTributo,
    igvPct,
    codSunat,
    tipoIGV,
    unidadMedida,
    '1',
    params.esEnvasable          || '0',
    params.codigoProductoBase   || '',
    factorConv,
    parseFloat(params.factorConversionBase) || '',
    parseFloat(params.mermaEsperadaPct)     || '',
    parseFloat(params.stockMinimo) || 0,
    parseFloat(params.stockMaximo) || 0,
    params.zona                 || '',
    new Date(),
    params.usuario              || '',
    modoOverride,
    isNaN(margenOverride) ? '' : margenOverride,
    isNaN(topeOverride) ? '' : topeOverride
  ];

  // 5. Forzar formato de TEXTO en columnas idProducto (1), skuBase (2), codigoBarra (3)
  // (sino Sheets los convierte a número y se pierden ceros / formato exacto)
  var nextRow = sheet.getLastRow() + 1;
  sheet.getRange(nextRow, 1, 1, 3).setNumberFormat('@STRING@');
  sheet.getRange(nextRow, 1, 1, values.length).setValues([values]);

  if (parseFloat(params.precioVenta) > 0) {
    _registrarHistorialPrecio(id, skuBase, params.codigoBarra || '',
      params.descripcion || '', 0, parseFloat(params.precioVenta),
      params.usuario || '', 'Precio inicial', 'MOS');
  }

  return { ok: true, data: { idProducto: id, skuBase: skuBase, secuencia: seq.secuencia } };
}

function actualizarProductoMaster(params) {
  var bloqueo = _validarSource(params, 'actualizar', 'PRODUCTOS_MASTER');
  if (bloqueo) return bloqueo;
  var sheet = getSheet('PRODUCTOS_MASTER');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];

  for (var i = 1; i < data.length; i++) {
    var match = data[i][0] === params.idProducto || data[i][2] === params.codigoBarra;
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
    // Campos críticos que NUNCA deben sobrescribirse con vacío (defensa contra
    // bugs de frontend que mandan params.skuBase = '' cuando el input no estaba poblado)
    var _camposNoVaciables = ['skuBase', 'codigoBarra', 'descripcion'];
    // Campos que deben preservarse como TEXTO (evitar conversión a número que pierde
    // ceros a la izquierda, formato GS1, etc.)
    var _camposTexto = ['skuBase', 'codigoBarra'];
    campos.forEach(function(campo) {
      if (params[campo] !== undefined) {
        var col = hdrs.indexOf(campo);
        if (col < 0) return;
        // Si es campo crítico y el valor llega vacío, no tocar la celda
        if (_camposNoVaciables.indexOf(campo) >= 0 &&
            (params[campo] === '' || params[campo] === null)) {
          return;
        }
        var cell = sheet.getRange(i + 1, col + 1);
        if (_camposTexto.indexOf(campo) >= 0) {
          // Forzar TEXTO en celdas de identificadores
          cell.setNumberFormat('@STRING@');
          cell.setValue(String(params[campo] || ''));
        } else {
          var val = (_numCampos.indexOf(campo) >= 0 && params[campo] !== '')
            ? parseFloat(params[campo])
            : params[campo];
          cell.setValue(isNaN(val) ? params[campo] : val);
        }
      }
    });

    // Historial si cambió el precio
    if (params.precioVenta !== undefined &&
        parseFloat(params.precioVenta) !== parseFloat(precioAnterior)) {
      _registrarHistorialPrecio(
        data[i][0], data[i][1], data[i][2], data[i][3],
        precioAnterior, params.precioVenta,
        params.usuario || '', params.motivoPrecio || 'Actualización', 'MOS'
      );
    }
    return { ok: true };
  }
  return { ok: false, error: 'Producto no encontrado' };
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
  // Columnas 2 (skuBase) y 3 (codigoBarra) como TEXTO
  sheet.getRange(nextRow, 2, 1, 2).setNumberFormat('@STRING@');
  var values = [id, String(params.skuBase || ''), String(params.codigoBarra || ''), params.descripcion || '', '1'];
  sheet.getRange(nextRow, 1, 1, values.length).setValues([values]);
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
    var campos = ['codigoBarra', 'descripcion', 'activo'];
    campos.forEach(function(c) {
      if (params[c] !== undefined) {
        var col = hdrs.indexOf(c);
        if (col < 0) return;
        var cell = sheet.getRange(i + 1, col + 1);
        // codigoBarra debe ir como TEXTO para preservar ceros / formato
        if (c === 'codigoBarra') {
          cell.setNumberFormat('@STRING@');
          cell.setValue(String(params[c] || ''));
        } else {
          cell.setValue(params[c]);
        }
      }
    });
    return { ok: true };
  }
  return { ok: false, error: 'Equivalencia no encontrada: ' + params.idEquiv };
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

  var res = actualizarProductoMaster({
    _source:      'MOS_MODAL_PRECIO',
    idProducto:   params.idProducto,
    codigoBarra:  params.codigoBarra,
    precioVenta:  _precioNuevo,
    usuario:      params.usuario,
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

  return { ok: true, data: { precioNuevo: params.precioNuevo, alertaGenerada: !!params.imprimirMembretes } };
}

function _registrarHistorialPrecio(idProd, skuBase, codBarra, desc, anterior, nuevo, usuario, motivo, app) {
  var sheet = getSheet('HISTORIAL_PRECIOS');
  var nextRow = sheet.getLastRow() + 1;
  // Columnas 2 (skuBase) y 3 (codigoBarra) deben quedar como TEXTO para preservar
  // ceros a la izquierda y evitar que Sheets las convierta a número.
  sheet.getRange(nextRow, 2, 1, 2).setNumberFormat('@STRING@');
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
