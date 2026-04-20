// ============================================================
// ProyectoMOS — Zonas.gs
// Puntos de venta: cada zona agrupa 1+ estaciones de despacho
// ============================================================

function getZonas(params) {
  var rows = _sheetToObjects(getSheet('ZONAS'));
  if (params && params.soloActivas) rows = rows.filter(function(z){ return String(z.estado) === '1'; });
  return { ok: true, data: rows };
}

function crearZona(params) {
  if (!params.nombre) return { ok: false, error: 'nombre requerido' };
  var sheet = getSheet('ZONAS');
  var idZona = params.idZona || ('Z' + new Date().getTime());
  sheet.appendRow([
    idZona,
    params.nombre,
    params.descripcion || '',
    params.direccion   || '',
    params.responsable || '',
    params.estado !== undefined ? String(params.estado) : '1'
  ]);
  return { ok: true, data: { idZona: idZona } };
}

function actualizarZona(params) {
  if (!params.idZona) return { ok: false, error: 'idZona requerido' };
  var sheet = getSheet('ZONAS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var campos = ['nombre','descripcion','direccion','responsable','estado'];
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][hdrs.indexOf('idZona')]) === String(params.idZona)) {
      campos.forEach(function(c) {
        var idx = hdrs.indexOf(c);
        if (idx >= 0 && params[c] !== undefined) {
          sheet.getRange(i + 1, idx + 1).setValue(params[c]);
        }
      });
      return { ok: true };
    }
  }
  return { ok: false, error: 'Zona no encontrada: ' + params.idZona };
}
