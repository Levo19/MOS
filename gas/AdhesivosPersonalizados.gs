/**
 * AdhesivosPersonalizados.gs — Backend del Editor de Avisos
 * v1.0.0 — 2026-06-05
 *
 * Sistema de plantillas custom para adhesivos 50×25mm (futureproof
 * para 80mm tickets en F4). Convive sin pisarse con MEMBRETE_ME/WH/
 * ADHESIVO_ENVASADO que viven en warehouseMos.
 *
 * Hojas:
 *   • ADHESIVOS_PLANTILLAS: idPlantilla | nombre | descripcion |
 *       tamanoCanvas | json | creadoPor | fechaCreado | fechaUltMod | activo
 *   • ICONOS_BITMAPS_ADH: idIcono | tamano_dots | hex
 *
 * Flujo impresión: lee plantilla → json2tspl → reusa PrintNode del
 * sistema de membretes (bridge a WH si está accesible, sino impresión
 * directa via PRINTNODE_API_KEY local).
 */

var ADH_HOJA_PLANTILLAS = 'ADHESIVOS_PLANTILLAS';
var ADH_HOJA_ICONOS     = 'ICONOS_BITMAPS_ADH';
var ADH_DOTS_POR_MM     = 8;
var ADH_MAX_CAPAS       = 20;

// ════════════════════════════════════════════════════════════════════
// SETUP — crea hojas + 6 plantillas semilla
// ════════════════════════════════════════════════════════════════════
function setupAdhesivosBase(payload) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  payload = payload || {};

  // 1) Hoja PLANTILLAS
  var hP = ss.getSheetByName(ADH_HOJA_PLANTILLAS);
  if (!hP) {
    hP = ss.insertSheet(ADH_HOJA_PLANTILLAS);
    hP.appendRow(['idPlantilla', 'nombre', 'descripcion', 'tamanoCanvas', 'json', 'creadoPor', 'fechaCreado', 'fechaUltMod', 'activo']);
    hP.getRange('A1:I1').setFontWeight('bold').setBackground('#1e293b').setFontColor('#fff');
    hP.setFrozenRows(1);
  }

  // 2) Hoja ICONOS_BITMAPS_ADH
  var hI = ss.getSheetByName(ADH_HOJA_ICONOS);
  if (!hI) {
    hI = ss.insertSheet(ADH_HOJA_ICONOS);
    hI.appendRow(['idIcono', 'tamano_dots', 'hex']);
    hI.getRange('A1:C1').setFontWeight('bold').setBackground('#1e293b').setFontColor('#fff');
    hI.setFrozenRows(1);
  }

  // 3) Cargar hex de iconos enviados desde frontend (formato {estrella:'AABB...', ...})
  if (payload.iconos && typeof payload.iconos === 'object') {
    var existentes = _adhListarIconos();
    var existeKey = {};
    existentes.forEach(function(r) { existeKey[r.idIcono + '__' + r.tamano_dots] = true; });
    var tamano = parseInt(payload.tamano_dots) || 48;
    Object.keys(payload.iconos).forEach(function(idIcono) {
      var key = idIcono + '__' + tamano;
      var hex = String(payload.iconos[idIcono] || '');
      if (!hex) return;
      if (existeKey[key]) {
        // Actualizar fila existente
        var data = hI.getDataRange().getValues();
        for (var r = 1; r < data.length; r++) {
          if (String(data[r][0]) === idIcono && parseInt(data[r][1]) === tamano) {
            hI.getRange(r + 1, 3).setValue(hex);
            break;
          }
        }
      } else {
        hI.appendRow([idIcono, tamano, hex]);
      }
    });
  }

  // 4) Plantillas semilla (solo si no hay ninguna activa)
  var plantillasExist = hP.getLastRow() > 1;
  if (!plantillasExist) {
    _adhInsertarSemillas(hP);
  }

  return {
    ok: true,
    hojaPlantillasCreada: !plantillasExist,
    iconosCargados: payload.iconos ? Object.keys(payload.iconos).length : 0,
    plantillas: _adhListarPlantillas().length
  };
}

function _adhInsertarSemillas(hP) {
  var hoy = new Date().toISOString().slice(0, 10);
  var semillas = [
    {
      nombre: 'OFERTA_GENERAL',
      descripcion: 'Banner de oferta con estrella e icono',
      json: {
        version: 1,
        tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
        capas: [
          { id: 'sem-1a', tipo: 'icono', x_mm: 2, y_mm: 4, idIcono: 'estrella', tamano_dots: 96 },
          { id: 'sem-1b', tipo: 'texto', x_mm: 16, y_mm: 2, texto: 'OFERTA', font: 5, alineacion: 'left' },
          { id: 'sem-1c', tipo: 'linea', x_mm: 16, y_mm: 11, ancho_mm: 30, alto_mm: 0.4 },
          { id: 'sem-1d', tipo: 'texto', x_mm: 16, y_mm: 13, texto: 'DESCUENTO', font: 3, alineacion: 'left' },
          { id: 'sem-1e', tipo: 'texto', x_mm: 16, y_mm: 18, texto: 'ESPECIAL', font: 3, alineacion: 'left' }
        ]
      }
    },
    {
      nombre: 'VENCE_HOY',
      descripcion: 'Alerta vence hoy con icono de alerta',
      json: {
        version: 1,
        tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
        capas: [
          { id: 'sem-2a', tipo: 'icono', x_mm: 2, y_mm: 4, idIcono: 'triangulo', tamano_dots: 96 },
          { id: 'sem-2b', tipo: 'texto', x_mm: 16, y_mm: 3, texto: 'VENCE', font: 5, alineacion: 'left' },
          { id: 'sem-2c', tipo: 'texto', x_mm: 16, y_mm: 12, texto: 'HOY!', font: 5, alineacion: 'left' },
          { id: 'sem-2d', tipo: 'rectangulo', x_mm: 0, y_mm: 0, ancho_mm: 50, alto_mm: 25, grosor: 2, relleno: false }
        ]
      }
    },
    {
      nombre: 'ZONA_LIMPIEZA',
      descripcion: 'Señal de zona de limpieza',
      json: {
        version: 1,
        tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
        capas: [
          { id: 'sem-3a', tipo: 'icono', x_mm: 2, y_mm: 4, idIcono: 'escoba', tamano_dots: 96 },
          { id: 'sem-3b', tipo: 'texto', x_mm: 16, y_mm: 4, texto: 'ZONA DE', font: 4, alineacion: 'left' },
          { id: 'sem-3c', tipo: 'texto', x_mm: 16, y_mm: 12, texto: 'LIMPIEZA', font: 5, alineacion: 'left' }
        ]
      }
    },
    {
      nombre: 'MANTENER_FRIO',
      descripcion: 'Aviso mantener refrigerado',
      json: {
        version: 1,
        tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
        capas: [
          { id: 'sem-4a', tipo: 'icono', x_mm: 2, y_mm: 4, idIcono: 'copo', tamano_dots: 96 },
          { id: 'sem-4b', tipo: 'texto', x_mm: 16, y_mm: 3, texto: 'MANTENER', font: 3, alineacion: 'left' },
          { id: 'sem-4c', tipo: 'texto', x_mm: 16, y_mm: 10, texto: 'REFRIGERADO', font: 4, alineacion: 'left' },
          { id: 'sem-4d', tipo: 'linea', x_mm: 2, y_mm: 22, ancho_mm: 46, alto_mm: 0.4 }
        ]
      }
    },
    {
      nombre: 'PRODUCTO_NUEVO',
      descripcion: 'Banner producto nuevo',
      json: {
        version: 1,
        tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
        capas: [
          { id: 'sem-5a', tipo: 'icono', x_mm: 2, y_mm: 4, idIcono: 'estrella', tamano_dots: 64 },
          { id: 'sem-5b', tipo: 'icono', x_mm: 34, y_mm: 4, idIcono: 'estrella', tamano_dots: 64 },
          { id: 'sem-5c', tipo: 'texto', x_mm: 11, y_mm: 6, texto: 'NUEVO!', font: 5, alineacion: 'left' },
          { id: 'sem-5d', tipo: 'texto', x_mm: 5, y_mm: 17, texto: 'PRODUCTO EN GONDOLA', font: 2, alineacion: 'left' }
        ]
      }
    },
    {
      nombre: 'NO_TOCAR',
      descripcion: 'Aviso no tocar / restringido',
      json: {
        version: 1,
        tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
        capas: [
          { id: 'sem-6a', tipo: 'icono', x_mm: 2, y_mm: 4, idIcono: 'prohibido', tamano_dots: 96 },
          { id: 'sem-6b', tipo: 'texto', x_mm: 16, y_mm: 6, texto: 'NO TOCAR', font: 5, alineacion: 'left' },
          { id: 'sem-6c', tipo: 'rectangulo', x_mm: 0, y_mm: 0, ancho_mm: 50, alto_mm: 25, grosor: 3, relleno: false }
        ]
      }
    }
  ];
  var now = new Date();
  var creador = 'SYSTEM';
  semillas.forEach(function(s, i) {
    var id = 'ADH-SEED-' + (i + 1);
    hP.appendRow([id, s.nombre, s.descripcion, '50x25', JSON.stringify(s.json), creador, now, now, true]);
  });
}

// ════════════════════════════════════════════════════════════════════
// ENDPOINTS PÚBLICOS (cases del router)
// ════════════════════════════════════════════════════════════════════
function listarAdhesivosPlantillas() {
  return { ok: true, plantillas: _adhListarPlantillas() };
}

function guardarAdhesivoPlantilla(params) {
  if (!params) return { ok: false, error: 'falta payload' };
  var nombre = String(params.nombre || '').trim();
  if (!nombre) return { ok: false, error: 'nombre requerido' };
  if (nombre.length > 50) return { ok: false, error: 'nombre muy largo (máx 50)' };

  // Validar JSON
  var jsonObj;
  try {
    jsonObj = typeof params.json === 'string' ? JSON.parse(params.json) : params.json;
  } catch(e) {
    return { ok: false, error: 'JSON inválido: ' + e.message };
  }
  var errores = _adhValidar(jsonObj);
  if (errores.length > 0) {
    return { ok: false, error: 'Plantilla inválida', detalles: errores };
  }

  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(10000);
    var ss = SpreadsheetApp.getActiveSpreadsheet();
    var hP = ss.getSheetByName(ADH_HOJA_PLANTILLAS);
    if (!hP) return { ok: false, error: 'Hoja ' + ADH_HOJA_PLANTILLAS + ' no existe. Corré setupAdhesivosBase()' };
    var data = hP.getDataRange().getValues();

    var ahora = new Date();
    var creador = params.creadoPor || 'ADMIN';
    var idPlantilla = params.idPlantilla;
    var tamanoStr = (jsonObj.tamano.ancho_mm || 50) + 'x' + (jsonObj.tamano.alto_mm || 25);

    if (idPlantilla) {
      // Actualizar fila existente
      for (var r = 1; r < data.length; r++) {
        if (String(data[r][0]) === String(idPlantilla)) {
          hP.getRange(r + 1, 2).setValue(nombre);
          hP.getRange(r + 1, 3).setValue(params.descripcion || '');
          hP.getRange(r + 1, 4).setValue(tamanoStr);
          hP.getRange(r + 1, 5).setValue(JSON.stringify(jsonObj));
          hP.getRange(r + 1, 8).setValue(ahora);
          hP.getRange(r + 1, 9).setValue(true);
          return { ok: true, idPlantilla: idPlantilla, actualizado: true };
        }
      }
      return { ok: false, error: 'idPlantilla no encontrada: ' + idPlantilla };
    } else {
      // Crear nueva
      idPlantilla = 'ADH-' + Utilities.getUuid().substring(0, 8).toUpperCase();
      hP.appendRow([
        idPlantilla, nombre, params.descripcion || '', tamanoStr,
        JSON.stringify(jsonObj), creador, ahora, ahora, true
      ]);
      return { ok: true, idPlantilla: idPlantilla, creado: true };
    }
  } finally {
    try { lock.releaseLock(); } catch(_){}
  }
}

function eliminarAdhesivoPlantilla(params) {
  var id = params && params.idPlantilla;
  if (!id) return { ok: false, error: 'idPlantilla requerido' };
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var hP = ss.getSheetByName(ADH_HOJA_PLANTILLAS);
  if (!hP) return { ok: false, error: 'Hoja no existe' };
  var data = hP.getDataRange().getValues();
  for (var r = 1; r < data.length; r++) {
    if (String(data[r][0]) === String(id)) {
      hP.getRange(r + 1, 9).setValue(false);  // soft-delete: activo = FALSE
      return { ok: true, eliminado: id };
    }
  }
  return { ok: false, error: 'no encontrada: ' + id };
}

function imprimirAdhesivoPlantilla(params) {
  var id = params && params.idPlantilla;
  var cantidad = parseInt(params.cantidad || 1);
  if (!id) return { ok: false, error: 'idPlantilla requerido' };
  if (cantidad < 1 || cantidad > 100) return { ok: false, error: 'cantidad fuera de rango (1-100)' };

  var p = _adhBuscarPlantilla(id);
  if (!p) return { ok: false, error: 'no encontrada: ' + id };
  if (!p.activo) return { ok: false, error: 'plantilla inactiva' };

  var jsonObj;
  try {
    jsonObj = JSON.parse(p.json);
  } catch(e) {
    return { ok: false, error: 'JSON corrupto: ' + e.message };
  }

  var errores = _adhValidar(jsonObj);
  if (errores.length > 0) {
    return { ok: false, error: 'Plantilla inválida', detalles: errores };
  }

  // Construir TSPL batch (N etiquetas con drift incremental)
  var bytesTotal = [];
  var iconosMap = _adhMapaIconos();
  for (var i = 0; i < cantidad; i++) {
    var offsetY = _adhCalcularOffsetParaIndice(i);
    var bytes = _adhJson2tspl(jsonObj, offsetY, iconosMap);
    bytesTotal = bytesTotal.concat(bytes);
  }

  // Enviar a PrintNode
  var resultado = _adhEnviarPrintNode(bytesTotal, cantidad);
  return resultado;
}

function testImpresionAdhesivoPlantilla(params) {
  // Igual que imprimir pero cantidad=1 sin validar activo
  var id = params && params.idPlantilla;
  if (!id) return { ok: false, error: 'idPlantilla requerido' };
  var p = _adhBuscarPlantilla(id);
  if (!p) return { ok: false, error: 'no encontrada' };
  var jsonObj = JSON.parse(p.json);
  var errores = _adhValidar(jsonObj);
  if (errores.length > 0) {
    return { ok: false, error: 'Plantilla inválida', detalles: errores };
  }
  var iconosMap = _adhMapaIconos();
  var bytes = _adhJson2tspl(jsonObj, _adhCalcularOffsetParaIndice(0), iconosMap);
  return _adhEnviarPrintNode(bytes, 1);
}

// ════════════════════════════════════════════════════════════════════
// HELPERS INTERNOS
// ════════════════════════════════════════════════════════════════════
function _adhListarPlantillas() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var hP = ss.getSheetByName(ADH_HOJA_PLANTILLAS);
  if (!hP || hP.getLastRow() < 2) return [];
  var data = hP.getDataRange().getValues();
  var heads = data[0];
  var rows = [];
  for (var r = 1; r < data.length; r++) {
    var obj = {};
    for (var c = 0; c < heads.length; c++) {
      obj[heads[c]] = data[r][c];
    }
    if (obj.activo === true || String(obj.activo).toUpperCase() === 'TRUE') {
      rows.push({
        idPlantilla:  obj.idPlantilla,
        nombre:       obj.nombre,
        descripcion:  obj.descripcion,
        tamanoCanvas: obj.tamanoCanvas,
        json:         obj.json,
        creadoPor:    obj.creadoPor,
        fechaCreado:  obj.fechaCreado,
        fechaUltMod:  obj.fechaUltMod,
        activo:       true
      });
    }
  }
  return rows;
}

function _adhBuscarPlantilla(id) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var hP = ss.getSheetByName(ADH_HOJA_PLANTILLAS);
  if (!hP) return null;
  var data = hP.getDataRange().getValues();
  var heads = data[0];
  for (var r = 1; r < data.length; r++) {
    if (String(data[r][0]) === String(id)) {
      var obj = {};
      for (var c = 0; c < heads.length; c++) obj[heads[c]] = data[r][c];
      return obj;
    }
  }
  return null;
}

function _adhListarIconos() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var hI = ss.getSheetByName(ADH_HOJA_ICONOS);
  if (!hI || hI.getLastRow() < 2) return [];
  var data = hI.getDataRange().getValues();
  var rows = [];
  for (var r = 1; r < data.length; r++) {
    rows.push({ idIcono: data[r][0], tamano_dots: data[r][1], hex: data[r][2] });
  }
  return rows;
}

function _adhMapaIconos() {
  var rows = _adhListarIconos();
  var map = {};
  rows.forEach(function(r) {
    map[r.idIcono + '__' + r.tamano_dots] = String(r.hex || '');
  });
  return map;
}

function _adhValidar(jsonObj) {
  var errores = [];
  if (!jsonObj || typeof jsonObj !== 'object') {
    errores.push('JSON inválido'); return errores;
  }
  if (!jsonObj.tamano || !jsonObj.tamano.ancho_mm || !jsonObj.tamano.alto_mm) {
    errores.push('Falta tamano.ancho_mm / alto_mm');
  }
  if (!Array.isArray(jsonObj.capas)) {
    errores.push('Falta capas[]'); return errores;
  }
  if (jsonObj.capas.length === 0) errores.push('Plantilla sin capas');
  if (jsonObj.capas.length > ADH_MAX_CAPAS) {
    errores.push('Demasiadas capas (' + jsonObj.capas.length + ' > ' + ADH_MAX_CAPAS + ')');
  }
  var anchoMm = jsonObj.tamano.ancho_mm;
  var altoMm  = jsonObj.tamano.alto_mm;
  jsonObj.capas.forEach(function(c, i) {
    var prefix = '[Capa ' + (i + 1) + ' ' + (c.tipo || '?') + ']';
    if (typeof c.x_mm !== 'number' || typeof c.y_mm !== 'number') {
      errores.push(prefix + ' falta x_mm/y_mm'); return;
    }
    if (c.x_mm < -1 || c.y_mm < -1) errores.push(prefix + ' posición negativa');
    if (c.x_mm > anchoMm) errores.push(prefix + ' X fuera del lienzo');
    if (c.y_mm > altoMm)  errores.push(prefix + ' Y fuera del lienzo');
    if (c.tipo === 'texto' && (!c.texto || !String(c.texto).trim())) errores.push(prefix + ' texto vacío');
    if (c.tipo === 'icono' && !c.idIcono) errores.push(prefix + ' falta idIcono');
    if (c.tipo === 'barcode' && !c.codigo) errores.push(prefix + ' falta código');
  });
  return errores;
}

function _adhCalcularOffsetParaIndice(indice) {
  var props = PropertiesService.getScriptProperties();
  var offsetBase  = parseFloat(props.getProperty('ADHESIVO_OFFSET_Y'))             || 0;
  var driftDots   = parseFloat(props.getProperty('ADHESIVO_DRIFT_DOTS_POR_PRINT')) || 0;
  var printsCount = parseInt  (props.getProperty('ADHESIVO_PRINTS_DESDE_CAL'))     || 0;
  var compensacion = Math.round(driftDots * (printsCount + (indice || 0)));
  var off = offsetBase + compensacion;
  if (off < -1) off = -1;
  if (off > 16) off = 16;
  return off;
}

// ════════════════════════════════════════════════════════════════════
// JSON → TSPL (la conversión maestra)
// ════════════════════════════════════════════════════════════════════
function _adhJson2tspl(jsonObj, offsetY, iconosMap) {
  var props = PropertiesService.getScriptProperties();
  var gapMm   = parseFloat(props.getProperty('ADHESIVO_GAP_MM'))  || 2;
  var density = parseInt(props.getProperty('ADHESIVO_DENSITY'))    || 8;
  var speed   = parseInt(props.getProperty('ADHESIVO_SPEED'))      || 4;

  var lines = [
    'SIZE ' + jsonObj.tamano.ancho_mm + ' mm,' + jsonObj.tamano.alto_mm + ' mm',
    'GAP ' + gapMm + ' mm,0 mm',
    'DIRECTION 1',
    'DENSITY ' + density,
    'SPEED ' + speed,
    'CLS'
  ];

  jsonObj.capas.forEach(function(c) {
    var x = Math.round(c.x_mm * ADH_DOTS_POR_MM);
    var y = Math.round(c.y_mm * ADH_DOTS_POR_MM) + offsetY;
    if (c.tipo === 'texto') {
      var font = String(c.font || 3);
      var rot = c.rotacion || 0;
      var xMul = c.negrita ? 2 : 1, yMul = c.negrita ? 1 : 1;
      var texto = String(c.texto || '').replace(/"/g, "'");
      // Multilínea por \n
      var lineas = texto.split('\n');
      var fpx = { '1': 12, '2': 20, '3': 24, '4': 32, '5': 48 }[font] || 24;
      lineas.forEach(function(ln, idx) {
        lines.push('TEXT ' + x + ',' + (y + idx * Math.round(fpx * 1.05)) + ',"' + font + '",' + rot + ',' + xMul + ',' + yMul + ',"' + ln + '"');
      });
    }
    else if (c.tipo === 'icono') {
      var dots = c.tamano_dots || 48;
      var key = c.idIcono + '__' + dots;
      var hex = iconosMap[key];
      if (!hex) {
        // No tenemos hex de ese tamaño: intentar 48 como fallback
        hex = iconosMap[c.idIcono + '__48'];
        dots = hex ? 48 : 0;
      }
      if (hex && dots > 0) {
        var wBytes = dots / 8;
        // BITMAP necesita los bytes raw, los enviamos como secuencia hex en string TSPL
        // (BITMAP comando + hex inline en la misma línea no funciona; el truco TSPL
        // estándar es BITMAP x,y,wB,h,mode,<binary>. Usamos formato hex en payload
        // con conversion en _adhStrToBytes).
        lines.push('__BITMAP__' + x + ',' + y + ',' + wBytes + ',' + dots + ',' + hex);
      }
    }
    else if (c.tipo === 'linea') {
      var w = Math.round((c.ancho_mm || 0) * ADH_DOTS_POR_MM);
      var h = Math.max(1, Math.round((c.alto_mm || 0.25) * ADH_DOTS_POR_MM));
      lines.push('BAR ' + x + ',' + y + ',' + w + ',' + h);
    }
    else if (c.tipo === 'rectangulo') {
      var rw = Math.round((c.ancho_mm || 5) * ADH_DOTS_POR_MM);
      var rh = Math.round((c.alto_mm || 5) * ADH_DOTS_POR_MM);
      var g = c.grosor || 1;
      if (c.relleno) {
        lines.push('BAR ' + x + ',' + y + ',' + rw + ',' + rh);
      } else {
        lines.push('BAR ' + x + ',' + y + ',' + rw + ',' + g);                    // arriba
        lines.push('BAR ' + x + ',' + (y + rh - g) + ',' + rw + ',' + g);         // abajo
        lines.push('BAR ' + x + ',' + y + ',' + g + ',' + rh);                    // izquierda
        lines.push('BAR ' + (x + rw - g) + ',' + y + ',' + g + ',' + rh);         // derecha
      }
    }
    else if (c.tipo === 'barcode') {
      var codigo = String(c.codigo || '').replace(/"/g, '');
      var alto = c.alto_dots || 48;
      var narrow = c.narrow || 2;
      lines.push('BARCODE ' + x + ',' + y + ',"128",' + alto + ',0,0,' + narrow + ',' + narrow + ',"' + codigo + '"');
    }
    else if (c.tipo === 'qr') {
      var qrCod = String(c.codigo || '').replace(/"/g, '');
      var qrSize = Math.max(2, Math.min(10, Math.round((c.tamano_dots || 64) / 8)));
      lines.push('QRCODE ' + x + ',' + y + ',L,' + qrSize + ',A,0,"' + qrCod + '"');
    }
  });

  lines.push('PRINT 1,1');

  // Convertir a bytes (con manejo especial de __BITMAP__)
  return _adhLinesToBytes(lines);
}

function _adhLinesToBytes(lines) {
  var bytes = [];
  lines.forEach(function(ln) {
    if (ln.indexOf('__BITMAP__') === 0) {
      var rest = ln.substring(10);  // quitar __BITMAP__
      var parts = rest.split(',');
      // Formato: x,y,wB,h,hex
      var prefix = 'BITMAP ' + parts[0] + ',' + parts[1] + ',' + parts[2] + ',' + parts[3] + ',0,';
      bytes = bytes.concat(_adhStrToBytes(prefix));
      bytes = bytes.concat(_adhHexToBytes(parts[4]));
      bytes = bytes.concat(_adhStrToBytes('\r\n'));
    } else {
      bytes = bytes.concat(_adhStrToBytes(ln + '\r\n'));
    }
  });
  return bytes;
}

function _adhStrToBytes(s) {
  var b = [];
  for (var i = 0; i < s.length; i++) b.push(s.charCodeAt(i) & 0xFF);
  return b;
}

function _adhHexToBytes(hex) {
  var b = [];
  hex = String(hex || '').replace(/\s+/g, '');
  for (var i = 0; i < hex.length; i += 2) {
    b.push(parseInt(hex.substring(i, i + 2), 16));
  }
  return b;
}

// ════════════════════════════════════════════════════════════════════
// PrintNode envío directo (sin pasar por WH bridge — autonomo)
// ════════════════════════════════════════════════════════════════════
function _adhEnviarPrintNode(bytes, cantidad) {
  var props = PropertiesService.getScriptProperties();
  var apiKey = props.getProperty('PRINTNODE_API_KEY');
  var printerId = props.getProperty('ADH_PRINTER_ID') || props.getProperty('ENVASADO_PRINTER_ID');
  if (!apiKey) return { ok: false, error: 'Falta PRINTNODE_API_KEY en Script Properties' };
  if (!printerId) return { ok: false, error: 'Falta ADH_PRINTER_ID o ENVASADO_PRINTER_ID en Script Properties' };

  var b64 = Utilities.base64Encode(bytes);
  var payload = {
    printerId: parseInt(printerId),
    title: 'Adhesivo personalizado x' + cantidad,
    contentType: 'raw_base64',
    content: b64,
    source: 'AdhesivosPersonalizados.gs'
  };
  try {
    var res = UrlFetchApp.fetch('https://api.printnode.com/printjobs', {
      method: 'post',
      contentType: 'application/json',
      headers: { Authorization: 'Basic ' + Utilities.base64Encode(apiKey + ':') },
      payload: JSON.stringify(payload),
      muteHttpExceptions: true
    });
    var code = res.getResponseCode();
    var body = res.getContentText();
    if (code >= 200 && code < 300) {
      _adhIncrementarPrintsCount(cantidad);
      return { ok: true, jobId: body, cantidad: cantidad };
    }
    return { ok: false, error: 'PrintNode ' + code + ': ' + body };
  } catch(e) {
    return { ok: false, error: 'fetch fail: ' + e.message };
  }
}

function _adhIncrementarPrintsCount(qty) {
  try {
    var props = PropertiesService.getScriptProperties();
    var current = parseInt(props.getProperty('ADHESIVO_PRINTS_DESDE_CAL')) || 0;
    props.setProperty('ADHESIVO_PRINTS_DESDE_CAL', String(current + qty));
  } catch(_) {}
}
