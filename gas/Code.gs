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
      case 'crearProducto':        return crearProductoMaster(params);
      case 'actualizarProducto':   return actualizarProductoMaster(params);
      case 'getEquivalencias':     return getEquivalencias(params);
      case 'crearEquivalencia':    return crearEquivalencia(params);
      case 'getHistorialPrecios':  return getHistorialPrecios(params);
      case 'publicarPrecio':       return publicarPrecio(params);

      // ── Proveedores maestros ───────────────────────────────
      case 'getProveedores':       return getProveedoresMaster(params);
      case 'crearProveedor':       return crearProveedorMaster(params);
      case 'actualizarProveedor':  return actualizarProveedorMaster(params);
      case 'getPagos':             return getPagosProveedor(params);
      case 'registrarPago':        return registrarPago(params);
      case 'getPedidos':           return getPedidosProveedor(params);
      case 'crearPedido':          return crearPedidoProveedor(params);

      // ── Conexiones cross-app ───────────────────────────────
      case 'getStockWarehouse':    return getStockWarehouse(params);
      case 'getAlertasWarehouse':  return getAlertasWarehouse();
      case 'getMermasWarehouse':   return getMermasWarehouse(params);
      case 'getEnvasadosWarehouse':return getEnvasadosWarehouse(params);
      case 'getGuiasWarehouse':    return getGuiasWarehouse(params);
      case 'getVentasMosExpress':  return getVentasMosExpress(params);
      case 'getRotacion':          return getRotacionProductos(params);
      case 'getConexiones':        return getConexiones();
      case 'setConexion':          return setConexion(params);

      // ── Config ─────────────────────────────────────────────
      case 'getConfig':            return getConfigMos();
      case 'setConfig':            return setConfigMos(params);

      // ── Estaciones ─────────────────────────────────────────
      case 'getEstaciones':        return getEstaciones(params);
      case 'crearEstacion':        return crearEstacion(params);
      case 'actualizarEstacion':   return actualizarEstacion(params);
      case 'verificarPinEstacion': return verificarPinEstacion(params);

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

      // ── Cajas MosExpress ────────────────────────────────────
      case 'getCierresCaja':            return getCierresCaja(params);

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
  var headers = data[0];
  return data.slice(1).map(function(row) {
    var obj = {};
    headers.forEach(function(h, i) {
      var v = row[i];
      obj[h] = v instanceof Date
        ? Utilities.formatDate(v, Session.getScriptTimeZone(), 'yyyy-MM-dd')
        : v;
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
