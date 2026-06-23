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
    SpreadsheetApp.flush();  // forzar commit antes de continuar
  }
  return sheet;
}

// ── ONE-SHOT: inicializar columna politicaJSON manualmente ──────────────
// Ejecutar desde el editor de Apps Script si el guardado desde el UI no
// crea la columna automáticamente (suele pasar si el deployment del web
// app está congelado en una versión vieja).
//
// También permite SETEAR una política específica desde el editor para
// validar sin pasar por la UI:
//   setupZonasPolitica({ZONA-01: {metaDiaria: 1500, comisionExcedentePct: 5, metaAuditorias: 30}})
function setupZonasPolitica(politicasPorIdZona) {
  var sheet = _garantizarColPoliticaZona();
  if (!sheet) return { ok: false, error: 'No se encontró hoja ZONAS' };
  var data    = sheet.getDataRange().getValues();
  var hdrs    = data[0].map(function(h){ return String(h); });
  var idxId   = hdrs.indexOf('idZona');
  var idxPol  = hdrs.indexOf('politicaJSON');
  if (idxId < 0 || idxPol < 0) return { ok: false, error: 'Headers idZona/politicaJSON no encontrados' };

  var actualizadas = [];
  if (politicasPorIdZona && typeof politicasPorIdZona === 'object') {
    for (var i = 1; i < data.length; i++) {
      var idz = String(data[i][idxId] || '');
      if (politicasPorIdZona[idz]) {
        var pol = politicasPorIdZona[idz];
        var json = typeof pol === 'string' ? pol : JSON.stringify(pol);
        sheet.getRange(i + 1, idxPol + 1).setValue(json);
        actualizadas.push(idz + ' → ' + json);
      }
    }
  }

  // Mostrar estado completo
  var resumen = [];
  for (var j = 1; j < data.length; j++) {
    var idj  = String(data[j][idxId] || '');
    var raw  = String(sheet.getRange(j + 1, idxPol + 1).getValue() || '');
    resumen.push(idj + ': ' + (raw || '(vacío)'));
  }
  Logger.log('Política por zona — estado actual:');
  resumen.forEach(function(r){ Logger.log('  ' + r); });
  if (actualizadas.length) Logger.log('Actualizadas: ' + actualizadas.length);
  return { ok: true, actualizadas: actualizadas, estado: resumen };
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
  // [DELETE-SAFE · espejo inmediato] Mirror best-effort a mos.zonas (upsert por PK), igual que el catálogo.
  // La Hoja sigue siendo la VERDAD (no hay RPC directo-puro de zonas); el espejo mantiene la sombra fresca sin
  // esperar el sync horario → la lectura Supabase-first (zonas_lista) ve el alta de inmediato. NUNCA lanza.
  try {
    if (typeof _dualWriteCAT === 'function') {
      _dualWriteCAT('zonas', {
        idZona: idZona, nombre: params.nombre, descripcion: params.descripcion || '',
        direccion: params.direccion || '', responsable: params.responsable || '',
        estado: params.estado !== undefined ? String(params.estado) : '1',
        politicaJSON: params.politicaJSON || ''
      });
    }
  } catch (eDW) { Logger.log('[dualWrite crearZona] ' + (eDW && eDW.message)); }
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
      // [DELETE-SAFE · espejo inmediato] Mirror best-effort de la fila ACTUALIZADA a mos.zonas (upsert por PK).
      // La Hoja es la verdad; el espejo mantiene la sombra fresca para zonas_lista. NUNCA lanza.
      try {
        if (typeof _dualWriteCAT === 'function') {
          var fila = sheet.getRange(i + 1, 1, 1, hdrs.length).getValues()[0];
          var obj = {};
          hdrs.forEach(function(h, k){ obj[h] = fila[k]; });
          _dualWriteCAT('zonas', obj);
        }
      } catch (eDW) { Logger.log('[dualWrite actualizarZona] ' + (eDW && eDW.message)); }
      return { ok: true };
    }
  }
  return { ok: false, error: 'Zona no encontrada: ' + params.idZona };
}

// ── Resolver política de comisión/meta para una zona ────────────────
// Lee politicaJSON de la zona. SIN fallback global — cada zona se
// configura explícitamente desde el modal de Zona. Si la zona no tiene
// meta válida, retorna configurada:false para que UI muestre "FALTA
// CONFIGURAR" en lugar de heredar un valor por defecto confuso.
function _resolverPoliticaZona(idZona) {
  var meta = 0, pct = 0, metaAud = 0, configurada = false;
  if (idZona) {
    try {
      _garantizarColPoliticaZona();
      var zRows = _sheetToObjects(getSheet('ZONAS'));
      var z = zRows.find(function(r){ return String(r.idZona) === String(idZona); });
      if (z && z.politicaJSON) {
        var raw = String(z.politicaJSON || '').trim();
        if (raw) {
          var pol = JSON.parse(raw);
          if (pol && parseFloat(pol.metaDiaria) > 0)             meta    = parseFloat(pol.metaDiaria);
          if (pol && parseFloat(pol.comisionExcedentePct) >= 0)  pct     = parseFloat(pol.comisionExcedentePct);
          if (pol && parseFloat(pol.metaAuditorias) > 0)         metaAud = parseFloat(pol.metaAuditorias);
          if (meta > 0)                                          configurada = true;
        }
      }
    } catch(_) {}
  }
  // metaAuditorias: SIN fallback al global. evalMetaAuditorias es para
  // almacén, no para POS. Si la zona no la tiene → metaAud = 0 (el UI
  // mostrará "sin configurar" igual que para meta de venta).
  return { metaDiaria: meta, comisionExcedentePct: pct, metaAuditorias: metaAud, configurada: configurada };
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
