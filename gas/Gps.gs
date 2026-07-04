// ============================================================
// ProyectoMOS — Gps.gs
// Tracking de ubicación de dispositivos de empresa (anti-robo).
//
// Flujo:
// 1. Cada 5 min, ME/WH (con app abierta) hacen navigator.geolocation
//    y llaman registrarUbicacion con lat/lng/accuracy/bateria
// 2. Master/Admin click 📍 en card de dispositivo → ve mapa con última posición
//    o historial 24h
// 3. Trigger horario verificarSinSenal: alerta a master si dispositivo
//    activo no reporta hace > 24h
//
// Hoja:
//   UBICACIONES_HISTORIAL: idUbic | deviceId | timestamp | lat | lng | accuracy | bateria | usuarioLogueado
//   TTL: 7 días normal — borrado por limpiarUbicacionesViejas
// ============================================================

var GPS_HEADERS = ['idUbic', 'deviceId', 'timestamp', 'lat', 'lng', 'accuracy', 'bateria', 'usuarioLogueado'];
var GPS_TTL_DIAS = 7;
var GPS_SIN_SENAL_HORAS = 24;

function _garantizarHojaGps() {
  var ss = getSpreadsheet();
  var s = ss.getSheetByName('UBICACIONES_HISTORIAL');
  if (!s) {
    s = ss.insertSheet('UBICACIONES_HISTORIAL');
    s.getRange(1, 1, 1, GPS_HEADERS.length).setValues([GPS_HEADERS]);
    s.getRange(1, 1, 1, GPS_HEADERS.length)
      .setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
    s.setFrozenRows(1);
  }
  return s;
}

// ────────────────────────────────────────────────────────────
// REGISTRAR ubicación (llamado por dispositivo)
// ────────────────────────────────────────────────────────────
function registrarUbicacion(params) {
  if (!params || !params.deviceId) return { ok: false, error: 'Requiere deviceId' };
  if (!params.lat || !params.lng)  return { ok: false, error: 'Requiere lat y lng' };

  _garantizarHojaGps();
  var sheet = getSheet('UBICACIONES_HISTORIAL');

  var lat = parseFloat(params.lat);
  var lng = parseFloat(params.lng);
  if (isNaN(lat) || isNaN(lng)) return { ok: false, error: 'Coordenadas inválidas' };

  var idUbic = 'UB' + new Date().getTime();
  sheet.appendRow([
    idUbic,
    String(params.deviceId),
    new Date(),
    lat,
    lng,
    parseFloat(params.accuracy) || 0,
    params.bateria !== undefined ? parseFloat(params.bateria) : '',
    String(params.usuarioLogueado || '')
  ]);

  return { ok: true, data: { idUbic: idUbic } };
}

// ────────────────────────────────────────────────────────────
// Obtener última ubicación de un dispositivo
// ────────────────────────────────────────────────────────────
function getUltimaUbicacionDispositivo(params) {
  if (!params || !params.deviceId) return { ok: false, error: 'Requiere deviceId' };
  _garantizarHojaGps();
  var rows = _sheetToObjects(getSheet('UBICACIONES_HISTORIAL'))
    .filter(function(r){ return String(r.deviceId) === String(params.deviceId); });
  if (!rows.length) return { ok: true, data: null };
  rows.sort(function(a, b) {
    return (new Date(b.timestamp).getTime() || 0) - (new Date(a.timestamp).getTime() || 0);
  });
  return { ok: true, data: rows[0] };
}

// ────────────────────────────────────────────────────────────
// Historial de ubicaciones (para mapa con ruta)
// ────────────────────────────────────────────────────────────
function getUbicacionesDispositivo(params) {
  if (!params || !params.deviceId) return { ok: false, error: 'Requiere deviceId' };
  _garantizarHojaGps();
  var horas = parseInt(params.horas, 10) || 24;
  var corte = Date.now() - (horas * 60 * 60 * 1000);
  var rows = _sheetToObjects(getSheet('UBICACIONES_HISTORIAL'))
    .filter(function(r) {
      if (String(r.deviceId) !== String(params.deviceId)) return false;
      var ts = new Date(r.timestamp).getTime() || 0;
      return ts >= corte;
    });
  rows.sort(function(a, b) {
    return (new Date(a.timestamp).getTime() || 0) - (new Date(b.timestamp).getTime() || 0);
  });
  return { ok: true, data: rows };
}

// ────────────────────────────────────────────────────────────
// Trigger horario — detecta dispositivos activos sin señal >24h
// ────────────────────────────────────────────────────────────
function verificarSinSenal() {
  _garantizarHojaGps();

  var dispositivos = _sheetToObjects(getSheet('DISPOSITIVOS'))
    .filter(function(d){ return String(d.Estado).toUpperCase() === 'ACTIVO'; });

  var ubics = _sheetToObjects(getSheet('UBICACIONES_HISTORIAL'));
  var ultimaPorDevice = {};
  ubics.forEach(function(u) {
    var ts = new Date(u.timestamp).getTime() || 0;
    if (!ultimaPorDevice[u.deviceId] || ultimaPorDevice[u.deviceId] < ts) {
      ultimaPorDevice[u.deviceId] = ts;
    }
  });

  // [cero-GAS G2] Mergear con la última GPS de Supabase (mos.gps_ultima_map): tras activar GPS_DIRECTO los
  // reportes van a Supabase y NO a la Hoja. Tomamos el MÁS reciente de ambas fuentes → un equipo solo cuenta
  // como "sin señal" si AMBAS están viejas. Sin esto, post-cutover marcaría todos los equipos sin señal (spam).
  // Tolerante: si Supabase falla, sigue con el mapa de la Hoja (gracia de 24h por las filas viejas).
  try {
    var _sbMap = _sbRpc('mos', 'gps_ultima_map', { p: { dias: 8 } });
    var _m = _sbMap && _sbMap.ok && _sbMap.data && _sbMap.data.data;
    if (_m) {
      Object.keys(_m).forEach(function(dev) {
        var ts = new Date(_m[dev]).getTime() || 0;
        if (ts && (!ultimaPorDevice[dev] || ultimaPorDevice[dev] < ts)) ultimaPorDevice[dev] = ts;
      });
    }
  } catch(e) { Logger.log('merge GPS Supabase: ' + e.message); }

  var corte = Date.now() - (GPS_SIN_SENAL_HORAS * 60 * 60 * 1000);
  var sinSenal = [];
  dispositivos.forEach(function(d) {
    var ult = ultimaPorDevice[d.ID_Dispositivo];
    if (!ult || ult < corte) {
      sinSenal.push({
        nombre: d.Nombre_Equipo,
        deviceId: d.ID_Dispositivo,
        ultima: ult ? new Date(ult) : null
      });
    }
  });

  if (sinSenal.length > 0) {
    var titulo = '⚠ ' + sinSenal.length + ' dispositivo' + (sinSenal.length === 1 ? '' : 's') + ' sin señal';
    var cuerpo = sinSenal.slice(0, 3).map(function(d) {
      var horas = d.ultima ? Math.round((Date.now() - d.ultima.getTime()) / 3600000) : null;
      return '📱 ' + d.nombre + (horas !== null ? ' · ' + horas + 'h sin reportar' : ' · nunca');
    }).join('\n');
    if (sinSenal.length > 3) cuerpo += '\n+ ' + (sinSenal.length - 3) + ' más';

    // [CERO-GAS · anti-doble-push] GPS sin señal lo envía el pg_cron mos-gps-sin-senal (mos.cron_gps_sin_senal).
    // El GAS ya NO pushea (evita doble + deja de leer el Sheet de tokens).
  }

  return { ok: true, data: { dispositivosSinSenal: sinSenal.length } };
}

// ────────────────────────────────────────────────────────────
// Limpieza — borra ubicaciones > 7 días
// ────────────────────────────────────────────────────────────
function limpiarUbicacionesViejas() {
  _garantizarHojaGps();
  var sheet = getSheet('UBICACIONES_HISTORIAL');
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var iTs = hdrs.indexOf('timestamp');
  var corte = Date.now() - (GPS_TTL_DIAS * 24 * 60 * 60 * 1000);
  var filasABorrar = [];
  for (var i = 1; i < data.length; i++) {
    var ts = data[i][iTs] ? new Date(data[i][iTs]).getTime() : 0;
    if (ts && ts < corte) filasABorrar.push(i + 1);
  }
  for (var k = filasABorrar.length - 1; k >= 0; k--) {
    sheet.deleteRow(filasABorrar[k]);
  }
  Logger.log('[GPS] Limpieza: ' + filasABorrar.length + ' ubicaciones > ' + GPS_TTL_DIAS + 'd eliminadas');
  return { ok: true, data: { eliminados: filasABorrar.length } };
}
