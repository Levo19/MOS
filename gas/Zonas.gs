// ============================================================
// ProyectoMOS — Zonas.gs
// Puntos de venta: cada zona agrupa 1+ estaciones de despacho
// ============================================================

// Garantiza que la columna politicaJSON exista. Se llama desde getZonas y
// actualizarZona — idempotente, costo cero si ya existe.
function _garantizarColPoliticaZona() {
  var sheet = getSheet('ZONAS');
  if (!sheet) return null;
  var lastCol = sheet.getLastColumn();
  var hdrs    = sheet.getRange(1, 1, 1, lastCol).getValues()[0];
  if (hdrs.indexOf('politicaJSON') === -1) {
    sheet.getRange(1, lastCol + 1).setValue('politicaJSON');
  }
  return sheet;
}

function getZonas(params) {
  _garantizarColPoliticaZona();
  var rows = _sheetToObjects(getSheet('ZONAS'));
  if (params && params.soloActivas) rows = rows.filter(function(z){ return String(z.estado) === '1'; });
  return { ok: true, data: rows };
}

function crearZona(params) {
  if (!params.nombre) return { ok: false, error: 'nombre requerido' };
  _garantizarColPoliticaZona();
  var sheet = getSheet('ZONAS');
  var idZona = params.idZona || ('Z' + new Date().getTime());
  sheet.appendRow([
    idZona,
    params.nombre,
    params.descripcion || '',
    params.direccion   || '',
    params.responsable || '',
    params.estado !== undefined ? String(params.estado) : '1',
    params.politicaJSON || ''
  ]);
  return { ok: true, data: { idZona: idZona } };
}

function actualizarZona(params) {
  if (!params.idZona) return { ok: false, error: 'idZona requerido' };
  _garantizarColPoliticaZona();
  var sheet = getSheet('ZONAS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  // politicaJSON incluido: editable como cualquier campo. Si llega objeto, stringificarlo.
  var campos = ['nombre','descripcion','direccion','responsable','estado','politicaJSON'];
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][hdrs.indexOf('idZona')]) === String(params.idZona)) {
      campos.forEach(function(c) {
        var idx = hdrs.indexOf(c);
        if (idx >= 0 && params[c] !== undefined) {
          var val = params[c];
          if (c === 'politicaJSON' && typeof val === 'object') val = JSON.stringify(val);
          sheet.getRange(i + 1, idx + 1).setValue(val);
        }
      });
      return { ok: true };
    }
  }
  return { ok: false, error: 'Zona no encontrada: ' + params.idZona };
}

// ── Resolver política de comisión/meta para una zona ────────────────
// Lee politicaJSON de la zona; si vacío/inválido, cae a CONFIG_MOS global.
// Retorna { metaDiaria, comisionExcedentePct } siempre con valores válidos.
function _resolverPoliticaZona(idZona) {
  var meta = 0, pct = 0;
  // 1. Fallback global desde CONFIG_MOS (siempre se lee primero)
  try {
    var cfgRows = _sheetToObjects(getSheet('CONFIG_MOS'));
    var cfgMap = {};
    cfgRows.forEach(function(r){ cfgMap[r.clave] = r.valor; });
    meta = parseFloat(cfgMap['evalMetaCajero']) || 2000;
    pct  = parseFloat(cfgMap['evalComisionExcedentePct']);
    if (isNaN(pct)) {
      pct = 5;
      // Auto-crear la clave la primera vez para que el admin pueda editarla
      _setConfigMosClave('evalComisionExcedentePct', 5,
        'Porcentaje de comisión sobre el excedente de la meta diaria (sobre lo cobrado)');
    }
  } catch(_){}
  // 2. Override por zona si politicaJSON tiene valores
  if (idZona) {
    try {
      _garantizarColPoliticaZona();
      var zRows = _sheetToObjects(getSheet('ZONAS'));
      var z = zRows.find(function(r){ return String(r.idZona) === String(idZona); });
      if (z && z.politicaJSON) {
        var raw = String(z.politicaJSON || '').trim();
        if (raw) {
          var pol = JSON.parse(raw);
          if (pol && parseFloat(pol.metaDiaria) > 0)             meta = parseFloat(pol.metaDiaria);
          if (pol && parseFloat(pol.comisionExcedentePct) >= 0)  pct  = parseFloat(pol.comisionExcedentePct);
        }
      }
    } catch(_) {}
  }
  return { metaDiaria: meta, comisionExcedentePct: pct };
}

// Helper interno: setea (o crea) una clave en CONFIG_MOS
function _setConfigMosClave(clave, valor, descripcion) {
  var sheet = getSheet('CONFIG_MOS');
  if (!sheet) return;
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var idxClave = hdrs.indexOf('clave');
  var idxValor = hdrs.indexOf('valor');
  var idxDesc  = hdrs.indexOf('descripcion');
  if (idxClave < 0 || idxValor < 0) return;
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][idxClave]) === String(clave)) {
      sheet.getRange(i + 1, idxValor + 1).setValue(valor);
      return;
    }
  }
  // No existe: append
  var fila = new Array(hdrs.length).fill('');
  fila[idxClave] = clave;
  fila[idxValor] = valor;
  if (idxDesc >= 0 && descripcion) fila[idxDesc] = descripcion;
  sheet.appendRow(fila);
}
