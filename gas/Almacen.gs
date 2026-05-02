// ============================================================
// ProyectoMOS — Almacen.gs
// Endpoints unificados de almacén/stock que combinan datos de:
//  · WH (warehouseMos) — STOCK central, GUIAS, PREINGRESOS, MERMAS, ENVASADOS
//  · ME (MosExpress)   — STOCK_ZONAS, VENTAS_CABECERA, VENTAS_DETALLE
//  · MOS               — PRODUCTOS_MASTER (catálogo), ESTACIONES (zonas)
//
// Cache: usa CacheService (memoria) con TTL configurable. Bypass con _refresh=true
// ============================================================

// ── EQUIVALENCIAS HELPER ─────────────────────────────────────────
// Lee EQUIVALENCIAS activas y devuelve { skuBase: [codigoBarra1, codigoBarra2, ...] }
// + lookup inverso { codigoBarra: skuBase } para mapeo rápido
function _readEquivalencias() {
  var map = {};        // skuBase → [cb, cb, ...]
  var inverse = {};    // cb → skuBase
  try {
    var data = _sheetToObjects(getSheet('EQUIVALENCIAS'));
    data.forEach(function(e) {
      if (!e.skuBase || !e.codigoBarra) return;
      var ac = e.activo;
      var activo = (ac === undefined || ac === '' || ac === 1 || ac === '1' ||
                    ac === true || String(ac).toLowerCase() === 'true');
      if (!activo) return;
      var sku = String(e.skuBase).trim();
      var cb  = String(e.codigoBarra).trim();
      if (!map[sku]) map[sku] = [];
      map[sku].push({ codigoBarra: cb, idEquiv: e.idEquiv || '', descripcion: e.descripcion || '' });
      inverse[cb] = sku;
    });
  } catch(_){}
  return { porSku: map, porCb: inverse };
}

// ── ZONA RESOLVER ────────────────────────────────────────────────
// Normaliza cualquier identificador de zona (Zona_ID, idEstacion, nombre)
// a un canónico { id, nombre } único. Usa SOLO datos reales:
//   1. Tabla ZONAS (idZona → nombre)
//   2. Tabla ESTACIONES (mapea idEstacion/nombre → idZona padre)
//   3. Fallback: usa el valor crudo como id Y nombre (no inventa)
function _buildZonaResolver() {
  var zonas      = _sheetToObjects(getSheet('ZONAS'));
  var estaciones = _sheetToObjects(getSheet('ESTACIONES'));
  var map = {};   // clave normalizada → { id, nombre }

  function _variantes(k) {
    return [k, k.toUpperCase(), k.toLowerCase(),
            k.replace(/[\s_-]+/g, ''),
            k.replace(/[\s_-]+/g, '').toUpperCase(),
            k.replace(/[\s_-]+/g, '').toLowerCase()];
  }
  function setKey(rawKey, canonId, canonName) {
    if (!rawKey) return;
    var k = String(rawKey).trim();
    if (!k) return;
    _variantes(k).forEach(function(v){
      if (!map[v]) map[v] = { id: canonId, nombre: canonName };
    });
  }

  // 1. ZONAS — fuente principal de nombres
  zonas.forEach(function(z) {
    if (!z.idZona) return;
    var canonId = String(z.idZona).trim().toUpperCase();
    var canonName = z.nombre || z.idZona;
    setKey(z.idZona, canonId, canonName);
    setKey(z.nombre, canonId, canonName);
  });

  // 2. ESTACIONES — mapean al idZona padre (sin inventar nombre)
  // Solo agregamos rutas de búsqueda, no creamos zonas nuevas.
  estaciones.forEach(function(e) {
    if (!e.idZona) return;
    var idZ = String(e.idZona).trim().toUpperCase();
    // Si ya existe en map (vino de ZONAS), usar su nombre. Si no, usar idZona crudo.
    var existing = map[idZ];
    var nombreZona = existing ? existing.nombre : e.idZona;
    setKey(e.idZona,     idZ, nombreZona);
    setKey(e.nombre,     idZ, nombreZona);
    setKey(e.idEstacion, idZ, nombreZona);
  });

  return {
    resolve: function(raw) {
      if (!raw) return null;
      var k = String(raw).trim();
      if (!k) return null;
      var variants = _variantes(k);
      for (var i = 0; i < variants.length; i++) {
        if (map[variants[i]]) return map[variants[i]];
      }
      // Sin match: id = uppercase del raw, nombre = raw tal cual viene
      return { id: k.toUpperCase(), nombre: k };
    }
  };
}

// ── CACHE HELPER ────────────────────────────────────────────────
// CacheService limit: 100 KB por key, 10 MB total. Para responses
// pequeños es perfecto. Si necesitamos algo más grande, hacer chunking.
function _almCached(key, ttlSec, params, fn) {
  // Bypass: si params._refresh === true, ignora cache y refresca
  if (params && (params._refresh === true || params._refresh === 'true')) {
    var fresh = fn();
    _almCachePut(key, fresh, ttlSec);
    return fresh;
  }
  var cached = _almCacheGet(key);
  if (cached) return cached;
  var result = fn();
  _almCachePut(key, result, ttlSec);
  return result;
}
function _almCacheGet(key) {
  try {
    var cache = CacheService.getScriptCache();
    var raw = cache.get('ALM_' + key);
    if (!raw) return null;
    return JSON.parse(raw);
  } catch(_) { return null; }
}
function _almCachePut(key, value, ttlSec) {
  try {
    if (!value || value.ok === false) return;
    var raw = JSON.stringify(value);
    if (raw.length > 100000) return;  // demasiado grande, no cachear
    CacheService.getScriptCache().put('ALM_' + key, raw, ttlSec);
  } catch(_) {}
}
function _almCacheBust(prefix) {
  // Invalida todas las keys que empiecen con prefix (manual)
  // Nota: CacheService no tiene clear(), así que solo borramos las conocidas
  try {
    var keys = ['dashboard', 'guiasPreing7', 'guiasPreing30', 'rankZonas7', 'rankZonas30',
                'rankZonas60', 'sinVenta30', 'sinVenta60', 'insights30', 'alertasOps'];
    var cache = CacheService.getScriptCache();
    cache.removeAll(keys.map(function(k){ return 'ALM_' + (prefix || '') + k; }));
  } catch(_) {}
}
// Endpoint público para invalidar cache desde la PWA
function bustAlmacenCache() {
  _almCacheBust('');
  return { ok: true, data: { busted: true, ts: new Date().toISOString() } };
}

// ── WARMUP: precarga todos los endpoints pesados a CacheService ──
// Ideal para correr via trigger time-driven cada 4-5 minutos.
// Mantiene el cache "caliente" → user nunca espera.
function warmupAlmacen() {
  var inicio = new Date().getTime();
  var resultados = {};
  var endpoints = [
    { name: 'dashboard',          fn: function(){ return getDashboardAlmacen({ _refresh: true }); } },
    { name: 'catalogoResumen7',   fn: function(){ return getCatalogoStockResumen({ dias: 7,  _refresh: true }); } },
    { name: 'guiasPreing7',       fn: function(){ return getGuiasYPreingresos({ dias: 7,  _refresh: true }); } },
    { name: 'guiasPreing30',      fn: function(){ return getGuiasYPreingresos({ dias: 30, _refresh: true }); } },
    { name: 'rankZonas30',        fn: function(){ return getRankingZonas({ dias: 30, _refresh: true }); } },
    { name: 'rankZonas7',         fn: function(){ return getRankingZonas({ dias: 7,  _refresh: true }); } },
    { name: 'sinVenta30',         fn: function(){ return getProductosSinVenta({ dias: 30, _refresh: true }); } },
    { name: 'insights30',         fn: function(){ return getInsightsStock({ dias: 30, _refresh: true }); } },
    { name: 'alertasOps',         fn: function(){ return getAlertasOperativas({ _refresh: true }); } }
  ];
  endpoints.forEach(function(ep) {
    var t = new Date().getTime();
    try {
      var r = ep.fn();
      resultados[ep.name] = { ok: r && r.ok !== false, ms: (new Date().getTime() - t) };
    } catch(e) {
      resultados[ep.name] = { ok: false, error: e.message, ms: (new Date().getTime() - t) };
    }
  });
  resultados._totalMs = new Date().getTime() - inicio;
  resultados._timestamp = new Date().toISOString();
  // Guardar timestamp del último warmup (para mostrar al usuario)
  try { _setProp('ALMACEN_LAST_WARMUP', resultados._timestamp); } catch(_) {}
  return { ok: true, data: resultados };
}

// Endpoint que devuelve cuándo fue el último warmup
function getAlmacenWarmupStatus() {
  return { ok: true, data: {
    lastWarmup: _getProp('ALMACEN_LAST_WARMUP') || null,
    serverTime: new Date().toISOString()
  }};
}

// ── CATÁLOGO DE STOCK RESUMIDO (un row por skuBase, suma WH + zonas) ──
// Diseño: una sola pasada por cada hoja, agregación O(N+M+K) → viable con 2K productos
function getCatalogoStockResumen(params) {
  var rangoDias = parseInt(params && params.dias) || 7;
  return _almCached('catalogoStockResumen_' + rangoDias, 180, params, function() {
    return _getCatalogoStockResumenImpl(rangoDias);
  });
}
function _getCatalogoStockResumenImpl(rangoDias) {
  var hoy = new Date();
  var desde = new Date(hoy.getTime() - rangoDias * 86400000);
  try {
    var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'))
      .filter(function(p) {
        var e = p.estado;
        return !(e === 0 || e === '0' || e === false || String(e).toLowerCase() === 'false');
      });

    // Indexar productos
    var prodById = {}, prodByCB = {};
    var bySku = {};   // skuBase → { base, presentaciones, idsAll, barrasAll, equivCount }
    productos.forEach(function(p) {
      prodById[p.idProducto] = p;
      if (p.codigoBarra) prodByCB[p.codigoBarra] = p;
      var sku = p.skuBase || p.idProducto;
      if (!bySku[sku]) bySku[sku] = { base: null, presentaciones: [], idsAll: [], barrasAll: [], equivCount: 0 };
      bySku[sku].presentaciones.push(p);
      bySku[sku].idsAll.push(p.idProducto);
      if (p.codigoBarra) bySku[sku].barrasAll.push(p.codigoBarra);
      var fc = parseFloat(p.factorConversion) || 1;
      if (p.idProducto === sku || (!bySku[sku].base && fc === 1)) {
        bySku[sku].base = p;
      }
    });
    Object.keys(bySku).forEach(function(sku) {
      if (!bySku[sku].base) bySku[sku].base = bySku[sku].presentaciones[0];
    });

    // EQUIVALENCIAS: agregar códigos de barra alternos a cada skuBase
    var equiv = _readEquivalencias();
    Object.keys(equiv.porSku).forEach(function(sku) {
      if (!bySku[sku]) return;  // equivalencia para sku que no existe en master, ignorar
      equiv.porSku[sku].forEach(function(eq) {
        if (bySku[sku].barrasAll.indexOf(eq.codigoBarra) < 0) {
          bySku[sku].barrasAll.push(eq.codigoBarra);
          bySku[sku].equivCount++;
        }
        // También indexar prodByCB para que el lookup desde STOCK_ZONAS funcione
        if (!prodByCB[eq.codigoBarra]) prodByCB[eq.codigoBarra] = bySku[sku].base;
      });
    });

    // Stock WH: 1 pasada
    var stockWH = _safeReadWhStock();
    var whBySku = {};
    stockWH.forEach(function(s) {
      var p = prodById[s.codigoProducto] || prodByCB[s.codigoProducto];
      if (!p) return;
      var sku = p.skuBase || p.idProducto;
      whBySku[sku] = (whBySku[sku] || 0) + (parseFloat(s.cantidadDisponible) || 0);
    });

    // Stock zonas ME: 1 pasada
    var stockZonas = _safeReadMeStockZonas();
    var zonasBySku = {};
    stockZonas.forEach(function(z) {
      var cb = String(z.Cod_Barras || z.codigoBarra || '').trim();
      var p = prodByCB[cb];
      if (!p) return;
      var sku = p.skuBase || p.idProducto;
      zonasBySku[sku] = (zonasBySku[sku] || 0) + (parseFloat(z.Cantidad || z.cantidad) || 0);
    });

    // Ventas N días: 1 pasada VENTAS_CABECERA + DETALLE
    var ventasBySku = {};
    try {
      var ssMe = SpreadsheetApp.openById(_getProp('ME_SS_ID'));
      var shVC = ssMe.getSheetByName('VENTAS_CABECERA');
      var shVD = ssMe.getSheetByName('VENTAS_DETALLE');
      if (shVC && shVD) {
        var dataVC = shVC.getDataRange().getValues();
        var idsValidas = {};
        for (var i = 1; i < dataVC.length; i++) {
          var fecha = dataVC[i][1] ? new Date(dataVC[i][1]) : null;
          if (!fecha || fecha < desde) continue;
          if (String(dataVC[i][8] || '').toUpperCase() === 'ANULADO') continue;
          idsValidas[String(dataVC[i][0] || '').trim()] = true;
        }
        var dataVD = shVD.getDataRange().getValues();
        for (var j = 1; j < dataVD.length; j++) {
          var idV = String(dataVD[j][0] || '').trim();
          if (!idsValidas[idV]) continue;
          var sku2 = String(dataVD[j][1] || '').trim();
          var cb2  = String(dataVD[j][6] || '').trim();
          var p = prodById[sku2] || prodByCB[cb2];
          if (!p) continue;
          var skuKey = p.skuBase || p.idProducto;
          var cant = parseFloat(dataVD[j][3]) || 0;
          ventasBySku[skuKey] = (ventasBySku[skuKey] || 0) + cant;
        }
      }
    } catch(_){}

    // Construir resultado
    var resultado = Object.keys(bySku).map(function(sku) {
      var grupo = bySku[sku];
      var p = grupo.base;
      var whQ    = whBySku[sku] || 0;
      var zonasQ = zonasBySku[sku] || 0;
      var total  = whQ + zonasQ;
      var ventas = ventasBySku[sku] || 0;
      var rotDia = ventas / rangoDias;
      var diasAcabar = (rotDia > 0 && total > 0) ? Math.floor(total / rotDia) : null;
      var minimo = parseFloat(p.stockMinimo) || 0;
      var maximo = parseFloat(p.stockMaximo) || 0;
      // Nivel de alerta para ordenar/colorear
      var alerta = 'OK';
      if (total < 0)                                          alerta = 'NEGATIVO';
      else if (minimo > 0 && total < minimo)                  alerta = 'BAJO_MINIMO';
      else if (rotDia > 0 && diasAcabar !== null && diasAcabar < 7) alerta = 'AGOTAR_PRONTO';
      else if (total > 0 && ventas === 0)                     alerta = 'SIN_ROTACION';
      else if (minimo > 0 && total < minimo * 1.2)            alerta = 'CERCA_MINIMO';
      return {
        skuBase:           sku,
        idProducto:        p.idProducto,
        descripcion:       p.descripcion || sku,
        codigoBarra:       p.codigoBarra || '',
        marca:             p.marca || '',
        idCategoria:       p.idCategoria || '',
        precioVenta:       parseFloat(p.precioVenta) || 0,
        precioCosto:       parseFloat(p.precioCosto) || 0,
        stockMinimo:       minimo,
        stockMaximo:       maximo,
        whCantidad:        whQ,
        zonasCantidad:     zonasQ,
        totalCantidad:     total,
        ventasRango:       ventas,
        rotacionDia:       Math.round(rotDia * 10) / 10,
        diasParaAcabar:    diasAcabar,
        countPresentaciones: grupo.presentaciones.length,
        countEquivalencias:  grupo.equivCount,
        alerta:            alerta
      };
    });

    // Ordenar: alertas primero (NEGATIVO > BAJO_MINIMO > AGOTAR_PRONTO > etc.)
    var sevOrden = { NEGATIVO: 0, BAJO_MINIMO: 1, AGOTAR_PRONTO: 2, SIN_ROTACION: 3, CERCA_MINIMO: 4, OK: 5 };
    resultado.sort(function(a, b) {
      var dx = (sevOrden[a.alerta] || 9) - (sevOrden[b.alerta] || 9);
      if (dx !== 0) return dx;
      return (a.descripcion || '').localeCompare(b.descripcion || '');
    });

    return { ok: true, data: { _almV: 2, productos: resultado, total: resultado.length, rangoDias: rangoDias } };
  } catch(e) {
    return { ok: false, error: 'Error catálogo stock: ' + e.message };
  }
}

// ── DASHBOARD: KPIs principales (cache 5min) ────────────────────
function getDashboardAlmacen(params) {
  return _almCached('dashboard', 300, params, function() {
    return _getDashboardAlmacenImpl();
  });
}
function _getDashboardAlmacenImpl() {
  try {
    var hoy = new Date();
    var mesIni = new Date(hoy.getFullYear(), hoy.getMonth(), 1);
    var stockWh    = _safeReadWhStock();
    var productos  = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
    var prodMap = {}; productos.forEach(function(p){ prodMap[p.idProducto] = p; if (p.skuBase) prodMap[p.skuBase] = p; });

    // 1. Stock valorizado
    var stockValor = 0, totalUnidades = 0;
    stockWh.forEach(function(s) {
      var prod = prodMap[s.codigoProducto] || prodMap[s.skuBase];
      var cant = parseFloat(s.cantidadDisponible) || 0;
      var costo = prod ? (parseFloat(prod.precioCosto) || 0) : 0;
      stockValor    += cant * costo;
      totalUnidades += cant;
    });

    // 2. Productos críticos (stock < mínimo)
    var criticos = 0, enAlerta = 0;
    stockWh.forEach(function(s) {
      var prod = prodMap[s.codigoProducto] || prodMap[s.skuBase];
      if (!prod) return;
      var cant = parseFloat(s.cantidadDisponible) || 0;
      var min  = parseFloat(prod.stockMinimo) || 0;
      if (min > 0) {
        if (cant < min) criticos++;
        else if (cant < min * 1.2) enAlerta++;
      }
    });

    // 3. Vencimientos próximos (lotes ≤ 7 días) y críticos (≤ 30)
    var lotes = _safeReadWhLotes();
    var vencCrit = 0, vencAlerta = 0;
    lotes.forEach(function(l) {
      if (!l.fechaVencimiento || (parseFloat(l.cantidadActual) || 0) <= 0) return;
      var dias = Math.floor((new Date(l.fechaVencimiento) - hoy) / 86400000);
      if (dias <= 7) vencCrit++;
      else if (dias <= 30) vencAlerta++;
    });

    // 4. Mermas del mes (sumar cantidad * costo)
    var mermas = _safeReadWhMermas();
    var mermasMes = 0, mermasMesUnidades = 0, mermasPendientes = 0;
    mermas.forEach(function(m) {
      var fecha = m.fecha ? new Date(m.fecha) : null;
      if (!fecha || fecha < mesIni) return;
      mermasMesUnidades += parseFloat(m.cantidad) || 0;
      var prod = prodMap[m.codigoProducto] || prodMap[m.skuBase];
      var costo = prod ? (parseFloat(prod.precioCosto) || 0) : 0;
      mermasMes += (parseFloat(m.cantidad) || 0) * costo;
      if (String(m.estado || '').toUpperCase() === 'PENDIENTE') mermasPendientes++;
    });

    // 5. Envasados del mes
    var envasados = _safeReadWhEnvasados();
    var envMes = 0, eficienciaSum = 0, eficienciaCount = 0;
    envasados.forEach(function(e) {
      var fecha = e.fecha ? new Date(e.fecha) : null;
      if (!fecha || fecha < mesIni) return;
      envMes++;
      var ef = parseFloat(e.eficiencia);
      if (!isNaN(ef)) { eficienciaSum += ef; eficienciaCount++; }
    });
    var eficienciaProm = eficienciaCount > 0 ? (eficienciaSum / eficienciaCount) : null;

    // 6. Preingresos pendientes
    var preingresos = _safeReadWhPreingresos();
    var preingPendientes = preingresos.filter(function(p){
      return String(p.estado || '').toUpperCase() === 'PENDIENTE';
    }).length;

    return { ok: true, data: {
      stockValor:        Math.round(stockValor * 100) / 100,
      totalUnidades:     totalUnidades,
      productosTotal:    productos.length,
      productosCriticos: criticos,
      productosAlerta:   enAlerta,
      vencCriticos:      vencCrit,
      vencAlerta:        vencAlerta,
      mermasMes:         Math.round(mermasMes * 100) / 100,
      mermasMesUnidades: mermasMesUnidades,
      mermasPendientes:  mermasPendientes,
      envasadosMes:      envMes,
      eficienciaPromedio: eficienciaProm,
      preingresosPendientes: preingPendientes,
      timestamp:         new Date().toISOString()
    }};
  } catch(e) {
    return { ok: false, error: 'Error dashboard: ' + e.message };
  }
}

// ── STOCK UNIFICADO por producto (cache 3min, key por producto) ──
function getStockUnificado(params) {
  if (!params || (!params.skuBase && !params.idProducto)) {
    return { ok: false, error: 'Requiere skuBase o idProducto' };
  }
  var key = 'stockUnif_' + (params.skuBase || params.idProducto) + '_' + (parseInt(params.rangoDias) || 7);
  return _almCached(key, 60, params, function() {  // TTL 60s para actualización rápida
    return _getStockUnificadoImpl(params);
  });
}
function _getStockUnificadoImpl(params) {
  var key = params.skuBase || params.idProducto;
  var rangoDias = parseInt(params.rangoDias) || 7;
  var hoy = new Date();
  var desde = new Date(hoy.getTime() - rangoDias * 86400000);

  try {
    // Catálogo + resolver canónico de zonas
    var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
    var resolver = _buildZonaResolver();
    // Debug: capturar qué leyó de ZONAS para que el frontend lo muestre
    var _zonasLeidasFromMaster = _sheetToObjects(getSheet('ZONAS')).map(function(z) {
      return {
        idZona: z.idZona, nombre: z.nombre, estado: z.estado,
        canonResolved: z.idZona ? resolver.resolve(z.idZona) : null
      };
    });

    // Producto base — intentar 3 caminos: idProducto, skuBase, codigoBarra
    var prodBase = productos.find(function(p){
      return p.idProducto === key || p.skuBase === key || p.codigoBarra === key;
    });
    // Si no está en MOS catálogo, devolver al menos los datos de WH (catálogo desincronizado)
    if (!prodBase) {
      var stockWh0 = _safeReadWhStock();
      var matchWh = stockWh0.find(function(s){ return s.codigoProducto === key; });
      var cantWh0 = matchWh ? (parseFloat(matchWh.cantidadDisponible) || 0) : 0;
      return { ok: true, data: {
        producto: {
          idProducto:  key,
          skuBase:     '',
          descripcion: '⚠ ' + key + ' (no existe en catálogo MOS)',
          codigoBarra: '',
          stockMinimo: 0, stockMaximo: 0, precioCosto: 0, precioVenta: 0
        },
        wh: { cantidad: cantWh0, detalle: matchWh ? [matchWh] : [] },
        zonas: [],
        total: { cantidad: cantWh0, rotacionDia: 0, ventasRango: 0, diasParaAcabar: null, rangoDiasConsultado: rangoDias },
        insights: [{
          tipo: 'NO_EN_CATALOGO',
          severidad: 'ALTA',
          mensaje: 'Este producto está en WH pero no en PRODUCTOS_MASTER de MOS',
          accion: 'Crearlo en Catálogo MOS para activar tracking de zonas y rotación'
        }],
        sinCatalogo: true
      }};
    }
    var skuBase = prodBase.skuBase || prodBase.idProducto;
    var presentaciones = productos.filter(function(p){
      return (p.skuBase || p.idProducto) === skuBase;
    });
    var idsPresentacion = presentaciones.map(function(p){ return p.idProducto; });
    // Códigos de barra: principales de las presentaciones + equivalencias
    var equiv = _readEquivalencias();
    var equivList = equiv.porSku[skuBase] || [];
    var barrasInfo = [];  // [{ cb, tipo: 'principal'|'equiv', desc }]
    presentaciones.forEach(function(p) {
      if (p.codigoBarra) {
        barrasInfo.push({ codigoBarra: p.codigoBarra, tipo: 'principal', descripcion: p.descripcion || '' });
      }
    });
    equivList.forEach(function(eq) {
      if (!barrasInfo.find(function(b){ return b.codigoBarra === eq.codigoBarra; })) {
        barrasInfo.push({ codigoBarra: eq.codigoBarra, tipo: 'equivalencia', descripcion: eq.descripcion || '' });
      }
    });
    var barrasPresentacion = barrasInfo.map(function(b){ return b.codigoBarra; });

    // 1. Stock WH
    var stockWh = _safeReadWhStock();
    var stockWhCantidad = 0;
    var stockWhDetalle = [];
    var stockWhPorCb = {};  // codigoBarra → cantidad WH
    stockWh.forEach(function(s) {
      if (idsPresentacion.indexOf(s.codigoProducto) >= 0 || barrasPresentacion.indexOf(s.codigoProducto) >= 0) {
        var c = parseFloat(s.cantidadDisponible) || 0;
        stockWhCantidad += c;
        stockWhDetalle.push({
          codigoProducto: s.codigoProducto,
          cantidad: c,
          ultimaActualizacion: s.ultimaActualizacion
        });
        stockWhPorCb[s.codigoProducto] = (stockWhPorCb[s.codigoProducto] || 0) + c;
      }
    });

    // 2. Stock por zona (ME.STOCK_ZONAS) — agrupando por canónico
    var stockZonas = _safeReadMeStockZonas();
    var zonaAcum = {};  // { canonId: { cantidad, nombre } }
    var stockZonasPorCb = {};  // codigoBarra → cantidad total en zonas
    stockZonas.forEach(function(z) {
      var cb = String(z.Cod_Barras || z.codigoBarra || '').trim();
      if (barrasPresentacion.indexOf(cb) < 0) return;
      var qty = parseFloat(z.Cantidad || z.cantidad) || 0;
      stockZonasPorCb[cb] = (stockZonasPorCb[cb] || 0) + qty;
      var zid = String(z.Zona_ID || z.zonaId || '').trim();
      if (!zid) return;
      var canon = resolver.resolve(zid);
      if (!zonaAcum[canon.id]) zonaAcum[canon.id] = { cantidad: 0, nombre: canon.nombre };
      zonaAcum[canon.id].cantidad += qty;
    });

    // 3. Ventas últimos N días por zona (canonicalizado)
    var ventasZonaRaw = _calcularVentasPorZonaRango(barrasPresentacion, idsPresentacion, desde);
    var ventasZona = {};
    Object.keys(ventasZonaRaw).forEach(function(rawId) {
      var canon = resolver.resolve(rawId);
      ventasZona[canon.id] = (ventasZona[canon.id] || 0) + ventasZonaRaw[rawId];
    });

    // 4. Construir array de zonas — INCLUIR TODAS las zonas de la tabla ZONAS
    //    (aunque no tengan stock ni ventas de este producto), para visibilidad completa.
    var zonasMaster = _sheetToObjects(getSheet('ZONAS'));
    var idsTodas = {};
    var nombreCanonMap = {};
    // 4a. Todas las ZONAS activas
    zonasMaster.forEach(function(z){
      if (!z.idZona) return;
      var activa = (z.estado === undefined || z.estado === '' || z.estado === 1 || z.estado === '1' || z.estado === true);
      if (!activa) return;
      var canon = resolver.resolve(z.idZona);
      idsTodas[canon.id] = true;
      nombreCanonMap[canon.id] = canon.nombre;
    });
    // 4b. Cualquier zona que aparezca en stock o ventas pero no en ZONAS (sin registrar)
    Object.keys(zonaAcum).forEach(function(z){
      if (!idsTodas[z]) {
        idsTodas[z] = true;
        nombreCanonMap[z] = (zonaAcum[z] && zonaAcum[z].nombre) || z;
      }
    });
    Object.keys(ventasZona).forEach(function(z){
      if (!idsTodas[z]) { idsTodas[z] = true; nombreCanonMap[z] = z; }
    });

    var zonasArr = Object.keys(idsTodas).map(function(canonId) {
      var hasStockRow = !!zonaAcum[canonId];          // ¿hay fila en STOCK_ZONAS?
      var hasVentaRow = ventasZona[canonId] !== undefined; // ¿alguna venta del producto?
      var info = zonaAcum[canonId] || { cantidad: 0 };
      var cant = info.cantidad;
      var ventas = ventasZona[canonId] || 0;
      var rotDia = ventas / rangoDias;
      var diasParaAcabar = (rotDia > 0 && cant > 0) ? Math.floor(cant / rotDia) : null;
      return {
        idZona: canonId,
        nombre: nombreCanonMap[canonId] || canonId,
        cantidad: cant,
        ventasRango: ventas,
        rotacionDia: Math.round(rotDia * 10) / 10,
        diasParaAcabar: diasParaAcabar,
        // Flags explícitos: registro vs cantidad
        tieneRegistroStock: hasStockRow,    // true si hay fila en STOCK_ZONAS para este producto
        tieneRegistroVenta: hasVentaRow,    // true si hubo alguna venta del producto en esta zona
        sinStock: cant <= 0,
        sinVentas: ventas <= 0
      };
    }).sort(function(a, b){
      // Orden: las que tienen stock o ventas primero, después por mayor ventas
      var aHas = (a.cantidad > 0 || a.ventasRango > 0) ? 1 : 0;
      var bHas = (b.cantidad > 0 || b.ventasRango > 0) ? 1 : 0;
      if (aHas !== bHas) return bHas - aHas;
      return b.ventasRango - a.ventasRango;
    });

    // 5. Total
    var totalCant = stockWhCantidad + zonasArr.reduce(function(s, z){ return s + z.cantidad; }, 0);
    var totalRot = zonasArr.reduce(function(s, z){ return s + z.rotacionDia; }, 0);
    var diasTotalParaAcabar = (totalRot > 0 && totalCant > 0) ? Math.floor(totalCant / totalRot) : null;

    // 6. Insights
    var insights = [];
    zonasArr.forEach(function(z) {
      if (z.rotacionDia > 0 && z.cantidad > 0 && z.diasParaAcabar !== null && z.diasParaAcabar < 7) {
        insights.push({
          tipo: 'REPONER_ZONA',
          severidad: 'ALTA',
          mensaje: 'Zona ' + z.nombre + ' consume ' + z.rotacionDia + '/d, alcanza ' + z.diasParaAcabar + ' días',
          idZona: z.idZona,
          accion: 'Trasladar desde WH (' + stockWhCantidad + 'u disponibles)'
        });
      }
    });
    if (totalRot === 0 && totalCant > 0) {
      insights.push({
        tipo: 'SIN_ROTACION',
        severidad: 'MEDIA',
        mensaje: 'Sin ventas en últimos ' + rangoDias + ' días con ' + totalCant + 'u en stock',
        accion: 'Considerar promo/descuento para rotar'
      });
    }
    var minimo = parseFloat(prodBase.stockMinimo) || 0;
    if (minimo > 0 && totalCant < minimo) {
      insights.push({
        tipo: 'BAJO_MINIMO',
        severidad: 'CRITICA',
        mensaje: 'Stock total (' + totalCant + ') por debajo del mínimo (' + minimo + ')',
        accion: 'Generar pedido de reposición'
      });
    }

    // Construir detalle por código de barra
    var codigosBarraDetalle = barrasInfo.map(function(b) {
      return {
        codigoBarra:   b.codigoBarra,
        tipo:          b.tipo,
        descripcion:   b.descripcion,
        stockWh:       stockWhPorCb[b.codigoBarra] || 0,
        stockZonas:    stockZonasPorCb[b.codigoBarra] || 0,
        stockTotal:    (stockWhPorCb[b.codigoBarra] || 0) + (stockZonasPorCb[b.codigoBarra] || 0)
      };
    });

    return { ok: true, data: {
      producto: {
        idProducto:  prodBase.idProducto,
        skuBase:     skuBase,
        descripcion: prodBase.descripcion,
        codigoBarra: prodBase.codigoBarra,
        stockMinimo: parseFloat(prodBase.stockMinimo) || 0,
        stockMaximo: parseFloat(prodBase.stockMaximo) || 0,
        precioCosto: parseFloat(prodBase.precioCosto) || 0,
        precioVenta: parseFloat(prodBase.precioVenta) || 0
      },
      codigosBarra: codigosBarraDetalle,
      countEquivalencias: equivList.length,
      wh: {
        cantidad: stockWhCantidad,
        detalle: stockWhDetalle
      },
      zonas: zonasArr,
      total: {
        cantidad:           totalCant,
        rotacionDia:        Math.round(totalRot * 10) / 10,
        ventasRango:        zonasArr.reduce(function(s, z){ return s + z.ventasRango; }, 0),
        diasParaAcabar:     diasTotalParaAcabar,
        rangoDiasConsultado: rangoDias
      },
      insights: insights,
      _debug: {
        zonasLeidasDeTablaZONAS: _zonasLeidasFromMaster,
        idsTodasFinales: Object.keys(idsTodas),
        nombreCanonMap: nombreCanonMap,
        zonaAcumKeys: Object.keys(zonaAcum),
        ventasZonaKeys: Object.keys(ventasZona)
      }
    }};
  } catch(e) {
    return { ok: false, error: 'Error stock unificado: ' + e.message };
  }
}

// ── GUÍAS Y PREINGRESOS DE WH (cache 2min) ───────────────────────
function getGuiasYPreingresos(params) {
  var dias = parseInt(params && params.dias) || 7;
  return _almCached('guiasPreing' + dias, 120, params, function() {
    return _getGuiasYPreingresosImpl(params);
  });
}
function _getGuiasYPreingresosImpl(params) {
  try {
    var dias = parseInt(params && params.dias) || 7;
    var hoy = new Date();
    var desde = new Date(hoy.getTime() - dias * 86400000);

    var guias = _safeReadWhGuias();
    var preingresos = _safeReadWhPreingresos();

    // Filtrar guías recientes
    var guiasFiltradas = guias.filter(function(g) {
      var fecha = g.fecha ? new Date(g.fecha) : null;
      return fecha && fecha >= desde;
    }).sort(function(a, b){ return new Date(b.fecha) - new Date(a.fecha); });

    // Preingresos pendientes (todos) + procesados recientes
    var preingPend = preingresos.filter(function(p){
      return String(p.estado || '').toUpperCase() === 'PENDIENTE';
    });
    var preingProc = preingresos.filter(function(p) {
      if (String(p.estado || '').toUpperCase() !== 'PROCESADO') return false;
      var fecha = p.fecha ? new Date(p.fecha) : null;
      return fecha && fecha >= desde;
    }).sort(function(a, b){ return new Date(b.fecha) - new Date(a.fecha); });

    // Guía abiertas (>24h sin cerrar)
    var hace24h = new Date(hoy.getTime() - 86400000);
    var guiasAbiertasViejas = guias.filter(function(g) {
      var fecha = g.fecha ? new Date(g.fecha) : null;
      return String(g.estado || '').toUpperCase() === 'ABIERTA' && fecha && fecha < hace24h;
    });

    return { ok: true, data: {
      guias:                 guiasFiltradas,
      preingresosPendientes: preingPend,
      preingresosProcesados: preingProc,
      guiasAbiertasViejas:   guiasAbiertasViejas,
      resumen: {
        ingresosHoy:    _contarPorTipoYRango(guiasFiltradas, ['INGRESO_PROVEEDOR','INGRESO'], _hoyMidnight()),
        despachosHoy:   _contarPorTipoYRango(guiasFiltradas, ['SALIDA_ZONA','DESPACHO','SALIDA'], _hoyMidnight()),
        envasadosHoy:   _contarPorTipoYRango(guiasFiltradas, ['SALIDA_ENVASADO','ENVASADO'], _hoyMidnight()),
        montoIngresoHoy: _sumarMontoPorTipoYRango(guiasFiltradas, ['INGRESO_PROVEEDOR','INGRESO'], _hoyMidnight())
      }
    }};
  } catch(e) {
    return { ok: false, error: 'Error guías/preingresos: ' + e.message };
  }
}

// ── HELPERS PRIVADOS ────────────────────────────────────────────
function _safeReadWhStock() {
  try { return _sheetToObjects(_abrirWhSheet('STOCK')); } catch(e) { return []; }
}
function _safeReadWhLotes() {
  try { return _sheetToObjects(_abrirWhSheet('LOTES_VENCIMIENTO')); } catch(e) { return []; }
}
function _safeReadWhMermas() {
  try { return _sheetToObjects(_abrirWhSheet('MERMAS')); } catch(e) { return []; }
}
function _safeReadWhEnvasados() {
  try { return _sheetToObjects(_abrirWhSheet('ENVASADOS')); } catch(e) { return []; }
}
function _safeReadWhGuias() {
  try { return _sheetToObjects(_abrirWhSheet('GUIAS')); } catch(e) { return []; }
}
function _safeReadWhPreingresos() {
  try { return _sheetToObjects(_abrirWhSheet('PREINGRESOS')); } catch(e) { return []; }
}
function _safeReadMeStockZonas() {
  try { return _sheetToObjects(_abrirMeSheet('STOCK_ZONAS')); } catch(e) { return []; }
}

function _calcularVentasPorZonaRango(codBarras, idsProd, desde) {
  // Devuelve { Zona_ID: cantidadVendida }
  var resultado = {};
  try {
    var ssMe = SpreadsheetApp.openById(_getProp('ME_SS_ID'));
    var shVC = ssMe.getSheetByName('VENTAS_CABECERA');
    var shVD = ssMe.getSheetByName('VENTAS_DETALLE');
    if (!shVC || !shVD) return resultado;

    var dataVC = shVC.getDataRange().getValues();
    if (dataVC.length < 2) return resultado;
    // Mapa ID_Venta → Zona_ID + Fecha
    // VENTAS_CABECERA: ID_Venta(0) | Fecha(1) | Vendedor(2) | Estacion(3) | ... | Estado_Envio(?)
    // El estado de anulación está en col 8 (índice 8) según código existente
    var ventasIdToZona = {};
    for (var i = 1; i < dataVC.length; i++) {
      var idV = String(dataVC[i][0] || '').trim();
      if (!idV) continue;
      var fecha = dataVC[i][1] ? new Date(dataVC[i][1]) : null;
      if (!fecha || fecha < desde) continue;
      if (String(dataVC[i][8] || '').toUpperCase() === 'ANULADO') continue;
      var estacion = String(dataVC[i][3] || '').trim();
      if (!estacion) continue;
      ventasIdToZona[idV] = estacion;
    }

    // VENTAS_DETALLE: ID_Venta(0) | SKU(1) | Nombre(2) | Cantidad(3) | Precio(4) | Subtotal(5) | Cod_Barras(6) | ...
    var dataVD = shVD.getDataRange().getValues();
    var setBarras = {}; (codBarras || []).forEach(function(b){ setBarras[String(b)] = true; });
    var setIds    = {}; (idsProd || []).forEach(function(i){ setIds[String(i)] = true; });

    for (var j = 1; j < dataVD.length; j++) {
      var idV2 = String(dataVD[j][0] || '').trim();
      var zona = ventasIdToZona[idV2];
      if (!zona) continue;
      var sku  = String(dataVD[j][1] || '').trim();
      var cb   = String(dataVD[j][6] || '').trim();
      if (!setBarras[cb] && !setIds[sku]) continue;
      var cant = parseFloat(dataVD[j][3]) || 0;
      resultado[zona] = (resultado[zona] || 0) + cant;
    }
  } catch(e) { /* silencioso */ }
  return resultado;
}

function _hoyMidnight() {
  var d = new Date();
  d.setHours(0, 0, 0, 0);
  return d;
}

function _contarPorTipoYRango(guias, tipos, desdeFecha) {
  return guias.filter(function(g) {
    var fecha = g.fecha ? new Date(g.fecha) : null;
    if (!fecha || fecha < desdeFecha) return false;
    var tipo = String(g.tipo || '').toUpperCase();
    return tipos.some(function(t){ return tipo.indexOf(t) >= 0; });
  }).length;
}

function _sumarMontoPorTipoYRango(guias, tipos, desdeFecha) {
  var total = 0;
  guias.forEach(function(g) {
    var fecha = g.fecha ? new Date(g.fecha) : null;
    if (!fecha || fecha < desdeFecha) return;
    var tipo = String(g.tipo || '').toUpperCase();
    if (!tipos.some(function(t){ return tipo.indexOf(t) >= 0; })) return;
    total += parseFloat(g.montoTotal) || 0;
  });
  return Math.round(total * 100) / 100;
}

// ============================================================
// SPRINT 3 — Análisis por Zona (datos ME)
// ============================================================

// Ranking de zonas por venta total (cache 5min)
function getRankingZonas(params) {
  var rangoDias = parseInt(params && params.dias) || 30;
  return _almCached('rankZonas' + rangoDias, 300, params, function() {
    return _getRankingZonasImpl(params);
  });
}
function _getRankingZonasImpl(params) {
  try {
    var rangoDias = parseInt(params && params.dias) || 30;
    var hoy = new Date();
    var desde = new Date(hoy.getTime() - rangoDias * 86400000);

    var ssMe = SpreadsheetApp.openById(_getProp('ME_SS_ID'));
    var shVC = ssMe.getSheetByName('VENTAS_CABECERA');
    if (!shVC) return { ok: false, error: 'VENTAS_CABECERA no encontrada en ME' };

    var data = shVC.getDataRange().getValues();
    if (data.length < 2) return { ok: true, data: { zonas: [], total: 0 } };

    var resolver = _buildZonaResolver();
    // Set de zonas registradas en MOS (filtro estricto)
    var zonasMOS = _sheetToObjects(getSheet('ZONAS'));
    var zonasRegistradas = {};
    var nombresRegistrados = {};
    zonasMOS.forEach(function(z) {
      if (!z.idZona) return;
      var activa = (z.estado === undefined || z.estado === '' || z.estado === 1 || z.estado === '1' || z.estado === true);
      if (!activa) return;
      var canon = resolver.resolve(z.idZona);
      zonasRegistradas[canon.id] = true;
      nombresRegistrados[canon.id] = canon.nombre;
    });

    // Por zona canónica — SOLO zonas registradas en MOS.ZONAS
    // (lo demás cae en bucket 'OTRAS' para no perder el dinero pero mostrarlo aparte)
    var porZona = {};
    var ventasOtras = 0, ticketsOtras = 0;
    var totalVentas = 0, totalTickets = 0;
    for (var i = 1; i < data.length; i++) {
      var fecha = data[i][1] ? new Date(data[i][1]) : null;
      if (!fecha || fecha < desde) continue;
      if (String(data[i][8] || '').toUpperCase() === 'ANULADO') continue;
      var zonaRaw = String(data[i][3] || '').trim();
      if (!zonaRaw) continue;
      var canon = resolver.resolve(zonaRaw);
      var monto = parseFloat(data[i][6]) || 0;
      var vendedor = String(data[i][2] || '').trim();
      totalVentas += monto;
      totalTickets += 1;
      // Si la zona NO está registrada en MOS, va al bucket 'OTRAS'
      if (!zonasRegistradas[canon.id]) {
        ventasOtras += monto;
        ticketsOtras += 1;
        continue;
      }
      if (!porZona[canon.id]) porZona[canon.id] = { ventas: 0, tickets: 0, vendedoresSet: {}, nombre: nombresRegistrados[canon.id] };
      porZona[canon.id].ventas  += monto;
      porZona[canon.id].tickets += 1;
      porZona[canon.id].vendedoresSet[vendedor] = true;
    }

    // Asegurar que TODAS las zonas registradas aparezcan (aunque tengan 0 ventas)
    Object.keys(zonasRegistradas).forEach(function(zid) {
      if (!porZona[zid]) porZona[zid] = { ventas: 0, tickets: 0, vendedoresSet: {}, nombre: nombresRegistrados[zid] };
    });

    var arr = Object.keys(porZona).map(function(zid) {
      var d = porZona[zid];
      return {
        idZona:     zid,
        nombre:     d.nombre || zid,
        ventas:     Math.round(d.ventas * 100) / 100,
        tickets:    d.tickets,
        ticketProm: d.tickets > 0 ? Math.round((d.ventas / d.tickets) * 100) / 100 : 0,
        vendedores: Object.keys(d.vendedoresSet).length,
        pctTotal:   totalVentas > 0 ? Math.round((d.ventas / totalVentas) * 1000) / 10 : 0
      };
    }).sort(function(a, b){ return b.ventas - a.ventas; });

    return { ok: true, data: {
      _almV: 2,  // versión del schema — frontend detecta si es viejo
      zonas:        arr,
      totalVentas:  Math.round(totalVentas * 100) / 100,
      totalTickets: totalTickets,
      rangoDias:    rangoDias,
      ticketProm:   totalTickets > 0 ? Math.round((totalVentas / totalTickets) * 100) / 100 : 0,
      ventasFueraDeZonasRegistradas: Math.round(ventasOtras * 100) / 100,
      ticketsFueraDeZonasRegistradas: ticketsOtras
    }};
  } catch(e) {
    return { ok: false, error: 'Error ranking zonas: ' + e.message };
  }
}

// Productos sin venta en últimos N días (cache 10min — pesado)
function getProductosSinVenta(params) {
  var rangoDias = parseInt(params && params.dias) || 30;
  return _almCached('sinVenta' + rangoDias, 600, params, function() {
    return _getProductosSinVentaImpl(params);
  });
}
function _getProductosSinVentaImpl(params) {
  try {
    var rangoDias = parseInt(params && params.dias) || 30;
    var hoy = new Date();
    var desde = new Date(hoy.getTime() - rangoDias * 86400000);

    // 1. Obtener todos los códigos vendidos en el rango
    var ssMe = SpreadsheetApp.openById(_getProp('ME_SS_ID'));
    var shVC = ssMe.getSheetByName('VENTAS_CABECERA');
    var shVD = ssMe.getSheetByName('VENTAS_DETALLE');
    if (!shVC || !shVD) return { ok: false, error: 'Hojas ME no encontradas' };

    var dataVC = shVC.getDataRange().getValues();
    var ventasIds = {};
    for (var i = 1; i < dataVC.length; i++) {
      var fecha = dataVC[i][1] ? new Date(dataVC[i][1]) : null;
      if (!fecha || fecha < desde) continue;
      if (String(dataVC[i][8] || '').toUpperCase() === 'ANULADO') continue;
      ventasIds[String(dataVC[i][0] || '').trim()] = true;
    }

    var dataVD = shVD.getDataRange().getValues();
    var vendidos = {};
    for (var j = 1; j < dataVD.length; j++) {
      if (!ventasIds[String(dataVD[j][0] || '').trim()]) continue;
      var sku = String(dataVD[j][1] || '').trim();
      var cb  = String(dataVD[j][6] || '').trim();
      if (sku) vendidos[sku] = true;
      if (cb) vendidos[cb] = true;
    }

    // 2. Stock por zona — guardamos breakdown por barras
    var stockZonas = _safeReadMeStockZonas();
    var resolver = _buildZonaResolver();
    var stockPorBarras = {};  // { cb: { total, porZona: {canonId: cant}, nombres: {canonId: nombre} } }
    stockZonas.forEach(function(z) {
      var cb = String(z.Cod_Barras || z.codigoBarra || '').trim();
      var qty = parseFloat(z.Cantidad || z.cantidad) || 0;
      if (!cb || qty <= 0) return;
      var zid = String(z.Zona_ID || '').trim();
      var canon = zid ? resolver.resolve(zid) : null;
      if (!stockPorBarras[cb]) stockPorBarras[cb] = { total: 0, porZona: {}, nombres: {} };
      stockPorBarras[cb].total += qty;
      if (canon) {
        stockPorBarras[cb].porZona[canon.id] = (stockPorBarras[cb].porZona[canon.id] || 0) + qty;
        stockPorBarras[cb].nombres[canon.id] = canon.nombre;
      }
    });

    // 3. Productos en master con stock pero sin venta
    var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
    var sinVenta = productos.filter(function(p){
      var idP = p.idProducto;
      var cb  = p.codigoBarra;
      var info = cb && stockPorBarras[cb];
      var stockEnZonas = info ? info.total : 0;
      if (stockEnZonas <= 0) return false;
      return !(vendidos[idP] || (cb && vendidos[cb]));
    }).map(function(p){
      var info = stockPorBarras[p.codigoBarra] || { total: 0, porZona: {}, nombres: {} };
      // Construir breakdown ordenado por mayor cantidad
      var breakdown = Object.keys(info.porZona).map(function(zid) {
        return { idZona: zid, nombre: info.nombres[zid] || zid, cantidad: info.porZona[zid] };
      }).sort(function(a, b){ return b.cantidad - a.cantidad; });
      return {
        idProducto:  p.idProducto,
        skuBase:     p.skuBase,
        descripcion: p.descripcion,
        codigoBarra: p.codigoBarra,
        precioVenta: parseFloat(p.precioVenta) || 0,
        stockEnZonas: info.total,
        breakdownZonas: breakdown
      };
    }).sort(function(a, b){ return b.stockEnZonas - a.stockEnZonas; });

    return { ok: true, data: { _almV: 2, productos: sinVenta, rangoDias: rangoDias } };
  } catch(e) {
    return { ok: false, error: 'Error productos sin venta: ' + e.message };
  }
}

// ============================================================
// SPRINT 4 — Alertas operativas (push diaria + alertas críticas)
// ============================================================

function getAlertasOperativas(params) {
  return _almCached('alertasOps', 300, params, function() {
    return _getAlertasOperativasImpl();
  });
}
function _getAlertasOperativasImpl() {
  try {
    var alertas = [];
    var stockWh = _safeReadWhStock();
    var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
    var prodMap = {}; productos.forEach(function(p){ prodMap[p.idProducto] = p; });

    // 1. Productos con stock crítico (< mínimo)
    var critCount = 0, critTop = [];
    stockWh.forEach(function(s) {
      var prod = prodMap[s.codigoProducto];
      if (!prod) return;
      var cant = parseFloat(s.cantidadDisponible) || 0;
      var min  = parseFloat(prod.stockMinimo) || 0;
      if (min > 0 && cant < min) {
        critCount++;
        if (critTop.length < 5) {
          critTop.push({
            idProducto: prod.idProducto,
            descripcion: prod.descripcion,
            stock: cant,
            minimo: min
          });
        }
      }
    });
    if (critCount > 0) {
      alertas.push({
        tipo: 'STOCK_CRITICO',
        severidad: 'CRITICA',
        cantidad: critCount,
        mensaje: critCount + ' producto(s) por debajo del mínimo en almacén central',
        topItems: critTop
      });
    }

    // 2. Vencimientos próximos
    var lotes = _safeReadWhLotes();
    var hoy = new Date();
    var vencCrit = [];
    lotes.forEach(function(l) {
      if (!l.fechaVencimiento || (parseFloat(l.cantidadActual) || 0) <= 0) return;
      var dias = Math.floor((new Date(l.fechaVencimiento) - hoy) / 86400000);
      if (dias <= 7 && dias >= 0) {
        vencCrit.push({
          codigoProducto: l.codigoProducto,
          dias: dias,
          cantidad: parseFloat(l.cantidadActual) || 0
        });
      }
    });
    if (vencCrit.length > 0) {
      alertas.push({
        tipo: 'VENCIMIENTO_CRITICO',
        severidad: 'ALTA',
        cantidad: vencCrit.length,
        mensaje: vencCrit.length + ' lote(s) vencen en ≤7 días',
        topItems: vencCrit.slice(0, 5)
      });
    }

    // 3. Preingresos pendientes
    var preingresos = _safeReadWhPreingresos();
    var preingPend = preingresos.filter(function(p){
      return String(p.estado || '').toUpperCase() === 'PENDIENTE';
    });
    if (preingPend.length > 0) {
      alertas.push({
        tipo: 'PREINGRESOS_PENDIENTES',
        severidad: 'MEDIA',
        cantidad: preingPend.length,
        mensaje: preingPend.length + ' preingreso(s) esperando aprobación'
      });
    }

    return { ok: true, data: {
      alertas: alertas,
      total: alertas.length,
      timestamp: new Date().toISOString()
    }};
  } catch(e) {
    return { ok: false, error: 'Error alertas operativas: ' + e.message };
  }
}

// Trigger diario opcional: corre las alertas y manda push si hay críticas
// Configurar trigger: ScriptApp.newTrigger('alertasOperativasDiarias').timeBased().everyDays(1).atHour(7).create()
function alertasOperativasDiarias() {
  var r = getAlertasOperativas({});
  if (!r.ok || !r.data || !r.data.total) return;
  var criticas = r.data.alertas.filter(function(a){ return a.severidad === 'CRITICA'; }).length;
  // Registrar en log (sin spam)
  _registrarAlerta(
    'OPS_DIARIA',
    criticas > 0 ? 'CRITICA' : 'MEDIA',
    'Resumen diario: ' + r.data.total + ' alertas operativas (' + criticas + ' críticas)',
    'MOS',
    JSON.stringify({ alertas: r.data.alertas, ts: new Date().toISOString() })
  );
  // Push (si está configurado)
  try {
    if (typeof _pushNotificarMaster === 'function') {
      _pushNotificarMaster({
        title: 'Resumen de almacén',
        body:  r.data.total + ' alertas (' + criticas + ' críticas)',
        url:   '/index.html#/almacen'
      });
    }
  } catch(_){}
  return r;
}

// ============================================================
// SPRINT 5 — Inteligencia (sugerencias automáticas)
// ============================================================

function getInsightsStock(params) {
  var rangoDias = parseInt(params && params.dias) || 30;
  return _almCached('insights' + rangoDias, 600, params, function() {
    return _getInsightsStockImpl(params);
  });
}
function _getInsightsStockImpl(params) {
  try {
    var insights = [];
    var rangoDias = parseInt(params && params.dias) || 30;
    var hoy = new Date();
    var desde = new Date(hoy.getTime() - rangoDias * 86400000);

    var stockWh = _safeReadWhStock();
    var stockZonas = _safeReadMeStockZonas();
    var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
    var prodById = {}; productos.forEach(function(p){
      prodById[p.idProducto] = p;
      if (p.codigoBarra) prodById[p.codigoBarra] = p;
    });
    var resolver = _buildZonaResolver();
    // Mapa canonId → nombre humano (para mensajes)
    var zonaNombre = {};

    // Acumular stock por barras en zonas (canonicalizado)
    var stockBarrasMap = {};
    stockZonas.forEach(function(z) {
      var cb = String(z.Cod_Barras || z.codigoBarra || '').trim();
      var qty = parseFloat(z.Cantidad || z.cantidad) || 0;
      if (!cb) return;
      if (!stockBarrasMap[cb]) stockBarrasMap[cb] = { total: 0, zonas: {} };
      stockBarrasMap[cb].total += qty;
      var zid = String(z.Zona_ID || '').trim();
      var canon = resolver.resolve(zid);
      stockBarrasMap[cb].zonas[canon.id] = (stockBarrasMap[cb].zonas[canon.id] || 0) + qty;
      zonaNombre[canon.id] = canon.nombre;
    });

    // Calcular ventas por barras + zona (canonicalizado)
    var ventasMap = {}; // { codigoBarra: { canonZonaId: cantidad } }
    try {
      var ssMe = SpreadsheetApp.openById(_getProp('ME_SS_ID'));
      var shVC = ssMe.getSheetByName('VENTAS_CABECERA');
      var shVD = ssMe.getSheetByName('VENTAS_DETALLE');
      if (shVC && shVD) {
        var dataVC = shVC.getDataRange().getValues();
        var ventasMeta = {};
        for (var i = 1; i < dataVC.length; i++) {
          var fecha = dataVC[i][1] ? new Date(dataVC[i][1]) : null;
          if (!fecha || fecha < desde) continue;
          if (String(dataVC[i][8] || '').toUpperCase() === 'ANULADO') continue;
          var rawZona = String(dataVC[i][3] || '').trim();
          var canonV = resolver.resolve(rawZona);
          ventasMeta[String(dataVC[i][0] || '').trim()] = canonV.id;
          if (canonV) zonaNombre[canonV.id] = canonV.nombre;
        }
        var dataVD = shVD.getDataRange().getValues();
        for (var j = 1; j < dataVD.length; j++) {
          var idV = String(dataVD[j][0] || '').trim();
          var zona = ventasMeta[idV];
          if (!zona) continue;
          var cb = String(dataVD[j][6] || '').trim();
          if (!cb) continue;
          var cant = parseFloat(dataVD[j][3]) || 0;
          if (!ventasMap[cb]) ventasMap[cb] = {};
          ventasMap[cb][zona] = (ventasMap[cb][zona] || 0) + cant;
        }
      }
    } catch(_){}

    // INSIGHT 1 — Productos con stock alto y sin venta en N días
    Object.keys(stockBarrasMap).forEach(function(cb) {
      var info = stockBarrasMap[cb];
      var ventasProd = ventasMap[cb] || {};
      var ventasTot = Object.values(ventasProd).reduce(function(s, v){ return s + v; }, 0);
      if (info.total >= 10 && ventasTot === 0) {
        var prod = prodById[cb];
        if (!prod) return;
        insights.push({
          tipo: 'SIN_ROTACION',
          severidad: 'MEDIA',
          producto: prod.descripcion || cb,
          codigoBarra: cb,
          stock: info.total,
          mensaje: prod.descripcion + ' tiene ' + info.total + 'u sin venta en ' + rangoDias + ' días',
          accion: 'Lanzar promo o trasladar a otra zona'
        });
      }
    });

    // INSIGHT 2 — Trasladar entre zonas: una zona vendiendo bien con poco stock + otra con stock + sin venta
    Object.keys(ventasMap).forEach(function(cb) {
      var ventasProd = ventasMap[cb];
      var stockInfo = stockBarrasMap[cb] || { zonas: {} };
      Object.keys(ventasProd).forEach(function(zonaVendedora) {
        var ventas = ventasProd[zonaVendedora];
        var stockEnEsa = stockInfo.zonas[zonaVendedora] || 0;
        var rotacionDia = ventas / rangoDias;
        if (rotacionDia <= 0) return;
        var diasRestantes = stockEnEsa / rotacionDia;
        if (diasRestantes < 7 && diasRestantes >= 0) {
          // Buscar zona con stock pero sin venta de este producto
          Object.keys(stockInfo.zonas).forEach(function(zonaConStock) {
            if (zonaConStock === zonaVendedora) return;
            var stockOtra = stockInfo.zonas[zonaConStock] || 0;
            var ventasOtra = (ventasProd[zonaConStock] || 0);
            if (stockOtra >= 5 && ventasOtra < ventas / 3) {
              var prod = prodById[cb];
              if (!prod) return;
              var nombreOrigen = zonaNombre[zonaConStock] || zonaConStock;
              var nombreDestino = zonaNombre[zonaVendedora] || zonaVendedora;
              insights.push({
                tipo: 'TRASLADAR',
                severidad: 'ALTA',
                producto: prod.descripcion || cb,
                codigoBarra: cb,
                mensaje: 'Trasladar ' + (prod.descripcion || cb) + ': ' + nombreOrigen + ' (' + stockOtra + 'u) → ' + nombreDestino + ' (vende ' + Math.round(rotacionDia * 10) / 10 + '/d, alcanza ' + Math.floor(diasRestantes) + 'd)',
                desde: zonaConStock,
                hacia: zonaVendedora,
                cantidadSugerida: Math.min(stockOtra, Math.ceil(rotacionDia * 7))
              });
            }
          });
        }
      });
    });

    // INSIGHT 3 — Reposición: stock total < mínimo
    productos.forEach(function(p) {
      var min = parseFloat(p.stockMinimo) || 0;
      if (min <= 0) return;
      var stockEnZonas = stockBarrasMap[p.codigoBarra] ? stockBarrasMap[p.codigoBarra].total : 0;
      var stockWhProd = 0;
      stockWh.forEach(function(s){
        if (s.codigoProducto === p.idProducto || s.codigoProducto === p.codigoBarra) {
          stockWhProd += parseFloat(s.cantidadDisponible) || 0;
        }
      });
      var total = stockEnZonas + stockWhProd;
      if (total < min) {
        insights.push({
          tipo: 'REPOSICION',
          severidad: 'CRITICA',
          producto: p.descripcion,
          idProducto: p.idProducto,
          stock: total,
          minimo: min,
          mensaje: p.descripcion + ' total ' + total + 'u < mínimo ' + min,
          accion: 'Generar pedido al proveedor'
        });
      }
    });

    // Dedup + ordenar por severidad
    var prio = { CRITICA: 0, ALTA: 1, MEDIA: 2, BAJA: 3 };
    insights.sort(function(a, b){ return (prio[a.severidad] || 9) - (prio[b.severidad] || 9); });

    return { ok: true, data: { insights: insights.slice(0, 20), total: insights.length, rangoDias: rangoDias } };
  } catch(e) {
    return { ok: false, error: 'Error insights: ' + e.message };
  }
}
