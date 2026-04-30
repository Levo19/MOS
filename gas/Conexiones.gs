// ============================================================
// ProyectoMOS — Conexiones.gs
// Bridge de datos entre MOS y las apps hijas.
//
// ESTRATEGIA:
//  - LECTURA directa por SS_ID (mismo Google account, sin HTTP)
//  - ESCRITURA vía GAS URL (respeta lógica de negocio de cada app)
//
// Para activar warehouseMos:
//   Script Properties de este proyecto → WH_SS_ID + WH_GAS_URL
//
// Para activar MosExpress (Phase 2):
//   Script Properties → ME_SS_ID + ME_GAS_URL
// ============================================================

function _getProp(key) {
  return PropertiesService.getScriptProperties().getProperty(key) || '';
}

function _abrirWhSheet(nombreHoja) {
  var ssId = _getProp('WH_SS_ID');
  if (!ssId) throw new Error('WH_SS_ID no configurado. Ir a Script Properties de ProyectoMOS.');
  return SpreadsheetApp.openById(ssId).getSheetByName(nombreHoja);
}

function _abrirMeSheet(nombreHoja) {
  var ssId = _getProp('ME_SS_ID');
  if (!ssId) throw new Error('ME_SS_ID no configurado (Phase 2 — MosExpress pendiente).');
  return SpreadsheetApp.openById(ssId).getSheetByName(nombreHoja);
}

function _sheetToObjectsLocal(sheet) {
  var data = sheet.getDataRange().getValues();
  if (data.length < 2) return [];
  var headers = data[0];
  return data.slice(1).map(function(row) {
    var obj = {};
    headers.forEach(function(h, i) {
      var v = row[i];
      obj[h] = v instanceof Date ? Utilities.formatDate(v, Session.getScriptTimeZone(), 'yyyy-MM-dd') : v;
    });
    return obj;
  }).filter(function(obj) {
    return Object.values(obj).some(function(v){ return v !== '' && v !== null && v !== undefined; });
  });
}

// ════════════════════════════════════════════════
// LECTURA DESDE warehouseMos
// ════════════════════════════════════════════════

function getStockWarehouse(params) {
  try {
    var stock    = _sheetToObjectsLocal(_abrirWhSheet('STOCK'));
    var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
    var prodMap = {};
    productos.forEach(function(p){ prodMap[p.idProducto] = p; });

    stock = stock.map(function(s) {
      var p = prodMap[s.codigoProducto] || {};
      s.descripcion  = p.descripcion || s.codigoProducto;
      s.skuBase      = p.skuBase     || '';
      s.stockMinimo  = p.stockMinimo || 0;
      s.alertaMinimo = parseFloat(s.cantidadDisponible) < parseFloat(p.stockMinimo || 0);
      return s;
    });

    if (params && params.soloAlertas === 'true') {
      stock = stock.filter(function(s){ return s.alertaMinimo; });
    }
    return { ok: true, data: stock };
  } catch(e) {
    return { ok: false, error: 'warehouseMos no conectado: ' + e.message };
  }
}

function getAlertasWarehouse() {
  try {
    var lotes = _sheetToObjectsLocal(_abrirWhSheet('LOTES_VENCIMIENTO'));
    var hoy   = new Date();
    var diasAlerta = 30;

    lotes.forEach(function(l) {
      if (l.fechaVencimiento && l.estado === 'ACTIVO') {
        l.diasRestantes = Math.ceil((new Date(l.fechaVencimiento) - hoy) / (1000*60*60*24));
      } else {
        l.diasRestantes = 9999;
      }
    });

    var activos = lotes.filter(function(l){
      return l.diasRestantes <= diasAlerta && parseFloat(l.cantidadActual) > 0;
    });
    activos.sort(function(a,b){ return a.diasRestantes - b.diasRestantes; });

    return {
      ok: true,
      data: {
        criticos: activos.filter(function(l){ return l.diasRestantes <= 7; }),
        alertas:  activos.filter(function(l){ return l.diasRestantes > 7; })
      }
    };
  } catch(e) {
    return { ok: false, error: 'warehouseMos no conectado: ' + e.message };
  }
}

function getMermasWarehouse(params) {
  try {
    var rows = _sheetToObjectsLocal(_abrirWhSheet('MERMAS'));
    if (params && params.estado) {
      rows = rows.filter(function(r){ return String(r.estado) === String(params.estado); });
    }
    return { ok: true, data: rows };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

function getEnvasadosWarehouse(params) {
  try {
    var rows = _sheetToObjectsLocal(_abrirWhSheet('ENVASADOS'));
    if (params && params.limit) rows = rows.slice(-parseInt(params.limit));
    return { ok: true, data: rows };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

function getGuiasWarehouse(params) {
  try {
    var rows = _sheetToObjectsLocal(_abrirWhSheet('GUIAS'));
    if (params && params.tipo)   rows = rows.filter(function(r){ return r.tipo === params.tipo; });
    if (params && params.estado) rows = rows.filter(function(r){ return r.estado === params.estado; });
    if (params && params.mes) {
      rows = rows.filter(function(r){ return (r.fecha || '').toString().startsWith(params.mes); });
    }
    return { ok: true, data: rows };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// ════════════════════════════════════════════════
// LECTURA DESDE MosExpress (Phase 2)
// ════════════════════════════════════════════════

function getVentasMosExpress(params) {
  try {
    var ventas = _sheetToObjectsLocal(_abrirMeSheet('VENTAS_CABECERA'));
    if (params && params.fecha) {
      ventas = ventas.filter(function(v){ return (String(v.Fecha || '')).startsWith(params.fecha); });
    }
    return { ok: true, data: ventas };
  } catch(e) {
    return { ok: false, error: 'MosExpress no conectado: ' + e.message };
  }
}

// ════════════════════════════════════════════════
// ANÁLISIS CRUZADO
// ════════════════════════════════════════════════

// Rotación = ventas del mes / stock actual → días de cobertura
function getRotacionProductos(params) {
  try {
    var stockRes = getStockWarehouse(params || {});
    if (!stockRes.ok) return stockRes;

    var ventasMap = {};
    try {
      var mes = params && params.mes
        ? params.mes  // 'YYYY-MM'
        : Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM');

      // Leer VENTAS_DETALLE (nivel ítem) para rotación por producto
      var detalleSheet = _abrirMeSheet('VENTAS_DETALLE');
      var detalles = _sheetToObjectsLocal(detalleSheet).filter(function(v) {
        return (String(v.Fecha_Venta || v.Fecha || '')).startsWith(mes) ||
               true; // VENTAS_DETALLE no tiene fecha propia, se filtra por join con cabecera
      });
      // Fallback: usar la cabecera si no hay fecha en detalle
      var ventasRes = getVentasMosExpress({ fecha: mes });
      var ventasIds = {};
      if (ventasRes.ok) {
        ventasRes.data.forEach(function(v){ ventasIds[v.ID_Venta] = true; });
      }
      detalles.forEach(function(v) {
        if (!ventasIds[v.ID_Venta] && ventasRes.ok && ventasRes.data.length) return;
        var key = String(v.SKU || '');
        if (!ventasMap[key]) ventasMap[key] = 0;
        ventasMap[key] += parseFloat(v.Cantidad || 0);
      });
    } catch(e) {
      // MosExpress no conectado aún — rotación sin ventas
    }

    var rotacion = stockRes.data.map(function(s) {
      var vendidasMes = ventasMap[s.skuBase] || ventasMap[s.codigoProducto] || 0;
      var diasCobertura = vendidasMes > 0
        ? Math.round(parseFloat(s.cantidadDisponible) / vendidasMes * 30)
        : null;
      return {
        codigoProducto: s.codigoProducto,
        descripcion:    s.descripcion,
        skuBase:        s.skuBase,
        stockActual:    s.cantidadDisponible,
        vendidasMes:    vendidasMes,
        diasCobertura:  diasCobertura,
        alertaMinimo:   s.alertaMinimo
      };
    });

    // Más críticos primero (menos cobertura)
    rotacion.sort(function(a, b) {
      var da = a.diasCobertura === null ? 9999 : a.diasCobertura;
      var db = b.diasCobertura === null ? 9999 : b.diasCobertura;
      return da - db;
    });

    return { ok: true, data: rotacion };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// ════════════════════════════════════════════════
// ANALÍTICA DE PRODUCTO — datos agregados para dashboard
// ════════════════════════════════════════════════

function getAnaliticaProducto(params) {
  if (!params.idProducto && !params.codigoBarra && !params.skuBase) {
    return { ok: false, error: 'Requiere idProducto' };
  }

  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var prod = null;

  // Buscar por idProducto primero, luego por skuBase (base), luego codigoBarra
  if (params.idProducto) {
    prod = productos.find(function(p){ return p.idProducto === params.idProducto; });
    // Si es una presentación, subir al base
    if (prod && prod.skuBase && prod.skuBase !== prod.idProducto) {
      var base = productos.find(function(p){ return p.idProducto === prod.skuBase; });
      if (base) prod = base;
    }
  }
  if (!prod && params.codigoBarra) {
    prod = productos.find(function(p){ return p.codigoBarra === params.codigoBarra; });
  }
  if (!prod) return { ok: false, error: 'Producto no encontrado' };

  var skuBase  = prod.skuBase || prod.idProducto;
  var dias     = parseInt(params.dias) || 30;
  var hoy      = new Date();
  var desdeMs  = hoy.getTime() - dias * 86400000;
  var desdeStr = Utilities.formatDate(new Date(desdeMs), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  var tz       = Session.getScriptTimeZone();

  // Todos los codigosBarra del grupo (base + presentaciones)
  var cbGrupo = productos
    .filter(function(p){ return p.skuBase === skuBase || p.idProducto === skuBase; })
    .map(function(p){ return p.codigoBarra; })
    .filter(Boolean);

  // ── Ventas desde ME ──────────────────────────────────────────
  var ventasDiarias = {};
  var totalUnidades = 0, totalImporte = 0;
  var meConectado   = false;

  // Leer VENTAS_DETALLE de ME (ítem por ítem — campos: SKU, Cod_Barras, Cantidad, Precio, ID_Venta)
  // Para obtener la fecha cruzamos con VENTAS_CABECERA por ID_Venta
  try {
    var detalles  = _sheetToObjectsLocal(_abrirMeSheet('VENTAS_DETALLE'));
    var cabeceras = _sheetToObjectsLocal(_abrirMeSheet('VENTAS_CABECERA'));
    meConectado = true;

    // Mapa ID_Venta → Fecha (yyyy-MM-dd)
    var fechaMap = {};
    cabeceras.forEach(function(c) {
      var f = String(c.Fecha || '').substring(0, 10);
      if (f >= desdeStr && c.Estado_Envio !== 'ANULADO') fechaMap[c.ID_Venta] = f;
    });

    detalles.forEach(function(v) {
      var fecha = fechaMap[v.ID_Venta];
      if (!fecha) return; // venta fuera del período o anulada
      var sku = String(v.SKU || '');
      var cb  = String(v.Cod_Barras || '');
      var match = sku === skuBase || cbGrupo.indexOf(cb) >= 0 || cbGrupo.indexOf(sku) >= 0;
      if (!match) return;
      if (!ventasDiarias[fecha]) ventasDiarias[fecha] = { u: 0, imp: 0 };
      var qty    = parseFloat(v.Cantidad || 0);
      var precio = parseFloat(v.Precio || prod.precioVenta || 0);
      ventasDiarias[fecha].u   += qty;
      ventasDiarias[fecha].imp += parseFloat(v.Subtotal || qty * precio);
      totalUnidades += qty;
      totalImporte  += parseFloat(v.Subtotal || qty * precio);
    });
  } catch(e) { /* ME no conectado */ }

  // Serie completa con ceros para días sin ventas
  var ventasSerie = [];
  for (var d = 0; d < dias; d++) {
    var dd = Utilities.formatDate(new Date(desdeMs + d * 86400000), tz, 'yyyy-MM-dd');
    ventasSerie.push({ fecha: dd, u: (ventasDiarias[dd] || {}).u || 0, imp: (ventasDiarias[dd] || {}).imp || 0 });
  }

  // ── Stock desde WH ───────────────────────────────────────────
  var stockTotal  = 0;
  var stockZonas  = [];
  var whConectado = false;
  try {
    var stockRes = getStockWarehouse({});
    if (stockRes.ok) {
      whConectado = true;
      stockZonas = stockRes.data.filter(function(s){
        return s.codigoProducto === prod.idProducto || s.skuBase === skuBase;
      });
      stockTotal = stockZonas.reduce(function(a, s){ return a + parseFloat(s.cantidadDisponible || 0); }, 0);
    }
  } catch(e) {}

  // ── Historial de precios ─────────────────────────────────────
  var histPrecios = _sheetToObjects(getSheet('HISTORIAL_PRECIOS'))
    .filter(function(h){ return h.idProducto === prod.idProducto || h.skuBase === skuBase; })
    .sort(function(a, b){ return String(a.fecha) < String(b.fecha) ? -1 : 1; })
    .slice(-20);

  // ── Pedidos de compra que incluyen este producto ─────────────
  var pedidosTodos  = _sheetToObjects(getSheet('PEDIDOS_PROVEEDOR'));
  var pedidosProd   = [];
  var provIdsMap    = {};

  pedidosTodos.forEach(function(ped) {
    try {
      var items = typeof ped.items === 'string' ? JSON.parse(ped.items) : (ped.items || []);
      var item  = null;
      for (var i = 0; i < items.length; i++) {
        if (items[i].idProducto === prod.idProducto ||
            items[i].skuBase    === skuBase ||
            cbGrupo.indexOf(items[i].codigoBarra || '') >= 0) {
          item = items[i]; break;
        }
      }
      if (!item) return;
      var fechaPed = String(ped.createdAt || ped.fecha || '').substring(0, 10);
      pedidosProd.push({
        idPedido:    ped.idPedido,
        idProveedor: ped.idProveedor,
        fecha:       fechaPed,
        cantidad:    parseFloat(item.cantidad || 0),
        costo:       parseFloat(item.costoUnitario || item.costo || item.precio || 0),
        estado:      ped.estado
      });
      if (ped.idProveedor) provIdsMap[ped.idProveedor] = true;
    } catch(e2) {}
  });

  // Ordenar por fecha más reciente
  pedidosProd.sort(function(a, b){ return b.fecha > a.fecha ? 1 : -1; });

  var todosProv = _sheetToObjects(getSheet('PROVEEDORES_MASTER'));
  var proveedores = todosProv.filter(function(p){ return provIdsMap[p.idProveedor]; })
    .map(function(p){ return { idProveedor: p.idProveedor, nombre: p.nombre, formaPago: p.formaPago }; });

  // ── Proyección ───────────────────────────────────────────────
  var promDia        = dias > 0 ? totalUnidades / dias : 0;
  var proyec30       = Math.ceil(promDia * 30);
  var coberturaDias  = promDia > 0 ? Math.round(stockTotal / promDia) : null;
  var sugerirComprar = Math.max(0, proyec30 - stockTotal);

  // ── Rentabilidad ─────────────────────────────────────────────
  var costo        = parseFloat(prod.precioCosto || 0);
  var precio       = parseFloat(prod.precioVenta || 0);
  var margenPct    = precio > 0 ? (precio - costo) / precio * 100 : 0;
  var utilidad     = totalImporte - totalUnidades * costo;

  return {
    ok: true,
    data: {
      producto: {
        idProducto:  prod.idProducto,
        descripcion: prod.descripcion || '—',
        codigoBarra: prod.codigoBarra || '',
        skuBase:     skuBase,
        precioVenta: precio,
        precioCosto: costo,
        stockMinimo: parseFloat(prod.stockMinimo || 0),
        stockMaximo: parseFloat(prod.stockMaximo || 0),
        unidad:      prod.unidad || 'UND',
        idCategoria: prod.idCategoria || ''
      },
      periodo:   { dias: dias, desde: desdeStr },
      ventas:    { serie: ventasSerie, totalUnidades: totalUnidades, totalImporte: totalImporte, promDia: promDia },
      stock:     { total: stockTotal, zonas: stockZonas, minimo: parseFloat(prod.stockMinimo || 0), maximo: parseFloat(prod.stockMaximo || 0) },
      financiero: { margenPct: margenPct, utilidadBruta: utilidad, precioVenta: precio, precioCosto: costo },
      compras:   { pedidos: pedidosProd.slice(0, 20), proveedores: proveedores },
      historialPrecios: histPrecios,
      proyeccion: { promDia: promDia, unidades30dias: proyec30, coberturaDias: coberturaDias, sugerirComprar: sugerirComprar },
      conexiones: { me: meConectado, wh: whConectado }
    }
  };
}

// ════════════════════════════════════════════════
// PRODUCTOS NUEVOS (desde warehouseMos)
// ════════════════════════════════════════════════

function getProductosNuevosWarehouse(params) {
  try {
    var pns = _sheetToObjectsLocal(_abrirWhSheet('PRODUCTO_NUEVO'));
    if (params && params.estado) {
      pns = pns.filter(function(p){ return String(p.estado) === String(params.estado); });
    } else {
      pns = pns.filter(function(p){ return String(p.estado) === 'PENDIENTE'; });
    }

    // Enriquecer con guía origen
    var guias = [];
    try { guias = _sheetToObjectsLocal(_abrirWhSheet('GUIAS')); } catch(e) {}
    var guiaMap = {};
    guias.forEach(function(g){ guiaMap[g.idGuia] = g; });

    pns = pns.map(function(pn) {
      var g = pn.idGuia ? guiaMap[pn.idGuia] : null;
      return {
        idProductoNuevo:  pn.idProductoNuevo,
        codigoBarra:      String(pn.codigoBarra  || ''),
        descripcion:      String(pn.descripcion  || ''),
        marca:            String(pn.marca        || ''),
        idCategoria:      String(pn.idCategoria  || ''),
        unidad:           String(pn.unidad       || ''),
        cantidad:         pn.cantidad            || 0,
        fechaVencimiento: String(pn.fechaVencimiento || ''),
        foto:             String(pn.foto         || ''),
        estado:           String(pn.estado       || ''),
        usuario:          String(pn.usuario      || ''),
        fechaRegistro:    String(pn.fechaRegistro || ''),
        idGuia:           String(pn.idGuia       || ''),
        guia: g ? { idGuia: g.idGuia, tipo: g.tipo, estado: g.estado, fecha: g.fecha } : null
      };
    });

    return { ok: true, data: pns };
  } catch(e) {
    return { ok: false, error: 'warehouseMos no conectado: ' + e.message };
  }
}

function lanzarProductoNuevo(params) {
  var tipo = String(params.tipo || 'NUEVO').toUpperCase();
  var idProductoCreado = '';
  var idEquivCreado    = '';

  if (tipo === 'NUEVO') {
    // 1. Crear en PRODUCTOS_MASTER de MOS
    var resultCrear = crearProductoMaster({
      codigoBarra:        params.codigoFinal        || '',
      descripcion:        params.descripcion        || '',
      marca:              params.marca              || '',
      idCategoria:        params.idCategoria        || '',
      unidad:             params.unidad             || 'UNIDAD',
      Tipo_IGV:           params.Tipo_IGV           || '1',
      precioVenta:        parseFloat(params.precioVenta) || 0,
      precioCosto:        parseFloat(params.precioCosto) || 0,
      stockMinimo:        parseFloat(params.stockMinimo) || 0,
      stockMaximo:        parseFloat(params.stockMaximo) || 0,
      esEnvasable:        params.esEnvasable        || '0',
      codigoProductoBase: params.codigoProductoBase || '',
      factorConversion:   params.factorConversion   || '',
      mermaEsperadaPct:   params.mermaEsperadaPct   || '',
      zona:               params.zona               || '',
      usuario:            params.usuario            || 'MOS'
    });
    if (!resultCrear.ok) return resultCrear;
    idProductoCreado = resultCrear.data.idProducto;
  } else if (tipo === 'EQUIVALENTE') {
    // 1. Crear en EQUIVALENCIAS de MOS
    var resultEq = crearEquivalencia({
      skuBase:     params.skuBase,
      codigoBarra: params.codigoFinal || '',
      descripcion: params.descripcionEquiv || params.descripcion || ''
    });
    if (!resultEq || !resultEq.ok) return { ok: false, error: (resultEq && resultEq.error) || 'Error creando equivalencia' };
    idEquivCreado = resultEq.data && resultEq.data.idEquiv;
  } else {
    return { ok: false, error: 'tipo inválido (NUEVO o EQUIVALENTE)' };
  }

  // 2. Notificar a warehouseMos: actualizar GUIA_DETALLE + STOCK + marcar PN APROBADO
  var whResult = postToWarehouse('aprobarProductoNuevo', {
    idProductoNuevo: params.idProductoNuevo,
    idGuia:          params.idGuia,
    codigoOriginal:  params.codigoOriginal,
    codigoFinal:     params.codigoFinal,
    cantidadFinal:   parseFloat(params.cantidadFinal) || 0,
    tipo:            tipo,
    skuBase:         params.skuBase || '',  // solo en EQUIVALENTE
    aprobadoPor:     params.aprobadoPor || params.usuario || 'MOS',
    descripcion:     params.descripcion,
    idCategoria:     params.idCategoria || '',
    unidad:          params.unidad || 'UNIDAD',
    idProducto:      idProductoCreado
  });

  return {
    ok: true,
    data: {
      tipo:           tipo,
      idProducto:     idProductoCreado,
      idEquiv:        idEquivCreado,
      aprobadoEnWH:   whResult.ok,
      whError:        whResult.ok ? '' : (whResult.error || '')
    }
  };
}

// ════════════════════════════════════════════════
// ESCRITURA HACIA warehouseMos (vía GAS URL)
// Usar solo cuando la operación debe pasar por
// la lógica de negocio de warehouseMos
// ════════════════════════════════════════════════

function postToWarehouse(action, params) {
  var url = _getProp('WH_GAS_URL');
  if (!url) return { ok: false, error: 'WH_GAS_URL no configurado' };
  try {
    var payload = JSON.stringify(Object.assign({ action: action }, params));
    var res = UrlFetchApp.fetch(url, {
      method: 'post',
      contentType: 'text/plain',
      payload: payload,
      muteHttpExceptions: true
    });
    return JSON.parse(res.getContentText());
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// ════════════════════════════════════════════════
// GESTIÓN DE CONEXIONES
// ════════════════════════════════════════════════

function getConexiones() {
  return { ok: true, data: _sheetToObjects(getSheet('CONEXIONES')) };
}

function setConexion(params) {
  var sheet = getSheet('CONEXIONES');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];

  for (var i = 1; i < data.length; i++) {
    if (data[i][0] !== params.idApp) continue;

    if (params.gasUrl) sheet.getRange(i+1, hdrs.indexOf('gasUrl')+1).setValue(params.gasUrl);
    if (params.ssId)   sheet.getRange(i+1, hdrs.indexOf('ssId')+1).setValue(params.ssId);
    if (params.activo !== undefined) sheet.getRange(i+1, hdrs.indexOf('activo')+1).setValue(params.activo);
    sheet.getRange(i+1, hdrs.indexOf('ultimaSync')+1).setValue(new Date());

    // Sincronizar también en Script Properties para acceso directo
    var propMap = {
      warehouseMos: { gasUrl: 'WH_GAS_URL', ssId: 'WH_SS_ID' },
      mosExpress:   { gasUrl: 'ME_GAS_URL', ssId: 'ME_SS_ID' }
    };
    var props = propMap[params.idApp];
    if (props) {
      var updates = {};
      if (params.gasUrl) updates[props.gasUrl] = params.gasUrl;
      if (params.ssId)   updates[props.ssId]   = params.ssId;
      if (Object.keys(updates).length) {
        PropertiesService.getScriptProperties().setProperties(updates);
      }
    }
    return { ok: true };
  }
  return { ok: false, error: 'Conexión no encontrada: ' + params.idApp };
}

// ════════════════════════════════════════════════
// ESTADO OPERACIONAL DEL ECOSISTEMA
// Devuelve snapshot en tiempo real de cada app hija.
// Verde  = datos accesibles + actividad hoy
// Amarillo = datos accesibles pero sin actividad hoy
// Rojo   = no se puede leer el sheet (sin configurar o error)
// ════════════════════════════════════════════════
function getEcoStatus() {
  var tz  = Session.getScriptTimeZone();
  var hoy = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd');
  var resultado = { ok: true, me: null, wh: null };

  // ── MosExpress ───────────────────────────────
  try {
    var meSsId = _getProp('ME_SS_ID');
    if (!meSsId) throw new Error('ME_SS_ID no configurado');

    var meSS = SpreadsheetApp.openById(meSsId);

    // Helper: busca columna ignorando mayúsculas, guiones y espacios
    function _findCol(hdrs, targets) {
      var idx = -1;
      targets.forEach(function(t) {
        if (idx >= 0) return;
        var tNorm = t.toLowerCase().replace(/[_\s-]/g, '');
        idx = hdrs.findIndex(function(h) {
          return h.toLowerCase().replace(/[_\s-]/g, '') === tNorm;
        });
      });
      return idx;
    }

    // ── Mapas desde ZONAS_CONFIG (vive en ME) ──────
    // serieZonaMap: { 'NV01': 'ZONA-01', 'NV02': 'ZONA-02', 'B001': 'ZONA-01', ... }
    // estZonaMap:   { 'Caja Central 01': 'ZONA-01', 'Pasillo Pedidos': 'ZONA-02', ... }
    var serieZonaMap = {};
    var estZonaMap   = {};
    var zonasSheet = meSS.getSheetByName('ZONAS_CONFIG');
    if (zonasSheet) {
      var zData = zonasSheet.getDataRange().getValues();
      var zHdrs = zData[0].map(function(h){ return String(h).trim(); });
      var zIdIdx     = _findCol(zHdrs, ['Zona_ID','ZonaID','zona']);
      var zEstIdx    = _findCol(zHdrs, ['Estacion_Nombre','Estacion','estacion']);
      var zSerNVIdx  = _findCol(zHdrs, ['Serie_Nota','SerieNota','serie_nota']);
      var zSerBIdx   = _findCol(zHdrs, ['Serie_Boleta','SerieBoleta','serie_boleta']);
      var zSerFIdx   = _findCol(zHdrs, ['Serie_Factura','SerieFactura','serie_factura']);
      for (var z = 1; z < zData.length; z++) {
        var zId  = String(zData[z][zIdIdx]  || '').trim();
        if (!zId) continue;
        // Serie_Nota, Serie_Boleta, Serie_Factura → todos mapean a la misma zona
        [zSerNVIdx, zSerBIdx, zSerFIdx].forEach(function(idx) {
          if (idx < 0) return;
          var serie = String(zData[z][idx] || '').trim();
          if (serie && !serieZonaMap[serie]) serieZonaMap[serie] = zId;
        });
        // Estación → zona (sin duplicar si ya existe)
        if (zEstIdx >= 0) {
          var est = String(zData[z][zEstIdx] || '').trim();
          if (est && !estZonaMap[est]) estZonaMap[est] = zId;
        }
      }
    }

    // Helper: obtiene zona del correlativo (ej: 'NV02-000001' → 'ZONA-02')
    function _zonaDeCorrelativo(correlativo) {
      if (!correlativo) return null;
      var serie = String(correlativo).split('-')[0].trim();
      return serieZonaMap[serie] || null;
    }

    // ── Ventas de hoy, agrupadas por zona ────────
    var ventasSheet = meSS.getSheetByName('VENTAS_CABECERA');
    var ventasHoy = 0, totalHoy = 0, ultimaVenta = null, ultimaHace = null;
    var zonaVentasMap = {};

    if (ventasSheet) {
      var vData = ventasSheet.getDataRange().getValues();
      var vHdrs = vData[0].map(function(h){ return String(h).trim(); });
      var vFechaIdx  = _findCol(vHdrs, ['Fecha','fecha']);
      var vTotalIdx  = _findCol(vHdrs, ['Total','total']);
      var vEstadoIdx = _findCol(vHdrs, ['Estado_Envio','EstadoEnvio','Estado','estado']);
      var vCorrIdx   = _findCol(vHdrs, ['Correlativo','correlativo']);
      var vEstIdx    = _findCol(vHdrs, ['Estacion','estacion']);

      for (var i = vData.length - 1; i >= 1; i--) {
        var fRaw = vData[i][vFechaIdx];
        if (!fRaw) continue;
        var fStr = fRaw instanceof Date
          ? Utilities.formatDate(fRaw, tz, 'yyyy-MM-dd')
          : String(fRaw).substring(0, 10);
        if (fStr !== hoy) continue;
        var estado = vEstadoIdx >= 0 ? String(vData[i][vEstadoIdx] || '') : '';
        if (estado === 'ANULADO') continue;

        // Zona: primero por correlativo, luego por estación
        var corr  = vCorrIdx  >= 0 ? String(vData[i][vCorrIdx]  || '') : '';
        var estV  = vEstIdx   >= 0 ? String(vData[i][vEstIdx]   || '').trim() : '';
        var zona  = _zonaDeCorrelativo(corr) || estZonaMap[estV] || 'Sin zona';

        if (!zonaVentasMap[zona]) zonaVentasMap[zona] = { ventas: 0, total: 0, ultimaVenta: null };
        zonaVentasMap[zona].ventas++;
        zonaVentasMap[zona].total += parseFloat(vData[i][vTotalIdx] || 0);
        if (!zonaVentasMap[zona].ultimaVenta && fRaw instanceof Date) zonaVentasMap[zona].ultimaVenta = fRaw;

        ventasHoy++;
        totalHoy += parseFloat(vData[i][vTotalIdx] || 0);
        if (!ultimaVenta && fRaw instanceof Date) ultimaVenta = fRaw;
      }
      if (ultimaVenta) {
        var diffMin = Math.round((new Date() - ultimaVenta) / 60000);
        ultimaHace = diffMin < 60 ? 'hace ' + diffMin + ' min' : 'hace ' + Math.round(diffMin / 60) + 'h';
      }
    }

    // Convertir a array ordenado por total desc
    var zonas = Object.keys(zonaVentasMap).map(function(z) {
      var zm = zonaVentasMap[z];
      var diffZ = zm.ultimaVenta ? Math.round((new Date() - zm.ultimaVenta) / 60000) : null;
      var uv = diffZ !== null
        ? (diffZ < 60 ? 'hace ' + diffZ + ' min' : 'hace ' + Math.round(diffZ/60) + 'h')
        : 'Sin ventas';
      return { zona: z, ventas: zm.ventas, total: Math.round(zm.total * 100) / 100, ultimaVenta: uv };
    }).sort(function(a, b){ return b.total - a.total; });

    // ── Personal del día (todas las cajas de hoy) ─
    var cajasSheet = meSS.getSheetByName('CAJAS');
    var personalHoy = [];

    if (cajasSheet) {
      var cData = cajasSheet.getDataRange().getValues();
      var cHdrs = cData[0].map(function(h){ return String(h).trim(); });
      var cNomIdx    = _findCol(cHdrs, ['Vendedor','Cajero']);           if (cNomIdx    < 0) cNomIdx    = 1;
      var cEstIdx    = _findCol(cHdrs, ['Estacion']);                    if (cEstIdx    < 0) cEstIdx    = 2;
      var cAperIdx   = _findCol(cHdrs, ['Fecha_Apertura']);              if (cAperIdx   < 0) cAperIdx   = 3;
      var cCierIdx   = _findCol(cHdrs, ['Fecha_Cierre','Fecha_cierre']);
      var cEstadoIdx = _findCol(cHdrs, ['Estado']);                      if (cEstadoIdx < 0) cEstadoIdx = 5;
      var cZonaIdx   = _findCol(cHdrs, ['Zona_ID','ZonaID','Zona']);

      for (var c = 1; c < cData.length; c++) {
        var fAp = cData[c][cAperIdx];
        if (!fAp) continue;
        var diaAp = fAp instanceof Date
          ? Utilities.formatDate(fAp, tz, 'yyyy-MM-dd') : String(fAp).substring(0, 10);
        if (diaAp !== hoy) continue;

        var aperHora   = fAp instanceof Date ? Utilities.formatDate(fAp, tz, 'HH:mm') : '--:--';
        var estadoCaja = String(cData[c][cEstadoIdx] || '').toUpperCase();
        var cierreHora = '';
        if (cCierIdx >= 0 && cData[c][cCierIdx] instanceof Date) {
          cierreHora = Utilities.formatDate(cData[c][cCierIdx], tz, 'HH:mm');
        }

        // Zona: columna directa → fallback por estación en ZONAS_CONFIG
        var zonaRaw = cZonaIdx >= 0 ? String(cData[c][cZonaIdx] || '').trim() : '';
        var estCaja  = String(cData[c][cEstIdx] || '').trim();
        var zonaCaja = zonaRaw || estZonaMap[estCaja] || '—';

        personalHoy.push({
          nombre:   String(cData[c][cNomIdx] || '—').trim(),
          estacion: estCaja,
          zona:     zonaCaja,
          estado:   estadoCaja === 'ABIERTA' ? 'activo' : 'cerrado',
          desde:    aperHora,
          hasta:    cierreHora
        });
      }
      personalHoy.sort(function(a, b){
        if (a.estado !== b.estado) return a.estado === 'activo' ? -1 : 1;
        return a.desde < b.desde ? -1 : 1;
      });
    }

    var meActivo = ventasHoy > 0 || personalHoy.some(function(p){ return p.estado === 'activo'; });
    resultado.me = {
      color:       meActivo ? 'green' : 'yellow',
      ventasHoy:   ventasHoy,
      totalHoy:    Math.round(totalHoy * 100) / 100,
      ultimaVenta: ultimaHace || (ventasHoy > 0 ? 'hoy' : 'Sin ventas hoy'),
      zonas:       zonas,
      personal:    personalHoy,
      error:       null
    };

  } catch(e) {
    resultado.me = { color: 'red', error: e.message };
  }

  // ── warehouseMos ─────────────────────────────
  try {
    var whSsId = _getProp('WH_SS_ID');
    if (!whSsId) throw new Error('WH_SS_ID no configurado');

    var whSS = SpreadsheetApp.openById(whSsId);

    // Guías del día
    var guiasSheet = whSS.getSheetByName('GUIAS');
    var entradasHoy = 0, salidasHoy = 0, ultimaGuia = null, ultimaGuiaHace = null;
    if (guiasSheet) {
      var gData = guiasSheet.getDataRange().getValues();
      var gHdrs = gData[0].map(function(h){ return String(h).trim(); });
      var gFIdx = gHdrs.indexOf('Fecha');
      var gTIdx = gHdrs.indexOf('Tipo');
      for (var g = gData.length - 1; g >= 1; g--) {
        var gf = gData[g][gFIdx];
        if (!gf) continue;
        var gfStr = gf instanceof Date
          ? Utilities.formatDate(gf, tz, 'yyyy-MM-dd') : String(gf).substring(0, 10);
        if (gfStr !== hoy) continue;
        var tipo = String(gData[g][gTIdx] || '').toUpperCase();
        if (tipo.includes('ENTRADA') || tipo.includes('INGRESO')) entradasHoy++;
        else salidasHoy++;
        if (!ultimaGuia && gf instanceof Date) ultimaGuia = gf;
      }
      if (ultimaGuia) {
        var gdiff = Math.round((new Date() - ultimaGuia) / 60000);
        ultimaGuiaHace = gdiff < 60 ? 'hace ' + gdiff + ' min' : 'hace ' + Math.round(gdiff/60) + 'h';
      }
    }

    // Sesión activa
    var sesionActiva = null;
    var sesSheet = whSS.getSheetByName('SESIONES');
    if (sesSheet) {
      var sData = sesSheet.getDataRange().getValues();
      var sHdrs = sData[0].map(function(h){ return String(h).trim(); });
      var sEstIdx  = sHdrs.indexOf('estado');
      var sUsrIdx  = sHdrs.indexOf('usuario');
      var sRolIdx  = sHdrs.indexOf('rol');
      var sEntIdx  = sHdrs.indexOf('entrada');
      for (var s = sData.length - 1; s >= 1; s--) {
        if (String(sData[s][sEstIdx] || '').toUpperCase() === 'ACTIVA') {
          var sEnt = sData[s][sEntIdx];
          var sEntHora = sEnt instanceof Date ? Utilities.formatDate(sEnt, tz, 'HH:mm') : '--:--';
          sesionActiva = {
            usuario: String(sData[s][sUsrIdx] || ''),
            rol:     String(sData[s][sRolIdx] || ''),
            desde:   sEntHora
          };
          break;
        }
      }
    }

    // Stock crítico (alertaMinimo)
    var stockCritico = 0;
    try {
      var stockRes = getStockWarehouse({});
      if (stockRes.ok) stockCritico = stockRes.data.filter(function(s){ return s.alertaMinimo; }).length;
    } catch(e2) {}

    var whActivo = entradasHoy > 0 || salidasHoy > 0 || sesionActiva !== null;
    resultado.wh = {
      color:          whActivo ? 'green' : 'yellow',
      entradasHoy:    entradasHoy,
      salidasHoy:     salidasHoy,
      ultimaGuia:     ultimaGuiaHace || (entradasHoy + salidasHoy > 0 ? 'hoy' : 'Sin guías hoy'),
      sesionActiva:   sesionActiva,
      stockCritico:   stockCritico,
      error:          null
    };

  } catch(e) {
    resultado.wh = { color: 'red', error: e.message };
  }

  return { ok: true, data: resultado };
}
