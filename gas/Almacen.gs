// ============================================================
// ProyectoMOS — Almacen.gs
// Endpoints unificados de almacén/stock que combinan datos de:
//  · WH (warehouseMos) — STOCK central, GUIAS, PREINGRESOS, MERMAS, ENVASADOS
//  · ME (MosExpress)   — STOCK_ZONAS, VENTAS_CABECERA, VENTAS_DETALLE
//  · MOS               — PRODUCTOS_MASTER (catálogo), ESTACIONES (zonas)
//
// Cache: usa CacheService (memoria) con TTL configurable. Bypass con _refresh=true
// ============================================================

// ── PRODUCTO CANÓNICO HELPER ─────────────────────────────────────
// Construye un mapa { codigo_upper: canónico } donde "codigo" puede ser:
//   - idProducto / codigoBarra de un canónico → su propio canónico
//   - idProducto / codigoBarra de una presentación → canónico mismo skuBase
//   - idProducto / codigoBarra de un derivado → envasable canónico
//   - codigoBarra de una equivalencia → canónico vía skuBase
// Sirve para que cualquier vista pueda resolver un cb suelto (de stock, ventas,
// guías, mermas, vencimientos) al producto canónico al que pertenece.
function _construirMapaCBaCanonico() {
  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var canonicosBySku = {};
  var canonicosById  = {};
  productos.forEach(function(p) {
    if (_esCanonico(p)) {
      if (p.skuBase)    canonicosBySku[String(p.skuBase).toUpperCase()]    = p;
      if (p.idProducto) canonicosById[String(p.idProducto).toUpperCase()]  = p;
    }
  });

  function resolverCanonicoDe(p) {
    if (_esCanonico(p)) return p;
    if (p.codigoProductoBase) {
      var ref = String(p.codigoProductoBase).toUpperCase();
      return canonicosById[ref] || canonicosBySku[ref] || null;
    }
    if (p.skuBase) {
      return canonicosBySku[String(p.skuBase).toUpperCase()] || null;
    }
    return null;
  }

  var mapa = {};
  productos.forEach(function(p) {
    var canonico = resolverCanonicoDe(p);
    if (!canonico) return;
    if (p.idProducto)  mapa[String(p.idProducto).toUpperCase()]  = canonico;
    if (p.codigoBarra) mapa[String(p.codigoBarra).toUpperCase()] = canonico;
  });

  // Equivalencias → cb equivalente apunta al canónico
  try {
    var equiv = _readEquivalencias();
    Object.keys(equiv.porSku).forEach(function(skuBase) {
      var canonico = canonicosBySku[String(skuBase).toUpperCase()];
      if (!canonico) return;
      equiv.porSku[skuBase].forEach(function(eq) {
        if (!eq.codigoBarra) return;
        var k = String(eq.codigoBarra).toUpperCase();
        if (!mapa[k]) mapa[k] = canonico;
      });
    });
  } catch(_){}

  return mapa;
}

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
    // Mapa cb/idProd → CANÓNICO (incluye presentaciones, derivados y equivalencias)
    var mapaCanon = _construirMapaCBaCanonico();
    function _resolverProd(cod) {
      if (!cod) return null;
      return mapaCanon[String(cod).toUpperCase()] || null;
    }

    // 1. Stock valorizado (usando precioCosto del canónico al que apunta cada cb)
    var stockValor = 0, totalUnidades = 0;
    var stockWhPorCanon = {};   // { idProductoCanon: cantidad }
    stockWh.forEach(function(s) {
      var prod = _resolverProd(s.codigoProducto);
      var cant = parseFloat(s.cantidadDisponible) || 0;
      var costo = prod ? (parseFloat(prod.precioCosto) || 0) : 0;
      stockValor    += cant * costo;
      totalUnidades += cant;
      if (prod) {
        var key = String(prod.idProducto).toUpperCase();
        stockWhPorCanon[key] = (stockWhPorCanon[key] || 0) + cant;
      }
    });

    // 2. Productos críticos (stock < mínimo) — agrupado por canónico
    var criticos = 0, enAlerta = 0;
    productos.forEach(function(p) {
      if (!_esCanonico(p)) return;  // solo canónicos definen mínimo
      var min = parseFloat(p.stockMinimo) || 0;
      if (min <= 0) return;
      var key = String(p.idProducto).toUpperCase();
      var cant = stockWhPorCanon[key] || 0;
      if (cant < min) criticos++;
      else if (cant < min * 1.2) enAlerta++;
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

    // 4. Mermas del mes (sumar cantidad * costo del canónico)
    var mermas = _safeReadWhMermas();
    var mermasMes = 0, mermasMesUnidades = 0, mermasPendientes = 0;
    mermas.forEach(function(m) {
      var fecha = m.fecha ? new Date(m.fecha) : null;
      if (!fecha || fecha < mesIni) return;
      mermasMesUnidades += parseFloat(m.cantidad) || 0;
      var prod = _resolverProd(m.codigoProducto);
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

    // Matriz código × zona — qué cantidad hay de cada código en cada zona específica
    var matriz = {};  // matriz[cb][canonZonaId] = cantidad
    stockZonas.forEach(function(z) {
      var cb = String(z.Cod_Barras || z.codigoBarra || '').trim();
      if (barrasPresentacion.indexOf(cb) < 0) return;
      var zid = String(z.Zona_ID || z.zonaId || '').trim();
      if (!zid) return;
      var canonZ = resolver.resolve(zid);
      if (!matriz[cb]) matriz[cb] = {};
      matriz[cb][canonZ.id] = (matriz[cb][canonZ.id] || 0) + (parseFloat(z.Cantidad || z.cantidad) || 0);
    });

    // Construir detalle por código de barra
    var codigosBarraDetalle = barrasInfo.map(function(b) {
      return {
        codigoBarra:   b.codigoBarra,
        tipo:          b.tipo,
        descripcion:   b.descripcion,
        stockWh:       stockWhPorCb[b.codigoBarra] || 0,
        stockZonas:    stockZonasPorCb[b.codigoBarra] || 0,
        stockTotal:    (stockWhPorCb[b.codigoBarra] || 0) + (stockZonasPorCb[b.codigoBarra] || 0),
        porZona:       matriz[b.codigoBarra] || {}
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

// ── OPERACIONES UNIFICADAS — WH + ME por día, agrupado ──────────
function getOperacionesUnificadas(params) {
  var dias = parseInt(params && params.dias) || 7;
  // [v41.22] key bumpeada para invalidar cache que no traía op.preingreso anidado
  return _almCached('opsUnifV3_' + dias, 60, params, function() {
    return _getOperacionesUnificadasImpl(dias);
  });
}
function _getOperacionesUnificadasImpl(dias) {
  try {
    var hoy = new Date();
    var desde = new Date(hoy.getTime() - dias * 86400000);
    var resolver = _buildZonaResolver();
    var tz = Session.getScriptTimeZone();
    var operaciones = [];

    // Mapa idProveedor → nombre (para enriquecer ops). [v41.22] Fusiona
    // PROVEEDORES_MASTER (MOS) + PROVEEDORES (WH) — los preingresos WH
    // pueden tener IDs que no están en master, sin esto el voucher mostraba
    // solo el ID en lugar del nombre del proveedor.
    var provMap = {};
    try {
      _sheetToObjects(getSheet('PROVEEDORES_MASTER')).forEach(function(pr) {
        if (pr.idProveedor) provMap[String(pr.idProveedor)] = pr.nombre || pr.idProveedor;
      });
    } catch(_){}
    try {
      _sheetToObjects(_abrirWhSheet('PROVEEDORES')).forEach(function(pr) {
        if (pr.idProveedor && !provMap[String(pr.idProveedor)]) {
          provMap[String(pr.idProveedor)] = pr.nombre || pr.idProveedor;
        }
      });
    } catch(_){}

    // Helper: parser robusto contra todos los formatos que puede venir
    function _parseFecha(v) {
      if (!v) return null;
      // 1. Date object (lo más común si el sheet tiene celda formato Fecha)
      if (v instanceof Date) return isNaN(v.getTime()) ? null : v;
      var s = String(v).trim();
      if (!s) return null;
      // 2. ISO YYYY-MM-DD (sin hora) -> anclar a 12:00 local
      if (/^\d{4}-\d{1,2}-\d{1,2}$/.test(s)) {
        return new Date(s + 'T12:00:00');
      }
      // 3. ISO completo YYYY-MM-DDTHH:MM:SS o YYYY-MM-DD HH:MM:SS
      if (/^\d{4}-\d{1,2}-\d{1,2}[T ]\d{1,2}:\d{1,2}/.test(s)) {
        var iso = s.replace(' ', 'T');
        var d1 = new Date(iso);
        if (!isNaN(d1.getTime())) return d1;
      }
      // 4. M/D/YYYY [H:MM:SS] (formato US, así guarda Sheets por default en muchas configs)
      var mdy = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$/);
      if (mdy) {
        return new Date(
          parseInt(mdy[3], 10),
          parseInt(mdy[1], 10) - 1,
          parseInt(mdy[2], 10),
          parseInt(mdy[4] || 0, 10),
          parseInt(mdy[5] || 0, 10),
          parseInt(mdy[6] || 0, 10)
        );
      }
      // 5. D/M/YYYY (formato Latam si el spreadsheet usa locale 'es')
      var dmy = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
      if (dmy) {
        var dd = parseInt(dmy[1], 10), mm = parseInt(dmy[2], 10), yy = parseInt(dmy[3], 10);
        // Heurística: si dd > 12, es D/M (no M/D)
        if (dd > 12 && mm <= 12) return new Date(yy, mm - 1, dd);
      }
      // 6. Fallback: dejar que JS intente
      var d2 = new Date(s);
      return isNaN(d2.getTime()) ? null : d2;
    }

    // 1. WH GUIAS — [v41.22] Anidar datos del preingreso vinculado para que
    // el voucher en Operaciones MOS muestre el preingreso original como
    // anexo (fotos, comentario, tags, cargadores con estados de carreta).
    var whGuias = _safeReadWhGuias();
    // Indexar preingresos por id UNA vez para evitar O(n*m)
    var allPre = _safeReadWhPreingresos();
    var preMap = {};
    allPre.forEach(function(p) { if (p.idPreingreso) preMap[String(p.idPreingreso)] = p; });
    // [v41.22] Cross-check inverso: indexar las guías que apuntan a un preingreso.
    // Sirve para detectar preingresos ya procesados aunque su columna idGuia
    // haya quedado vacía por race condition o error de actualización en WH.
    var preProcesadosByGuia = {};
    whGuias.forEach(function(g) {
      var idPre = String(g.idPreingreso || '').trim();
      if (idPre) preProcesadosByGuia[idPre] = true;
    });

    whGuias.forEach(function(g) {
      var fecha = _parseFecha(g.fecha);
      if (!fecha || fecha < desde) return;

      // Anidar preingreso si esta guía nace de uno
      var anexoPre = null;
      if (g.idPreingreso && preMap[String(g.idPreingreso)]) {
        var pi = preMap[String(g.idPreingreso)];
        var fechaPi = _parseFecha(pi.fecha);
        anexoPre = {
          idPreingreso: pi.idPreingreso || '',
          monto:        parseFloat(pi.monto) || 0,
          comentario:   pi.comentario || '',
          fotos:        pi.fotos || '',
          cargadores:   pi.cargadores || '',
          usuario:      pi.usuario || '',
          estado:       pi.estado || '',
          fecha:        fechaPi ? fechaPi.toISOString() : ''
        };
      }

      operaciones.push({
        fuente:           'WH',
        fuenteLabel:      'Almacén central',
        idGuia:           g.idGuia || '',
        tipo:             g.tipo || '',
        fecha:            fecha.toISOString(),
        usuario:          g.usuario || '',
        idProveedor:      g.idProveedor || '',
        nombreProveedor:  g.idProveedor ? (provMap[String(g.idProveedor)] || g.idProveedor) : '',
        idZona:           g.idZona || '',
        idZonaCanonId:    g.idZona ? resolver.resolve(g.idZona).id : '',
        idZonaCanonNom:   g.idZona ? resolver.resolve(g.idZona).nombre : '',
        numeroDocumento:  g.numeroDocumento || '',
        comentario:       g.comentario || '',
        montoTotal:       parseFloat(g.montoTotal) || 0,
        estado:           g.estado || '',
        idPreingreso:     g.idPreingreso || '',
        preingreso:       anexoPre,
        foto:             g.foto || '',
        esPreingreso:     false
      });
    });

    // 2. WH PREINGRESOS — SOLO PENDIENTES (los PROCESADO ya están como guía en sección 1)
    // Reusamos allPre cargado arriba para indexar preMap (evita doble lectura).
    var preingresos = allPre;
    preingresos.forEach(function(p) {
      var estado = String(p.estado || '').toUpperCase();
      var idPre  = String(p.idPreingreso || '').trim();
      // [v41.22] Skip si:
      //   a) estado es PROCESADO o ANULADO
      //   b) tiene idGuia poblado en su propia fila
      //   c) Cross-check: alguna guía ya apunta a este preingreso (idGuia vacío
      //      por bug histórico no debe duplicar el voucher en Operaciones MOS)
      if (estado === 'PROCESADO' || estado === 'ANULADO') return;
      if (p.idGuia && String(p.idGuia).trim()) return;
      if (idPre && preProcesadosByGuia[idPre]) return;

      var fecha = _parseFecha(p.fecha);
      if (!fecha || fecha < desde) return;
      operaciones.push({
        fuente:           'WH',
        fuenteLabel:      'Almacén central',
        idGuia:           p.idPreingreso || '',
        tipo:             'PREINGRESO',
        fecha:            fecha.toISOString(),
        usuario:          p.usuario || '',
        idProveedor:      p.idProveedor || '',
        nombreProveedor:  p.idProveedor ? (provMap[String(p.idProveedor)] || p.idProveedor) : '',
        idZona:           '',
        comentario:       p.comentario || '',
        montoTotal:       parseFloat(p.monto) || 0,
        estado:           estado || 'PENDIENTE',
        idGuiaGenerada:   p.idGuia || '',
        esPreingreso:     true,
        fotos:            p.fotos || ''
      });
    });

    // 3. ME GUIAS_CABECERA (de cada zona)
    var diagME = { leidas: 0, filtroFecha: 0, agregadas: 0, error: '', meSsId: '', sinSheet: false };
    try {
      var meSsId = _getProp('ME_SS_ID');
      diagME.meSsId = meSsId ? (String(meSsId).substring(0, 8) + '…') : 'NULL';
      var ssMe = SpreadsheetApp.openById(meSsId);
      var shGC = ssMe.getSheetByName('GUIAS_CABECERA');
      if (!shGC) { diagME.sinSheet = true; }
      if (shGC) {
        var data = shGC.getDataRange().getValues();
        diagME.leidas = data.length - 1;
        if (data.length >= 2) {
          for (var i = 1; i < data.length; i++) {
            var fechaME = _parseFecha(data[i][1]);
            if (!fechaME) { continue; }
            if (fechaME < desde) { diagME.filtroFecha++; continue; }
            var zonaRaw = String(data[i][3] || '').trim();
            var canon = zonaRaw ? resolver.resolve(zonaRaw) : { id: '', nombre: '' };
            operaciones.push({
              fuente:         'ME',
              fuenteLabel:    'Zona ' + (canon.nombre || zonaRaw || ''),
              idGuia:         String(data[i][0] || '').trim(),
              tipo:           String(data[i][4] || '').trim(),
              fecha:          fechaME.toISOString(),
              usuario:        String(data[i][2] || '').trim(),
              idZona:         zonaRaw,
              idZonaCanonId:  canon.id,
              idZonaCanonNom: canon.nombre,
              comentario:     String(data[i][5] || '').trim(),
              zonaDestino:    String(data[i][6] || '').trim(),
              estado:         String(data[i][7] || '').trim(),
              montoTotal:     0,
              esPreingreso:   false
            });
            diagME.agregadas++;
          }
        }
      }
    } catch(eME){ diagME.error = String(eME && eME.message || eME); }

    // Ordenar por fecha desc
    operaciones.sort(function(a, b){ return new Date(b.fecha) - new Date(a.fecha); });

    // Agrupar por día — usar el TZ del script (Lima) para evitar shifts
    var porDia = {};
    operaciones.forEach(function(op) {
      var f = new Date(op.fecha);
      var key = Utilities.formatDate(f, tz, 'yyyy-MM-dd');
      if (!porDia[key]) porDia[key] = { fecha: key, operaciones: [], totalMonto: 0 };
      porDia[key].operaciones.push(op);
      porDia[key].totalMonto += op.montoTotal || 0;
    });
    var diasArr = Object.keys(porDia).sort().reverse().map(function(k) {
      return {
        fecha:        k,
        totalMonto:   Math.round(porDia[k].totalMonto * 100) / 100,
        totalOps:     porDia[k].operaciones.length,
        operaciones:  porDia[k].operaciones
      };
    });

    return { ok: true, data: {
      _almV: 2,
      porDia:    diasArr,
      total:     operaciones.length,
      rangoDias: dias,
      _debug: {
        timezone:     tz,
        nowIso:       new Date().toISOString(),
        nowLocal:     Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd HH:mm:ss'),
        meStats:      diagME,
        primerasFechasWh: whGuias.slice(-3).map(function(g){
          var f = _parseFecha(g.fecha);
          return {
            raw:    String(g.fecha),
            parsed: f ? f.toISOString() : null,
            local:  f ? Utilities.formatDate(f, tz, 'yyyy-MM-dd HH:mm:ss') : null
          };
        })
      }
    }};
  } catch(e) {
    return { ok: false, error: 'Error operaciones unificadas: ' + e.message };
  }
}

// Helper: construye mapa para resolver código a producto.
// Indexa por idProducto, codigoBarra principal Y codigos de EQUIVALENCIAS.
// bySku PRIORIZA canónicos para que las equivalencias se resuelvan al producto
// base (no a una presentación que comparte el skuBase).
function _buildProdLookup() {
  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var bySku = {};
  var lookup = {};
  productos.forEach(function(p) {
    if (p.idProducto)  lookup[p.idProducto]  = p;
    if (p.codigoBarra) lookup[p.codigoBarra] = p;
    var sku = p.skuBase || p.idProducto;
    if (!sku) return;
    var existente = bySku[sku];
    // Solo sobreescribir si el actual NO es canónico Y el nuevo SÍ lo es
    if (!existente) {
      bySku[sku] = p;
    } else if (!_esCanonico(existente) && _esCanonico(p)) {
      bySku[sku] = p;
    }
  });
  // Equivalencias: cada cb equivalente apunta al producto BASE via skuBase
  try {
    var equiv = _readEquivalencias();
    Object.keys(equiv.porSku).forEach(function(skuBase) {
      var prodBase = bySku[skuBase];
      if (!prodBase) return;
      equiv.porSku[skuBase].forEach(function(eq) {
        if (!lookup[eq.codigoBarra]) lookup[eq.codigoBarra] = prodBase;
      });
    });
  } catch(_){}
  return lookup;
}

// Llenar/actualizar costos de una guía WH y opcionalmente propagar a PRODUCTOS_MASTER
// params: { idGuia, items: [{idDetalle, codigoProducto, precioUnitario}], actualizarPrecioCosto: bool }
// Retorna también sugerenciasPrecioVenta[] basadas en política + lotización FIFO.
function llenarCostosGuia(params) {
  if (!params.idGuia || !Array.isArray(params.items) || !params.items.length) {
    return { ok: false, error: 'idGuia + items[] requeridos' };
  }
  // 1. Llamar WH para actualizar precioUnitario en GUIA_DETALLE
  var whItems = params.items.map(function(it) {
    return { idDetalle: it.idDetalle, precioUnitario: parseFloat(it.precioUnitario) || 0 };
  });
  var resWh = postToWarehouse('actualizarPreciosDetalle', { idGuia: params.idGuia, items: whItems });
  if (!resWh || !resWh.ok) {
    return { ok: false, error: 'WH no respondió: ' + ((resWh && resWh.error) || 'sin detalle') };
  }
  // 2. Si actualizarPrecioCosto=true, propagar a PRODUCTOS_MASTER.precioCosto
  var actualizadosCosto = 0;
  var prodLookup = _buildProdLookup();
  if (params.actualizarPrecioCosto) {
    params.items.forEach(function(it) {
      var precio = parseFloat(it.precioUnitario) || 0;
      if (precio <= 0) return;
      var p = prodLookup[it.codigoProducto];
      if (!p || !p.idProducto) return;
      try {
        actualizarProductoMaster({
          _source:     'MOS_MODAL_PRODUCTO',
          idProducto:  p.idProducto,
          precioCosto: precio,
          usuario:     params.usuario || ''
        });
        actualizadosCosto++;
      } catch(_){}
    });
  }
  // 3. Calcular sugerencias de precio venta para cada producto (con lotización FIFO)
  var sugerencias = [];
  try {
    var mapaCat = _cargarMapaPoliticaCategorias();
    var mapaCanonicos = _cargarMapaCanonicos();
    // Refrescar lookup con costos actualizados (si se aplicó actualizarPrecioCosto)
    if (params.actualizarPrecioCosto) prodLookup = _buildProdLookup();

    // ⚡ OPTIMIZACIÓN: precargar el contexto FIFO UNA SOLA VEZ.
    // Antes _calcularLotizacionFIFO + _stockTotalProducto releían todas las
    // guías de WH + GUIA_DETALLE completo + STOCK + STOCK_ZONAS por CADA
    // producto. Con 10 items → 10 relecturas de lo mismo. Ahora se lee 1 vez
    // y se pasa como ctx a las funciones de cálculo.
    var fifoCtx = _construirFifoCtx();

    params.items.forEach(function(it) {
      var costoNuevo = parseFloat(it.precioUnitario) || 0;
      if (costoNuevo <= 0) return;
      var p = prodLookup[it.codigoProducto];
      if (!p || !p.idProducto) return;
      var sug = _construirSugerenciaPrecio(p, costoNuevo, mapaCat, params.idGuia, mapaCanonicos, fifoCtx);
      if (sug) sugerencias.push(sug);
    });
  } catch(eS) {
    Logger.log('Error generando sugerencias: ' + eS.message);
  }

  // 4. Bust cache de operaciones para que se vean los cambios
  try { _almCacheBust(''); } catch(_){}
  return { ok: true, data: {
    lineasActualizadas:    resWh.data && resWh.data.actualizados || 0,
    productosActualizados: actualizadosCosto,
    montoTotalNuevo:       resWh.data && resWh.data.montoTotalNuevo || 0,
    sugerenciasPrecioVenta: sugerencias
  }};
}

// Precarga TODAS las lecturas pesadas que el cálculo FIFO necesita, una
// sola vez. Se pasa como `ctx` a _construirSugerenciaPrecio →
// _calcularLotizacionFIFO + _stockTotalProducto. Si una función recibe
// ctx === null/undefined cae al comportamiento legacy (relee cada vez),
// así nada se rompe si se llama desde otro lado sin ctx.
function _construirFifoCtx() {
  var ctx = {
    guias:        [],
    detalles:     [],
    stockWh:      [],
    stockMeZonas: [],
    equiv:        null
  };
  try { ctx.guias = _safeReadWhGuias(); } catch(_){}
  try { ctx.detalles = _readSheetPreservandoFecha(_abrirWhSheet('GUIA_DETALLE')); } catch(_){}
  try { ctx.stockWh = _safeReadWhStock(); } catch(_){}
  try { ctx.stockMeZonas = _safeReadMeStockZonas(); } catch(_){}
  try { ctx.equiv = _readEquivalencias(); } catch(_){}
  return ctx;
}

// Construye la sugerencia de precio venta para un producto dado un costo nuevo.
// Incluye lotización FIFO: lee guías de ingreso y arma desglose hasta cubrir stock.
// `fifoCtx` (opcional): contexto precargado por _construirFifoCtx para evitar
// relecturas. Si no se pasa, cada sub-función relee (comportamiento legacy).
function _construirSugerenciaPrecio(producto, costoNuevoConIgv, mapaCategorias, idGuiaActual, mapaCanonicos, fifoCtx) {
  var politica = _resolverPoliticaProducto(producto, mapaCategorias, mapaCanonicos);
  var precioVentaActual = parseFloat(producto.precioVenta) || 0;
  var costoAnterior = parseFloat(producto.precioCosto) || 0;
  var sugerido = _calcularPrecioVentaSugerido(costoNuevoConIgv, politica);

  var lotizacion = _calcularLotizacionFIFO(producto, costoNuevoConIgv, idGuiaActual, fifoCtx);

  return {
    idProducto:        producto.idProducto,
    codigoProducto:    producto.codigoBarra || producto.idProducto,
    descripcion:       producto.descripcion || '',
    costoAnterior:     costoAnterior,
    costoNuevo:        costoNuevoConIgv,
    costoPonderado:    lotizacion.costoPonderado,
    precioVentaActual: precioVentaActual,
    precioVentaSugerido: sugerido,
    margenActual:      _calcularMargenReal(precioVentaActual, costoAnterior),
    margenSugerido:    sugerido !== null ? _calcularMargenReal(sugerido, costoNuevoConIgv) : null,
    margenObjetivo:    politica.margenPct,
    modoEfectivo:      politica.modoVenta,
    origenPolitica:    politica.origen,
    precioTope:        politica.precioTope,
    lotizacion:        lotizacion
  };
}

// Lotización FIFO retroactiva:
// - Stock actual del producto (suma WH STOCK + ME STOCK_ZONAS)
// - Lee guías de INGRESO del producto, ordenadas por fecha desc
// - Acumula cantidades hasta cubrir el stock actual
// - Calcula promedio ponderado de los lotes "vivos"
// Excluye la guía actual (ya está representada en costoNuevo).
// `fifoCtx` (opcional): contexto precargado. Si no viene, relee de sheets.
function _calcularLotizacionFIFO(producto, costoNuevoConIgv, idGuiaActual, fifoCtx) {
  var stockTotal = _stockTotalProducto(producto, fifoCtx);
  if (stockTotal <= 0) {
    return { stockTotal: 0, hayLoteAnterior: false, costoPonderado: costoNuevoConIgv, desglose: [] };
  }

  // Construir lista de códigos a buscar (idProducto + codigoBarra principal + equivalencias)
  var codigos = {};
  if (producto.idProducto)  codigos[String(producto.idProducto).toUpperCase()] = true;
  if (producto.codigoBarra) codigos[String(producto.codigoBarra).toUpperCase()] = true;
  try {
    var equiv = (fifoCtx && fifoCtx.equiv) ? fifoCtx.equiv : _readEquivalencias();
    var skuBase = producto.skuBase || producto.idProducto;
    var equivList = equiv.porSku[skuBase] || [];
    equivList.forEach(function(e){ if (e.codigoBarra) codigos[String(e.codigoBarra).toUpperCase()] = true; });
  } catch(_){}

  // Leer GUIAS de WH + GUIA_DETALLE, filtrar ingresos del producto
  var guiasIngreso = [];
  try {
    var guiasRaw = (fifoCtx && fifoCtx.guias) ? fifoCtx.guias : _safeReadWhGuias();
    var guias = guiasRaw.filter(function(g) {
      return String(g.tipo || '').toUpperCase().indexOf('INGRESO') === 0
          && String(g.estado || '').toUpperCase() === 'CERRADA';
    });
    var guiaMap = {};
    guias.forEach(function(g){ guiaMap[g.idGuia] = g; });

    var detalles = (fifoCtx && fifoCtx.detalles)
      ? fifoCtx.detalles
      : _readSheetPreservandoFecha(_abrirWhSheet('GUIA_DETALLE'));
    detalles.forEach(function(d) {
      if (String(d.observacion || '').toUpperCase() === 'ANULADO') return;
      var cb = String(d.codigoProducto || '').toUpperCase();
      if (!codigos[cb]) return;
      var guia = guiaMap[d.idGuia];
      if (!guia) return;
      var cant = parseFloat(d.cantidadRecibida) || 0;
      var precio = parseFloat(d.precioUnitario) || 0;
      if (cant <= 0) return;
      guiasIngreso.push({
        idGuia:  d.idGuia,
        fecha:   guia.fecha || '',
        cantidad: cant,
        costo:   precio,
        esActual: idGuiaActual && String(d.idGuia) === String(idGuiaActual)
      });
    });
  } catch(eR) {
    Logger.log('Lotización: error leyendo guías: ' + eR.message);
  }

  // Ordenar por fecha desc (más reciente primero)
  guiasIngreso.sort(function(a, b){
    var ta = new Date(a.fecha).getTime() || 0;
    var tb = new Date(b.fecha).getTime() || 0;
    return tb - ta;
  });

  // FIFO retroactivo: tomar las últimas guías hasta cubrir stockTotal
  // Para la guía actual usar costoNuevoConIgv (pueden venir del modal ya con costo correcto)
  var pendiente = stockTotal;
  var desglose = [];
  for (var i = 0; i < guiasIngreso.length && pendiente > 0; i++) {
    var g = guiasIngreso[i];
    var costo = g.esActual ? costoNuevoConIgv : g.costo;
    if (costo <= 0) continue; // sin costo registrado, saltar (no ensucia el ponderado)
    var aplica = Math.min(pendiente, g.cantidad);
    desglose.push({
      idGuia:   g.idGuia,
      fecha:    g.fecha,
      cantidad: aplica,
      costo:    costo,
      esActual: g.esActual,
      esNueva:  g.esActual // alias para frontend
    });
    pendiente -= aplica;
  }

  // Promedio ponderado
  var costoPonderado = 0;
  var qtyTotal = 0;
  desglose.forEach(function(d){ costoPonderado += d.costo * d.cantidad; qtyTotal += d.cantidad; });
  costoPonderado = qtyTotal > 0 ? Math.round((costoPonderado / qtyTotal) * 10000) / 10000 : costoNuevoConIgv;

  // ¿Hay lotes anteriores aún vivos?
  var hayLoteAnterior = desglose.some(function(d){ return !d.esActual; });

  return {
    stockTotal: stockTotal,
    cantidadCubierta: stockTotal - pendiente,
    hayLoteAnterior: hayLoteAnterior,
    costoPonderado: costoPonderado,
    desglose: desglose
  };
}

// Suma stock del producto en WH (STOCK) + ME (STOCK_ZONAS).
// `fifoCtx` (opcional): contexto precargado. Si no viene, relee de sheets.
function _stockTotalProducto(producto, fifoCtx) {
  var codigos = {};
  if (producto.idProducto)  codigos[String(producto.idProducto).toUpperCase()] = true;
  if (producto.codigoBarra) codigos[String(producto.codigoBarra).toUpperCase()] = true;
  try {
    var equiv = (fifoCtx && fifoCtx.equiv) ? fifoCtx.equiv : _readEquivalencias();
    var skuBase = producto.skuBase || producto.idProducto;
    (equiv.porSku[skuBase] || []).forEach(function(e){
      if (e.codigoBarra) codigos[String(e.codigoBarra).toUpperCase()] = true;
    });
  } catch(_){}

  var total = 0;
  try {
    var stockWh = (fifoCtx && fifoCtx.stockWh) ? fifoCtx.stockWh : _safeReadWhStock();
    stockWh.forEach(function(s){
      var cb = String(s.codigoProducto || s.codigoBarra || '').toUpperCase();
      if (codigos[cb]) total += parseFloat(s.cantidad) || 0;
    });
  } catch(_){}
  try {
    var stockMe = (fifoCtx && fifoCtx.stockMeZonas) ? fifoCtx.stockMeZonas : _safeReadMeStockZonas();
    stockMe.forEach(function(s){
      var cb = String(s.Cod_Barras || '').toUpperCase();
      if (codigos[cb]) total += parseFloat(s.Cantidad) || 0;
    });
  } catch(_){}
  return total;
}

// Endpoint: aplicar precios de venta sugeridos seleccionados por el usuario
// params: { items: [{idProducto, precioNuevo, motivo}], usuario }
// Retorna: aplicados (canónicos), presentacionesPropagadas, errores
function aplicarPreciosVentaSugeridos(params) {
  if (!Array.isArray(params.items) || !params.items.length) {
    return { ok: false, error: 'items[] requerido' };
  }
  var aplicados = 0, errores = [], presentacionesPropagadas = 0;
  params.items.forEach(function(it) {
    var precio = parseFloat(it.precioNuevo);
    if (!it.idProducto || isNaN(precio) || precio <= 0) { errores.push({ idProducto: it.idProducto, error: 'datos inválidos' }); return; }
    try {
      var r = actualizarProductoMaster({
        _source:      'MOS_MODAL_PRODUCTO',
        idProducto:   it.idProducto,
        precioVenta:  precio,
        usuario:      params.usuario || '',
        motivoPrecio: it.motivo || 'Ajuste por costo de guía'
      });
      if (r && r.ok) {
        aplicados++;
        if (r.data && r.data.presentacionesActualizadas) {
          presentacionesPropagadas += parseInt(r.data.presentacionesActualizadas) || 0;
        }
      } else {
        errores.push({ idProducto: it.idProducto, error: (r && r.error) || 'sin detalle' });
      }
    } catch(e) {
      errores.push({ idProducto: it.idProducto, error: e.message });
    }
  });
  return { ok: true, data: {
    aplicados: aplicados,
    presentacionesPropagadas: presentacionesPropagadas,
    errores: errores
  }};
}

// Detalle de una operación específica (líneas/items)
// ============================================================
// getOperacionesConDetalle — versión enriquecida (v41.11)
// ============================================================
// Devuelve ops + lineas inline en UNA sola respuesta.
// Antes el frontend hacía 1 fetch de ops + N fetches de detalle (uno
// por click expandir). Con muchas ops esto era 50+ requests lentos.
// Ahora 1 lectura de GUIA_DETALLE (WH) + 1 de GUIAS_DETALLE (ME) +
// indexación por idGuia → ops llegan con sus líneas pegadas.
// ============================================================
// imprimirCostosGuia — ESC/POS 80mm con análisis de margen
// ============================================================
// Imprime un reporte físico de la guía de proveedor con:
//   - Cabecera: proveedor, fecha, factura, cajero
//   - Por cada producto (bloque): nombre, cantidad × costo = subtotal,
//     precio venta, margen %, alerta visual según umbral
//   - Total factura, leyenda de alertas, footer
//
// Umbrales globales (v41.22):
//   margen < 20%  → [ /!\ MARGEN BAJO ]
//   20% ≤ x ≤ 60% → [ OK -- margen normal ]
//   margen > 60%  → [ * MARGEN ALTO ]
//
// params: { idGuia, printerId }
function imprimirCostosGuia(params) {
  if (!params || !params.idGuia)  return { ok: false, error: 'idGuia requerido' };
  if (!params.printerId)          return { ok: false, error: 'printerId requerido' };

  var pnKey = PropertiesService.getScriptProperties().getProperty('PRINTNODE_API_KEY');
  if (!pnKey) return { ok: false, error: 'PRINTNODE_API_KEY no configurado' };

  // ── 1. Cargar guía cabecera ──
  var idGuia = String(params.idGuia);
  var whGuias = _safeReadWhGuias();
  var guia = whGuias.find(function(g){ return String(g.idGuia) === idGuia; });
  if (!guia) return { ok: false, error: 'Guía no encontrada en WH' };

  // ── 2. Cargar líneas de detalle ──
  var det;
  try {
    var detSh = _abrirWhSheet('GUIA_DETALLE');
    if (!detSh) return { ok: false, error: 'GUIA_DETALLE no encontrada' };
    var allDet = _sheetToObjects(detSh);
    det = allDet.filter(function(l){ return String(l.idGuia) === idGuia; });
  } catch(e) { return { ok: false, error: 'Error leyendo detalle: ' + e.message }; }
  if (!det.length) return { ok: false, error: 'Guía sin líneas' };

  // ── 3. Cruzar con catálogo MOS (precio venta actual) ──
  var prodLookup = _buildProdLookup();

  // ── 4. Resolver nombre proveedor ──
  var nombreProv = '';
  try {
    var provs = _sheetToObjects(getSheet('PROVEEDORES_MASTER'));
    var pr = provs.find(function(p){ return String(p.idProveedor) === String(guia.idProveedor || ''); });
    if (pr) nombreProv = pr.nombre || pr.idProveedor;
  } catch(_){}
  if (!nombreProv) nombreProv = guia.idProveedor || '(sin proveedor)';

  // ── 5. Generar ESC/POS ──
  var tz = Session.getScriptTimeZone();
  var ahora = Utilities.formatDate(new Date(), tz, 'dd/MM/yyyy HH:mm');
  var fechaGuia = '';
  try {
    var fg = guia.fecha instanceof Date ? guia.fecha : new Date(guia.fecha);
    if (!isNaN(fg.getTime())) fechaGuia = Utilities.formatDate(fg, tz, 'dd/MM/yy HH:mm');
  } catch(_){}

  var W = 32;            // 80mm typical
  var SEP = '================================';
  var SEPd = '--------------------------------';
  function _pad(s, n) { s = String(s || ''); while (s.length < n) s += ' '; return s; }
  function _norm(s) {
    // Quitar tildes y caracteres raros para impresora ESC/POS sin codepage configurado
    return String(s || '')
      .replace(/[áàäâ]/gi, 'a').replace(/[éèëê]/gi, 'e')
      .replace(/[íìïî]/gi, 'i').replace(/[óòöô]/gi, 'o')
      .replace(/[úùüû]/gi, 'u').replace(/ñ/g, 'n').replace(/Ñ/g, 'N')
      .replace(/[^\x20-\x7e]/g, '');
  }

  var txt = '';
  // Reset + Center
  txt += '\x1b\x40';                            // ESC @ reset
  txt += '\x1b\x61\x01';                        // center
  // Título doble alto
  txt += '\x1b\x21\x10' + _norm('INVERSION MOS SAC') + '\x1b\x21\x00\n';
  txt += _norm('REPORTE COSTOS INGRESO') + '\n';
  txt += SEP + '\n';
  // Volver a left align
  txt += '\x1b\x61\x00';
  txt += _pad('Guia:', 11) + _norm(idGuia) + '\n';
  txt += _pad('Fecha:', 11) + (fechaGuia || ahora) + '\n';
  txt += _pad('Proveedor:', 11) + _norm(nombreProv).substring(0, W - 11) + '\n';
  if (guia.numeroDocumento) txt += _pad('Factura:', 11) + _norm(guia.numeroDocumento).substring(0, W - 11) + '\n';
  if (guia.usuario)         txt += _pad('Cajero:', 11)  + _norm(guia.usuario) + '\n';

  txt += SEPd + '\n';
  txt += '\x1b\x61\x01PRODUCTOS Y MARGENES\x1b\x61\x00\n';
  txt += SEPd + '\n\n';

  // [v2.41.54] Margen objetivo para sugerir precio venta cuando el actual
  // no existe o queda fuera del rango sano (cálculo simple, mismo umbral
  // que la leyenda). 40% se usa como "redondeo dulce" para venta minorista.
  var MARGEN_OBJETIVO = 0.40;

  var totalFactura = 0;
  det.forEach(function(l) {
    var p = prodLookup[l.codigoProducto] || {};
    var cant = parseFloat(l.cantidadRecibida || l.cantidad) || parseFloat(l.cantidadEsperada) || 0;
    var costo = parseFloat(l.precioUnitario) || 0;
    var subtotal = costo * cant;
    totalFactura += subtotal;
    var precioVenta = parseFloat(p.precioVenta) || 0;
    var margenPct = costo > 0 ? ((precioVenta - costo) / costo) * 100 : null;
    // Umbrales globales v41.22
    var alertaTxt;
    if (margenPct === null || precioVenta <= 0) alertaTxt = '[ sin precio venta ]';
    else if (margenPct < 20)  alertaTxt = '[ /!\\ MARGEN BAJO ]';
    else if (margenPct > 60)  alertaTxt = '[ * MARGEN ALTO ]';
    else                      alertaTxt = '[ OK margen normal ]';

    // [v2.41.54] Precio venta SUGERIDO — solo si actual no existe o margen <20%
    var precioSugerido = null;
    if (costo > 0 && (precioVenta <= 0 || (margenPct !== null && margenPct < 20))) {
      precioSugerido = Math.round(costo * (1 + MARGEN_OBJETIVO) * 10) / 10; // redondeo a 0.10
    }

    var nombre = _norm(p.descripcion || l.codigoProducto || '').substring(0, W);
    txt += '\x1b\x21\x08' + nombre + '\x1b\x21\x00\n';  // bold
    txt += '  ' + cant + 'u x S/ ' + costo.toFixed(2) + ' = S/' + subtotal.toFixed(2) + '\n';
    if (precioVenta > 0) {
      var signo = margenPct >= 0 ? '+' : '';
      txt += '  >> P.Venta: S/ ' + precioVenta.toFixed(2)
           + ' (' + signo + (margenPct === null ? '?' : margenPct.toFixed(0)) + '%)\n';
    } else {
      txt += '  >> P.Venta: (sin definir)\n';
    }
    // [v2.41.54] Línea sugerencia para que la jefa sepa cuánto cobrar
    if (precioSugerido !== null) {
      var sugMargenPct = Math.round(MARGEN_OBJETIVO * 100);
      txt += '\x1b\x21\x08';                 // bold ON
      txt += '  $$ SUGERIDO: S/ ' + precioSugerido.toFixed(2)
           + ' (+' + sugMargenPct + '%)\n';
      txt += '\x1b\x21\x00';                 // bold OFF
    }
    txt += '  ' + alertaTxt + '\n\n';
  });

  txt += SEPd + '\n';
  txt += '\x1b\x21\x10' + _pad('TOTAL FACTURA:', 16) + 'S/' + totalFactura.toFixed(2) + '\x1b\x21\x00\n';
  txt += SEPd + '\n\n';

  // Leyenda
  txt += 'LEYENDA:\n';
  txt += '  OK   margen 20-60% normal\n';
  txt += '  /!\\  margen < 20% revisar\n';
  txt += '  *    margen > 60% alto\n';
  txt += '  $$   precio venta sugerido\n';
  txt += '       (margen 40% redondeo 0.10)\n\n';

  // Footer
  txt += '\x1b\x61\x01';
  txt += ahora + ' - MOSexpress\n';
  // Cortar papel
  txt += '\n\n\n\n\x1d\x56\x00';

  // ── 6. Enviar a PrintNode ──
  var bytes = [];
  for (var ci = 0; ci < txt.length; ci++) bytes.push(txt.charCodeAt(ci) & 0xFF);
  var content = Utilities.base64Encode(bytes);

  try {
    var resp = UrlFetchApp.fetch('https://api.printnode.com/printjobs', {
      method:      'post',
      headers:     { 'Authorization': 'Basic ' + Utilities.base64Encode(pnKey + ':') },
      contentType: 'application/json',
      payload:     JSON.stringify({
        printerId:   parseInt(String(params.printerId), 10),
        title:       'Costos Guia ' + idGuia + ' - ' + nombreProv,
        contentType: 'raw_base64',
        content:     content,
        source:      'ProyectoMOS-Ops'
      }),
      muteHttpExceptions: true
    });
    var code = resp.getResponseCode();
    if (code !== 201) {
      return { ok: false, error: 'PrintNode HTTP ' + code + ': ' + resp.getContentText().substring(0, 200) };
    }
    return { ok: true, jobId: resp.getContentText(), totalFactura: totalFactura };
  } catch(e) {
    return { ok: false, error: 'PrintNode fallo: ' + e.message };
  }
}

function getOperacionesConDetalle(params) {
  var dias = parseInt(params && params.dias) || 7;
  // Cache subido a 5min (era 60s): los detalles cambian poco y el endpoint
  // es pesado (lee múltiples sheets enteras). User puede forzar con _refresh.
  // [v41.22] key bumpeada para invalidar cache sin op.preingreso anidado
  return _almCached('opsConDetV3_' + dias, 300, params, function() {
    var base = _getOperacionesUnificadasImpl(dias);
    if (!base.ok || !base.data) return base;

    var diagWH = 0, diagME = 0, diagLinWH = 0, diagLinME = 0;
    try {
      var prodLookup = _buildProdLookup();

      // ── 0. Construir Set de idGuia válidos por fuente (solo del rango) ──
      // CLAVE OPTIMIZACIÓN: en lugar de leer TODO el histórico de detalle
      // y mapearlo, filtramos solo las líneas de las ops que están en el
      // rango. Reduce trabajo 10x si hay muchos meses de histórico.
      var validWH = {}, validME = {};
      (base.data.porDia || []).forEach(function(dia) {
        (dia.operaciones || []).forEach(function(op) {
          if (op.esPreingreso) return;
          var id = String(op.idGuia || '');
          if (!id) return;
          if (op.fuente === 'WH') { validWH[id] = true; diagWH++; }
          else                    { validME[id] = true; diagME++; }
        });
      });

      // ── 1. WH GUIA_DETALLE — solo idGuias del rango ──
      var lineasWH = {};
      try {
        var whSheet = _abrirWhSheet('GUIA_DETALLE');
        if (whSheet) {
          var allDet = _sheetToObjects(whSheet);
          allDet.forEach(function(l) {
            var id = String(l.idGuia || '');
            if (!id || !validWH[id]) return;
            var p = prodLookup[l.codigoProducto] || {};
            var esEquiv = p.idProducto && p.idProducto !== l.codigoProducto && p.codigoBarra !== l.codigoProducto;
            var cant = parseFloat(l.cantidadRecibida || l.cantidad) || parseFloat(l.cantidadEsperada) || 0;
            var precio = parseFloat(l.precioUnitario) || 0;
            (lineasWH[id] = lineasWH[id] || []).push({
              idDetalle:         l.idDetalle || '',
              codigoProducto:    l.codigoProducto,
              codigoBarra:       l.codigoProducto,
              descripcion:       p.descripcion || ('⚠ ' + l.codigoProducto + ' (no en catálogo)'),
              esEquivalencia:    esEquiv,
              cantidad:          cant,
              precioUnitario:    precio,
              subtotal:          cant * precio,
              fechaVencimiento:  l.fechaVencimiento || '',
              precioVentaActual: parseFloat(p.precioVenta) || 0,  // [v41.23] catálogo MOS
              precioCostoActual: parseFloat(p.precioCosto) || 0,
              categoria:         p.categoria || ''
            });
            diagLinWH++;
          });
        }
      } catch(_){}

      // ── 2. ME GUIAS_DETALLE — solo idGuias del rango ──
      var lineasME = {};
      try {
        var ssMe = SpreadsheetApp.openById(_getProp('ME_SS_ID'));
        var shGD = ssMe.getSheetByName('GUIAS_DETALLE');
        if (shGD) {
          var data = shGD.getDataRange().getValues();
          for (var i = 1; i < data.length; i++) {
            var id = String(data[i][0] || '');
            if (!id || !validME[id]) continue;
            var cb = String(data[i][1] || '').trim();
            var p = prodLookup[cb] || {};
            var esEquivME = p.idProducto && p.codigoBarra !== cb;
            var cantME = parseFloat(data[i][2]) || 0;
            var precioME = parseFloat(p.precioVenta) || 0;
            (lineasME[id] = lineasME[id] || []).push({
              codigoBarra:       cb,
              descripcion:       p.descripcion || ('⚠ ' + cb + ' (no en catálogo)'),
              esEquivalencia:    esEquivME,
              cantidad:          cantME,
              precioUnitario:    precioME,
              subtotal:          cantME * precioME,
              precioVentaActual: precioME,  // [v41.23] mismo dato (ME guarda venta no costo)
              precioCostoActual: parseFloat(p.precioCosto) || 0,
              categoria:         p.categoria || ''
            });
            diagLinME++;
          }
        }
      } catch(_){}

      // ── 3. Embeber lineas en cada op ──
      (base.data.porDia || []).forEach(function(dia) {
        (dia.operaciones || []).forEach(function(op) {
          if (op.esPreingreso) { op.lineas = []; op.lineasCount = 0; return; }
          var src = (op.fuente === 'WH') ? lineasWH : lineasME;
          var ls = src[String(op.idGuia)] || [];
          op.lineas = ls;
          op.lineasCount = ls.length;
          if (!op.montoTotal) {
            op.montoTotal = ls.reduce(function(s, l){ return s + (l.subtotal || 0); }, 0);
          }
        });
      });

      base.data._conDetalle = true;
      base.data._diagDet = {
        opsWH: diagWH, opsME: diagME,
        linWH: diagLinWH, linME: diagLinME
      };
      return base;
    } catch(e) {
      base.data._detError = e.message;
      return base;
    }
  });
}

function getOperacionDetalle(params) {
  if (!params || !params.fuente || !params.idGuia) {
    return { ok: false, error: 'Requiere fuente y idGuia' };
  }
  try {
    var prodLookup = _buildProdLookup();
    if (params.fuente === 'WH') {
      var whSheet = _abrirWhSheet('GUIA_DETALLE');
      if (!whSheet) return { ok: false, error: 'GUIA_DETALLE no encontrada en WH' };
      var allDet = _sheetToObjects(whSheet);
      var lineas = allDet.filter(function(d){ return String(d.idGuia) === String(params.idGuia); });
      lineas = lineas.map(function(l) {
        var p = prodLookup[l.codigoProducto] || {};
        var esEquiv = p.idProducto && p.idProducto !== l.codigoProducto && p.codigoBarra !== l.codigoProducto;
        var cant = parseFloat(l.cantidadRecibida || l.cantidad) || parseFloat(l.cantidadEsperada) || 0;
        var precio = parseFloat(l.precioUnitario) || 0;
        return {
          idDetalle:         l.idDetalle || '',
          codigoProducto:    l.codigoProducto,
          descripcion:       p.descripcion || '⚠ ' + l.codigoProducto + ' (no en catálogo)',
          esEquivalencia:    esEquiv,
          cantidad:          cant,
          precioUnitario:    precio,
          subtotal:          cant * precio,
          fechaVencimiento:  l.fechaVencimiento || '',
          precioVentaActual: parseFloat(p.precioVenta) || 0,   // [v41.23]
          precioCostoActual: parseFloat(p.precioCosto) || 0,
          categoria:         p.categoria || ''
        };
      });
      return { ok: true, data: { fuente: 'WH', idGuia: params.idGuia, lineas: lineas } };
    } else if (params.fuente === 'ME') {
      var ssMe = SpreadsheetApp.openById(_getProp('ME_SS_ID'));
      var shGD = ssMe.getSheetByName('GUIAS_DETALLE');
      if (!shGD) return { ok: false, error: 'GUIAS_DETALLE no encontrada en ME' };
      var data = shGD.getDataRange().getValues();
      var lineas = [];
      // Schema ME GUIAS_DETALLE: ID_Guia | Cod_Barras | Cantidad
      for (var i = 1; i < data.length; i++) {
        if (String(data[i][0]) !== String(params.idGuia)) continue;
        var cb = String(data[i][1] || '').trim();
        var p = prodLookup[cb] || {};
        var esEquivME = p.idProducto && p.codigoBarra !== cb;
        lineas.push({
          codigoBarra:    cb,
          descripcion:    p.descripcion || '⚠ ' + cb + ' (no en catálogo)',
          esEquivalencia: esEquivME,
          cantidad:       parseFloat(data[i][2]) || 0,
          precioUnitario: parseFloat(p.precioVenta) || 0,
          subtotal:       (parseFloat(data[i][2]) || 0) * (parseFloat(p.precioVenta) || 0)
        });
      }
      return { ok: true, data: { fuente: 'ME', idGuia: params.idGuia, lineas: lineas } };
    }
    return { ok: false, error: 'Fuente desconocida: ' + params.fuente };
  } catch(e) {
    return { ok: false, error: 'Error detalle operación: ' + e.message };
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
  // Usa lectura raw para preservar la hora completa (no truncar a yyyy-MM-dd)
  try { return _readSheetPreservandoFecha(_abrirWhSheet('GUIAS')); } catch(e) { return []; }
}
function _safeReadWhPreingresos() {
  try { return _readSheetPreservandoFecha(_abrirWhSheet('PREINGRESOS')); } catch(e) { return []; }
}

// Variante de _sheetToObjects que conserva los Date como ISO completo
// (necesaria para Operaciones, donde la hora del día sí importa).
function _readSheetPreservandoFecha(sheet) {
  var data = sheet.getDataRange().getValues();
  if (data.length < 2) return [];
  var headers = data[0].map(function(h){ return String(h).trim(); });
  return data.slice(1).map(function(row){
    var obj = {};
    headers.forEach(function(h, i){
      if (!h) return;
      var v = row[i];
      if (v instanceof Date) {
        obj[h] = v.toISOString();
      } else if (typeof v === 'string' && /^\d+,\d+$/.test(v.trim())) {
        obj[h] = parseFloat(v.trim().replace(',', '.'));
      } else {
        obj[h] = v;
      }
    });
    return obj;
  }).filter(function(obj){
    return Object.values(obj).some(function(v){ return v !== '' && v !== null && v !== undefined; });
  });
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

    // Mapa cb/idProd → CANÓNICO (incluye presentaciones, derivados y equivalentes)
    var mapaCanon = _construirMapaCBaCanonico();
    var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));

    // 1. Vendidos POR CANÓNICO (cualquier variante o equivalente cuenta como venta del canónico)
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
    var canonicosVendidos = {};   // { idProductoCanon: true }
    for (var j = 1; j < dataVD.length; j++) {
      if (!ventasIds[String(dataVD[j][0] || '').trim()]) continue;
      var sku = String(dataVD[j][1] || '').trim().toUpperCase();
      var cb  = String(dataVD[j][6] || '').trim().toUpperCase();
      var canon = (sku && mapaCanon[sku]) || (cb && mapaCanon[cb]);
      if (!canon) continue;
      canonicosVendidos[String(canon.idProducto).toUpperCase()] = true;
    }

    // 2. Stock POR CANÓNICO en zonas (suma todas las variantes)
    var stockZonas = _safeReadMeStockZonas();
    var resolver = _buildZonaResolver();
    var stockPorCanon = {};  // { idProductoCanon: { canon, total, porZona: {canonId: cant}, nombres: {} } }
    stockZonas.forEach(function(z) {
      var cb = String(z.Cod_Barras || z.codigoBarra || '').trim();
      var qty = parseFloat(z.Cantidad || z.cantidad) || 0;
      if (!cb || qty <= 0) return;
      var canon = mapaCanon[cb.toUpperCase()];
      if (!canon) return;
      var key = String(canon.idProducto).toUpperCase();
      var zid = String(z.Zona_ID || '').trim();
      var canonZ = zid ? resolver.resolve(zid) : null;
      if (!stockPorCanon[key]) stockPorCanon[key] = { canon: canon, total: 0, porZona: {}, nombres: {} };
      stockPorCanon[key].total += qty;
      if (canonZ) {
        stockPorCanon[key].porZona[canonZ.id] = (stockPorCanon[key].porZona[canonZ.id] || 0) + qty;
        stockPorCanon[key].nombres[canonZ.id] = canonZ.nombre;
      }
    });

    // 3. Canónicos con stock pero ninguna variante vendida en el rango
    var sinVenta = [];
    Object.keys(stockPorCanon).forEach(function(keyP) {
      if (canonicosVendidos[keyP]) return;
      var info = stockPorCanon[keyP];
      var p = info.canon;
      if (info.total <= 0) return;
      var breakdown = Object.keys(info.porZona).map(function(zid) {
        return { idZona: zid, nombre: info.nombres[zid] || zid, cantidad: info.porZona[zid] };
      }).sort(function(a, b){ return b.cantidad - a.cantidad; });
      sinVenta.push({
        idProducto:   p.idProducto,
        skuBase:      p.skuBase,
        descripcion:  p.descripcion,
        codigoBarra:  p.codigoBarra,
        precioVenta:  parseFloat(p.precioVenta) || 0,
        stockEnZonas: info.total,
        breakdownZonas: breakdown
      });
    });
    sinVenta.sort(function(a, b){ return b.stockEnZonas - a.stockEnZonas; });

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
    // Mapa cb/idProd → CANÓNICO (resuelve presentaciones, derivados y equivalentes)
    var mapaCanon = _construirMapaCBaCanonico();

    // Acumular stock WH POR CANÓNICO
    var stockWhPorCanon = {};   // { idProductoCanon: cantidad }
    stockWh.forEach(function(s) {
      var cp = String(s.codigoProducto || '').trim();
      if (!cp) return;
      var canon = mapaCanon[cp.toUpperCase()];
      if (!canon) return;
      var key = String(canon.idProducto).toUpperCase();
      stockWhPorCanon[key] = (stockWhPorCanon[key] || 0) + (parseFloat(s.cantidadDisponible) || 0);
    });

    // 1. Canónicos con stock crítico (< mínimo) — agrupa todas sus variantes
    var critCount = 0, critTop = [];
    productos.forEach(function(p) {
      if (!_esCanonico(p)) return;  // solo canónicos definen mínimo
      var min = parseFloat(p.stockMinimo) || 0;
      if (min <= 0) return;
      var keyP = String(p.idProducto).toUpperCase();
      var cant = stockWhPorCanon[keyP] || 0;
      if (cant < min) {
        critCount++;
        if (critTop.length < 5) {
          critTop.push({
            idProducto: p.idProducto,
            descripcion: p.descripcion,
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
// AUTO-AJUSTE DE stockMinimo / stockMaximo SEMANAL
// ----------------------------------------------------------
// Reescribe los mín/máx en PRODUCTOS_MASTER (canónico de cada sku) en
// función de las ventas reales de los últimos 28 días.
//   stockMinimo = ventasSemana
//   stockMaximo = ventasSemana × 1.2  (techo seguro 20% sobre demanda)
// Suma TODAS las presentaciones + códigos equivalentes del sku.
// Se ejecuta on-demand, frontend lo dispara cada 12h desde el prefetch.
// ============================================================
function recalcularStockMinMaxAuto(params) {
  var rangoDias = parseInt(params && params.dias) || 28;
  var hoy = new Date();
  var desde = new Date(hoy.getTime() - rangoDias * 86400000);
  try {
    // 1. Master + indices + identificar fila del canónico de cada sku
    var sheetMaster = getSheet('PRODUCTOS_MASTER');
    var data = sheetMaster.getDataRange().getValues();
    var hdrs = data[0];
    var iId  = hdrs.indexOf('idProducto');
    var iSku = hdrs.indexOf('skuBase');
    var iCB  = hdrs.indexOf('codigoBarra');
    var iMin = hdrs.indexOf('stockMinimo');
    var iMax = hdrs.indexOf('stockMaximo');
    var iFC  = hdrs.indexOf('factorConversion');
    var iCPB = hdrs.indexOf('codigoProductoBase');
    if (iMin < 0 || iMax < 0) return { ok: false, error: 'PRODUCTOS_MASTER sin columnas stockMinimo/stockMaximo' };

    var prodById = {}, prodByCB = {}, bySku = {};
    var rowCanonBySku = {};  // sku → fila (1-based) del canónico
    for (var i = 1; i < data.length; i++) {
      var p = {
        idProducto:         data[i][iId],
        skuBase:            data[i][iSku],
        codigoBarra:        data[i][iCB],
        codigoProductoBase: data[i][iCPB],
        factorConversion:   data[i][iFC],
        rowIdx:             i + 1
      };
      prodById[p.idProducto] = p;
      if (p.codigoBarra) prodByCB[p.codigoBarra] = p;
      var sku = p.skuBase || p.idProducto;
      if (!bySku[sku]) bySku[sku] = [];
      bySku[sku].push(p);
      // Canónico: idProducto === skuBase ó factorConversion=1 sin codigoProductoBase
      var fc = parseFloat(p.factorConversion) || 1;
      var esCanon = (p.idProducto === sku) ||
                    (fc === 1 && !String(p.codigoProductoBase || '').trim());
      if (esCanon && !rowCanonBySku[sku]) rowCanonBySku[sku] = p.rowIdx;
    }
    // Si algún sku no tuvo canónico explícito, usar el primer producto
    Object.keys(bySku).forEach(function(sku){
      if (!rowCanonBySku[sku]) rowCanonBySku[sku] = bySku[sku][0].rowIdx;
    });

    // 2. Equivalencias: ampliar prodByCB para que ventas con código
    //    alterno se mapeen al sku correcto
    try {
      var equiv = _readEquivalencias();
      Object.keys(equiv.porSku || {}).forEach(function(sku){
        if (!bySku[sku]) return;
        (equiv.porSku[sku] || []).forEach(function(eq){
          if (!prodByCB[eq.codigoBarra]) prodByCB[eq.codigoBarra] = bySku[sku][0];
        });
      });
    } catch(_){}

    // 3. Ventas en rango por sku (suma todas las presentaciones + equivalentes)
    var ventasBySku = {};
    try {
      var ssMe = SpreadsheetApp.openById(_getProp('ME_SS_ID'));
      var shVC = ssMe.getSheetByName('VENTAS_CABECERA');
      var shVD = ssMe.getSheetByName('VENTAS_DETALLE');
      if (shVC && shVD) {
        var dataVC = shVC.getDataRange().getValues();
        var idsValidas = {};
        for (var k = 1; k < dataVC.length; k++) {
          var fecha = dataVC[k][1] ? new Date(dataVC[k][1]) : null;
          if (!fecha || fecha < desde) continue;
          if (String(dataVC[k][8] || '').toUpperCase() === 'ANULADO') continue;
          idsValidas[String(dataVC[k][0] || '').trim()] = true;
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

    // 4. Calcular nuevos mín/máx y escribir al canónico de cada sku
    var actualizados = 0, sinVentas = 0, errores = 0, sinCambio = 0;
    var semanas = rangoDias / 7;
    var detalle = [];  // log para debug
    Object.keys(bySku).forEach(function(sku) {
      var totalVentas = ventasBySku[sku] || 0;
      if (totalVentas <= 0) { sinVentas++; return; }
      var ventasSemana = totalVentas / semanas;
      var nuevoMin = Math.ceil(ventasSemana);
      var nuevoMax = Math.ceil(ventasSemana * 1.2);
      var rowIdx = rowCanonBySku[sku];
      if (!rowIdx) { errores++; return; }
      try {
        var minActual = parseFloat(data[rowIdx - 1][iMin]) || 0;
        var maxActual = parseFloat(data[rowIdx - 1][iMax]) || 0;
        if (minActual === nuevoMin && maxActual === nuevoMax) { sinCambio++; return; }
        sheetMaster.getRange(rowIdx, iMin + 1).setValue(nuevoMin);
        sheetMaster.getRange(rowIdx, iMax + 1).setValue(nuevoMax);
        actualizados++;
        if (detalle.length < 20) {
          detalle.push({ sku: sku, ventasSem: Math.round(ventasSemana), min: nuevoMin, max: nuevoMax });
        }
      } catch(_){ errores++; }
    });

    PropertiesService.getScriptProperties().setProperty('LAST_AUTO_MINMAX', String(Date.now()));
    return {
      ok: true,
      data: {
        actualizados: actualizados,
        sinCambio:    sinCambio,
        sinVentas:    sinVentas,
        errores:      errores,
        ventana:      rangoDias + ' días',
        sample:       detalle
      }
    };
  } catch(e) {
    return { ok: false, error: 'Error auto-min-max: ' + e.message };
  }
}

// Devuelve el timestamp del último recálculo (para throttle desde frontend)
function getLastAutoMinMaxTs() {
  try {
    var ts = PropertiesService.getScriptProperties().getProperty('LAST_AUTO_MINMAX');
    return { ok: true, data: { ts: parseInt(ts) || 0 } };
  } catch(e) { return { ok: false, error: e.message }; }
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
    // Mapa cb/idProd → CANÓNICO (incluye presentaciones, derivados y equivalencias)
    var mapaCanon = _construirMapaCBaCanonico();
    function _aCanon(cod) {
      if (!cod) return null;
      return mapaCanon[String(cod).toUpperCase()] || null;
    }
    // Compatibilidad: prodById se usa para nombres si llega un cb no resuelto
    var prodById = {}; productos.forEach(function(p){
      prodById[p.idProducto] = p;
      if (p.codigoBarra) prodById[p.codigoBarra] = p;
    });
    var resolver = _buildZonaResolver();
    // Set ESTRICTO de zonas registradas en MOS.ZONAS (filtra TRASLADAR a zonas inventadas)
    var zonasMOS = _sheetToObjects(getSheet('ZONAS'));
    var zonasRegistradasSet = {};
    var zonaNombre = {};
    zonasMOS.forEach(function(z) {
      if (!z.idZona) return;
      var ac = z.estado;
      var activa = (ac === undefined || ac === '' || ac === 1 || ac === '1' || ac === true);
      if (!activa) return;
      var canon = resolver.resolve(z.idZona);
      zonasRegistradasSet[canon.id] = true;
      zonaNombre[canon.id] = canon.nombre;
    });

    // Acumular stock POR CANÓNICO en zonas (presentaciones + equivalentes suman al mismo canónico)
    var stockCanonMap = {};   // { idProductoCanon: { canon, total, zonas: {zid: qty} } }
    stockZonas.forEach(function(z) {
      var cb = String(z.Cod_Barras || z.codigoBarra || '').trim();
      var qty = parseFloat(z.Cantidad || z.cantidad) || 0;
      if (!cb || qty <= 0) return;
      var canon = _aCanon(cb);
      if (!canon) return;
      var key = String(canon.idProducto).toUpperCase();
      if (!stockCanonMap[key]) stockCanonMap[key] = { canon: canon, total: 0, zonas: {} };
      stockCanonMap[key].total += qty;
      var zid = String(z.Zona_ID || '').trim();
      var canonZ = resolver.resolve(zid);
      stockCanonMap[key].zonas[canonZ.id] = (stockCanonMap[key].zonas[canonZ.id] || 0) + qty;
      zonaNombre[canonZ.id] = canonZ.nombre;
    });

    // Calcular ventas POR CANÓNICO + zona
    var ventasCanonMap = {}; // { idProductoCanon: { canonZonaId: cantidad } }
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
          var canonV2 = _aCanon(cb);
          if (!canonV2) continue;
          var keyV = String(canonV2.idProducto).toUpperCase();
          var cant = parseFloat(dataVD[j][3]) || 0;
          if (!ventasCanonMap[keyV]) ventasCanonMap[keyV] = {};
          ventasCanonMap[keyV][zona] = (ventasCanonMap[keyV][zona] || 0) + cant;
        }
      }
    } catch(_){}

    // INSIGHT 1 — Canónicos con stock alto y sin venta en N días
    Object.keys(stockCanonMap).forEach(function(keyC) {
      var info = stockCanonMap[keyC];
      var ventasProd = ventasCanonMap[keyC] || {};
      var ventasTot = Object.values(ventasProd).reduce(function(s, v){ return s + v; }, 0);
      if (info.total >= 10 && ventasTot === 0) {
        var prod = info.canon;
        insights.push({
          tipo: 'SIN_ROTACION',
          severidad: 'MEDIA',
          producto: prod.descripcion || keyC,
          codigoBarra: prod.codigoBarra || keyC,
          idProducto: prod.idProducto,
          skuBase:    prod.skuBase || '',
          stock: info.total,
          mensaje: prod.descripcion + ' tiene ' + info.total + 'u sin venta en ' + rangoDias + ' días',
          accion: 'Lanzar promo o trasladar a otra zona'
        });
      }
    });

    // Pre-cálculo: stock WH POR CANÓNICO (suma todos los códigos del mismo canónico, incluidos equivalentes)
    var stockWhPorCanon = {};
    stockWh.forEach(function(s) {
      var cp = String(s.codigoProducto || '').trim();
      if (!cp) return;
      var canon = _aCanon(cp);
      if (!canon) return;
      var key = String(canon.idProducto).toUpperCase();
      stockWhPorCanon[key] = (stockWhPorCanon[key] || 0) + (parseFloat(s.cantidadDisponible) || 0);
    });

    // INSIGHT 2a — DESPACHAR DESDE WH (primera opción cuando una zona se queda sin stock)
    // INSIGHT 2b — TRASLADAR ENTRE ZONAS (solo si WH NO tiene stock disponible)
    Object.keys(ventasCanonMap).forEach(function(keyC) {
      var ventasProd = ventasCanonMap[keyC];
      var stockInfo = stockCanonMap[keyC] || { zonas: {} };
      var prod = (stockCanonMap[keyC] && stockCanonMap[keyC].canon) || _aCanon(keyC);
      if (!prod) return;
      var cb = prod.codigoBarra || keyC;
      Object.keys(ventasProd).forEach(function(zonaVendedora) {
        if (!zonasRegistradasSet[zonaVendedora]) return;
        var ventas = ventasProd[zonaVendedora];
        var stockEnEsa = stockInfo.zonas[zonaVendedora] || 0;
        var rotacionDia = ventas / rangoDias;
        if (rotacionDia <= 0) return;
        var diasRestantes = stockEnEsa / rotacionDia;
        // Solo nos interesa si la zona se queda sin stock pronto
        if (diasRestantes >= 7 || diasRestantes < 0) return;
        var nombreDestino = zonaNombre[zonaVendedora] || zonaVendedora;
        var stockWhDisp = stockWhPorCanon[keyC] || 0;
        var cantidadSugerida = Math.ceil(rotacionDia * 14);

        // 2a. PRIMERA OPCIÓN: ¿Hay stock en WH para despachar?
        if (stockWhDisp >= cantidadSugerida) {
          insights.push({
            tipo: 'DESPACHAR_DESDE_WH',
            severidad: diasRestantes < 3 ? 'CRITICA' : 'ALTA',
            producto: prod.descripcion || cb,
            codigoBarra: cb,
            idProducto: prod.idProducto,
            skuBase:    prod.skuBase || '',
            mensaje: 'Despachar de 🏭 WH → ' + nombreDestino + ': ' + nombreDestino + ' tiene ' + stockEnEsa + 'u (alcanza ' + Math.floor(diasRestantes) + 'd) y vende ' + Math.round(rotacionDia * 10) / 10 + '/d. WH dispone de ' + stockWhDisp + 'u (todas las variantes).',
            accion: 'Despachar ' + cantidadSugerida + 'u (cobertura 2 semanas)',
            desde: 'WH',
            hacia: zonaVendedora,
            cantidadSugerida: cantidadSugerida,
            stockWh: stockWhDisp
          });
          return;
        }

        // 2b. SEGUNDA OPCIÓN: WH no tiene → buscar otra zona con stock ocioso
        var trasladosCandidatos = [];
        Object.keys(stockInfo.zonas).forEach(function(zonaConStock) {
          if (zonaConStock === zonaVendedora) return;
          if (!zonasRegistradasSet[zonaConStock]) return;
          var stockOtra = stockInfo.zonas[zonaConStock] || 0;
          var ventasOtra = (ventasProd[zonaConStock] || 0);
          if (stockOtra >= 5 && ventasOtra < ventas / 3) {
            trasladosCandidatos.push({
              zonaOrigen: zonaConStock,
              stockOrigen: stockOtra,
              cantSugerida: Math.min(stockOtra, cantidadSugerida)
            });
          }
        });
        if (trasladosCandidatos.length > 0) {
          var mejor = trasladosCandidatos[0];
          var nombreOrigen = zonaNombre[mejor.zonaOrigen] || mejor.zonaOrigen;
          insights.push({
            tipo: 'TRASLADAR',
            severidad: 'MEDIA',
            producto: prod.descripcion || cb,
            codigoBarra: cb,
            idProducto: prod.idProducto,
            skuBase:    prod.skuBase || '',
            mensaje: '🏭 WH sin stock — Trasladar de ' + nombreOrigen + ' (' + mejor.stockOrigen + 'u, sin venta) → ' + nombreDestino + ' (vende ' + Math.round(rotacionDia * 10) / 10 + '/d, alcanza ' + Math.floor(diasRestantes) + 'd)',
            accion: 'Mover ' + mejor.cantSugerida + 'u entre zonas (operación manual)',
            desde: mejor.zonaOrigen,
            hacia: zonaVendedora,
            cantidadSugerida: mejor.cantSugerida
          });
        }
      });
    });

    // INSIGHT 3 — Reposición POR CANÓNICO: stock total < mínimo del canónico
    // Solo evaluamos canónicos. Las presentaciones/derivados heredan stockMinimo del canónico
    // si no lo tienen propio (lógica del frontend).
    productos.forEach(function(p) {
      if (!_esCanonico(p)) return;  // solo canónicos definen mínimo
      var min = parseFloat(p.stockMinimo) || 0;
      if (min <= 0) return;
      var keyP = String(p.idProducto).toUpperCase();
      var stockEnZonas = stockCanonMap[keyP] ? stockCanonMap[keyP].total : 0;
      var stockWhProd = stockWhPorCanon[keyP] || 0;
      var total = stockEnZonas + stockWhProd;
      if (total < min) {
        insights.push({
          tipo: 'REPOSICION',
          severidad: 'CRITICA',
          producto: p.descripcion,
          idProducto: p.idProducto,
          skuBase: p.skuBase || '',
          stock: total,
          minimo: min,
          mensaje: p.descripcion + ' total ' + total + 'u (todas variantes) < mínimo ' + min,
          accion: 'Generar pedido al proveedor'
        });
      }
    });

    // Ordenar: por severidad primero, luego por tipo (REPOSICION > DESPACHAR_DESDE_WH > TRASLADAR > SIN_ROTACION)
    var prioSev  = { CRITICA: 0, ALTA: 1, MEDIA: 2, BAJA: 3 };
    var prioTipo = { REPOSICION: 0, DESPACHAR_DESDE_WH: 1, TRASLADAR: 2, SIN_ROTACION: 3 };
    insights.sort(function(a, b){
      var d1 = (prioSev[a.severidad]  || 9) - (prioSev[b.severidad]  || 9);
      if (d1 !== 0) return d1;
      return (prioTipo[a.tipo] || 9) - (prioTipo[b.tipo] || 9);
    });

    return { ok: true, data: { _almV: 2, insights: insights.slice(0, 20), total: insights.length, rangoDias: rangoDias } };
  } catch(e) {
    return { ok: false, error: 'Error insights: ' + e.message };
  }
}
