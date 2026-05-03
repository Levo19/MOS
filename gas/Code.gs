// ============================================================
// ProyectoMOS — Code.gs
// Router principal. Desplegar como Web App: Execute as Me, Anyone
// Este es el cerebro del ecosistema InversionMos.
// ============================================================

var SS_ID = PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID');

function getSpreadsheet() { return SpreadsheetApp.openById(SS_ID); }
function getSheet(name)   { return getSpreadsheet().getSheetByName(name); }

function doGet(e)  { return _respond(_route('GET',  e)); }
function doPost(e) { return _respond(_route('POST', e)); }

function _respond(data) {
  return ContentService.createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}

function _route(method, e) {
  try {
    var params = (method === 'GET')
      ? e.parameter
      : JSON.parse(e.postData ? e.postData.contents : '{}');
    var action = params.action || '';

    return (function() { switch(action) {

      // ── Catálogo maestro (Productos) ───────────────────────
      case 'getProductos':         return getProductosMaster(params);
      case 'getProducto':          return getProductoMaster(params.codigo);
      case 'getProductoPorCodigo': return getProductoPorCodigo(params);
      case 'crearProducto':        return crearProductoMaster(params);
      case 'actualizarProducto':   return actualizarProductoMaster(params);
      case 'getEquivalencias':       return getEquivalencias(params);
      case 'crearEquivalencia':      return crearEquivalencia(params);
      case 'actualizarEquivalencia': return actualizarEquivalencia(params);
      case 'getHistorialPrecios':  return getHistorialPrecios(params);
      case 'publicarPrecio':       return publicarPrecio(params);

      // ── Auditoría de integridad ─────────────────────────────
      case 'getAuditoriaIntegridad':   return getAuditoriaIntegridad(params);
      case 'auditarIntegridad':        return auditarIntegridadProductos();
      case 'resolverAlertaAuditoria':  return resolverAlertaAuditoria(params);

      // ── Política de precios (categorías + sugerencia) ──────
      case 'getCategorias':           return getCategorias(params);
      case 'crearCategoria':          return crearCategoria(params);
      case 'actualizarCategoria':     return actualizarCategoria(params);
      case 'migrarPoliticaPrecios':   return migrarPoliticaPrecios();

      // ── Almacén unificado (WH + Zonas ME) ──────────────────
      case 'getDashboardAlmacen':    return getDashboardAlmacen();
      case 'getCatalogoStockResumen': return getCatalogoStockResumen(params);
      case 'getStockUnificado':      return getStockUnificado(params);
      case 'getGuiasYPreingresos':   return getGuiasYPreingresos(params);
      case 'getOperacionesUnificadas': return getOperacionesUnificadas(params);
      case 'getOperacionDetalle':    return getOperacionDetalle(params);
      case 'llenarCostosGuia':       return llenarCostosGuia(params);
      case 'getRankingZonas':        return getRankingZonas(params);
      case 'getProductosSinVenta':   return getProductosSinVenta(params);
      case 'getInsightsStock':       return getInsightsStock(params);
      case 'getAlertasOperativas':   return getAlertasOperativas(params);
      case 'bustAlmacenCache':       return bustAlmacenCache();
      case 'warmupAlmacen':          return warmupAlmacen();
      case 'getAlmacenWarmupStatus': return getAlmacenWarmupStatus();

      // ── Proveedores maestros ───────────────────────────────
      case 'getProveedores':              return getProveedoresMaster(params);
      case 'crearProveedor':              return crearProveedorMaster(params);
      case 'actualizarProveedor':         return actualizarProveedorMaster(params);
      case 'getPagos':                    return getPagosProveedor(params);
      case 'registrarPago':               return registrarPago(params);
      case 'getPedidos':                  return getPedidosProveedor(params);
      case 'crearPedido':                 return crearPedidoProveedor(params);
      case 'getProveedoresQueVenden':     return getProveedoresQueVenden(params);
      case 'getHistoricoProveedor':       return getHistoricoProveedor(params);
      case 'getProveedorProductos':       return getProveedorProductos(params);
      case 'agregarProductoProveedor':    return agregarProductoProveedor(params);
      case 'actualizarProductoProveedor': return actualizarProductoProveedor(params);
      case 'eliminarProductoProveedor':   return eliminarProductoProveedor(params);
      case 'upsertProductoProveedor':     return upsertProductoProveedor(params);

      // ── Promociones (centralizadas en hoja MosExpress) ─────
      case 'getPromociones':              return getPromociones(params);
      case 'crearPromocion':              return crearPromocion(params);
      case 'actualizarPromocion':         return actualizarPromocion(params);
      case 'eliminarPromocion':           return eliminarPromocion(params);

      // ── Conexiones cross-app ───────────────────────────────
      case 'getStockWarehouse':    return getStockWarehouse(params);
      case 'getAlertasWarehouse':  return getAlertasWarehouse();
      case 'getMermasWarehouse':   return getMermasWarehouse(params);
      case 'getEnvasadosWarehouse':return getEnvasadosWarehouse(params);
      case 'getGuiasWarehouse':    return getGuiasWarehouse(params);
      case 'getProductosNuevosWH': return getProductosNuevosWarehouse(params);
      case 'lanzarProductoNuevo':  return lanzarProductoNuevo(params);
      case 'getVentasMosExpress':  return getVentasMosExpress(params);
      case 'getRotacion':            return getRotacionProductos(params);
      case 'getAnaliticaProducto':   return getAnaliticaProducto(params);
      case 'getConexiones':        return getConexiones();
      case 'setConexion':          return setConexion(params);
      case 'getEcoStatus':         return getEcoStatus();

      // ── Config ─────────────────────────────────────────────
      case 'getConfig':            return getConfigMos();
      case 'setConfig':            return setConfigMos(params);

      // ── Dispositivos ───────────────────────────────────────
      case 'getDispositivos':          return getDispositivos(params);
      case 'crearDispositivo':         return crearDispositivo(params);
      case 'actualizarDispositivo':    return actualizarDispositivo(params);
      case 'registrarConexion':        return registrarConexionDispositivo(params);

      // ── Zonas (puntos de venta) ────────────────────────────
      case 'getZonas':             return getZonas(params);
      case 'crearZona':            return crearZona(params);
      case 'actualizarZona':       return actualizarZona(params);

      // ── Estaciones ─────────────────────────────────────────
      case 'getEstaciones':        return getEstaciones(params);
      case 'crearEstacion':        return crearEstacion(params);
      case 'actualizarEstacion':   return actualizarEstacion(params);
      case 'verificarPinEstacion': return verificarPinEstacion(params);
      case 'getEstacionesParaApp': return getEstacionesParaApp(params);

      // ── Impresoras ─────────────────────────────────────────
      case 'getImpresoras':        return getImpresoras(params);
      case 'crearImpresora':       return crearImpresora(params);
      case 'actualizarImpresora':  return actualizarImpresora(params);

      // ── Series documentales ────────────────────────────────
      case 'getSeries':            return getSeries(params);
      case 'crearSerie':           return crearSerie(params);
      case 'actualizarSerie':      return actualizarSerie(params);

      // ── Personal master ────────────────────────────────────
      case 'getPersonalMaster':         return getPersonalMaster(params);
      case 'crearPersonalMaster':       return crearPersonalMaster(params);
      case 'actualizarPersonalMaster':  return actualizarPersonalMaster(params);
      case 'verificarPinPersonal':      return verificarPinPersonal(params);

      // ── Finanzas ────────────────────────────────────────────
      case 'getFinanzasDia':             return getFinanzasDia(params);
      case 'getFinanzasRango':           return getFinanzasRango(params);
      case 'getJornadas':                return getJornadas(params);
      case 'registrarJornada':           return registrarJornada(params);
      case 'eliminarJornada':            return eliminarJornada(params);
      case 'importarJornadasDesdeCajas': return importarJornadasDesdeCajas(params);
      case 'getGastos':                  return getGastos(params);
      case 'registrarGasto':             return registrarGasto(params);
      case 'eliminarGasto':              return eliminarGasto(params);
      case 'actualizarCostoPorSku':      return actualizarCostoPorSku(params);

      // ── Push notifications ─────────────────────────────────────
      case 'registrarPushToken':        return registrarPushToken(params);
      case 'enviarPushNotif':           return enviarPushNotif(params);

      // ── Evaluaciones de personal ──────────────────────────────
      case 'crearEvaluacion':           return crearEvaluacion(params);
      case 'getEvaluacionesDia':        return getEvaluacionesDia(params);
      case 'getResumenDia':             return getResumenDia(params);
      case 'getResumenTodosDia':        return getResumenTodosDia(params);
      case 'getLiquidacionSemana':      return getLiquidacionSemana(params);

      // ── Cajas MosExpress ────────────────────────────────────
      case 'getCierresCaja':            return getCierresCaja(params);
      case 'anularTicketME':            return anularTicketME(params);
      case 'cambiarMetodoME':           return cambiarMetodoME(params);
      case 'imprimirTicketZCierre':     return imprimirTicketZCierre(params);
      case 'getTicketZTexto':           return getTicketZTexto(params);
      case 'datosTurno':               return datosTurno(params);

      default:
        return { ok: false, error: 'Acción no reconocida: ' + action };
    }})();
  } catch(err) {
    return { ok: false, error: err.message, stack: err.stack };
  }
}

// ============================================================
// Helpers compartidos
// ============================================================
function _sheetToObjects(sheet) {
  var data = sheet.getDataRange().getValues();
  if (data.length < 2) return [];
  var headers = data[0].map(function(h) { return String(h).trim(); });
  var tz = Session.getScriptTimeZone();
  return data.slice(1).map(function(row) {
    var obj = {};
    headers.forEach(function(h, i) {
      if (!h) return;
      var v = row[i];
      if (v instanceof Date) {
        obj[h] = Utilities.formatDate(v, tz, 'yyyy-MM-dd');
      } else if (typeof v === 'string' && /^\d+,\d+$/.test(v.trim())) {
        // Celda guardada como texto con separador decimal de coma (ej: "4,5" → 4.5)
        obj[h] = parseFloat(v.trim().replace(',', '.'));
      } else {
        obj[h] = v;
      }
    });
    return obj;
  }).filter(function(obj) {
    return Object.values(obj).some(function(v){ return v !== '' && v !== null && v !== undefined; });
  });
}

function _generateId(prefix) { return prefix + new Date().getTime(); }

function getConfigMos() {
  var rows = _sheetToObjects(getSheet('CONFIG_MOS'));
  var cfg = {};
  rows.forEach(function(r){ cfg[r.clave] = r.valor; });
  return { ok: true, data: cfg };
}

function setConfigMos(params) {
  var sheet = getSheet('CONFIG_MOS');
  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] === params.clave) {
      sheet.getRange(i + 1, 2).setValue(params.valor);
      return { ok: true };
    }
  }
  sheet.appendRow([params.clave, params.valor, params.descripcion || '']);
  return { ok: true };
}
