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
// [v1.0.1 SENIOR AUDIT] LockService para evitar setup concurrente
//   que duplicaría las semillas y carrera al actualizar iconos.
// ════════════════════════════════════════════════════════════════════
function setupAdhesivosBase(payload) {
  payload = payload || {};
  var lock = LockService.getScriptLock();
  var lockHeld = false;
  try {
    lock.waitLock(15000);
    lockHeld = true;

    var ss = SpreadsheetApp.getActiveSpreadsheet();

    // 1) Hoja PLANTILLAS
    var hP = ss.getSheetByName(ADH_HOJA_PLANTILLAS);
    var hojaCreada = false;
    if (!hP) {
      hP = ss.insertSheet(ADH_HOJA_PLANTILLAS);
      hP.appendRow(['idPlantilla', 'nombre', 'descripcion', 'tamanoCanvas', 'json', 'creadoPor', 'fechaCreado', 'fechaUltMod', 'activo']);
      hP.getRange('A1:I1').setFontWeight('bold').setBackground('#1e293b').setFontColor('#fff');
      hP.setFrozenRows(1);
      hojaCreada = true;
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
    // [v1.0.1] Lee la hoja UNA SOLA VEZ y arma un mapa idx para updates O(1).
    if (payload.iconos && typeof payload.iconos === 'object') {
      var dataIconos = hI.getLastRow() > 1 ? hI.getDataRange().getValues() : [['idIcono','tamano_dots','hex']];
      var indexFila = {};  // key → rowNum (1-based) en la hoja
      for (var rI = 1; rI < dataIconos.length; rI++) {
        var key = dataIconos[rI][0] + '__' + dataIconos[rI][1];
        indexFila[key] = rI + 1;  // +1 porque rango es 1-based
      }
      var tamano = parseInt(payload.tamano_dots) || 48;
      var nuevasFilas = [];
      Object.keys(payload.iconos).forEach(function(idIcono) {
        var key = idIcono + '__' + tamano;
        var hex = String(payload.iconos[idIcono] || '');
        if (!hex) return;
        // [v1.0.1] Validar longitud par del hex (defensa anti-NaN en bytes)
        if (hex.length % 2 !== 0) {
          try { Logger.log('[setupAdhesivos] hex impar para ' + idIcono + ' — skip'); } catch(_){}
          return;
        }
        if (indexFila[key]) {
          hI.getRange(indexFila[key], 3).setValue(hex);
        } else {
          nuevasFilas.push([idIcono, tamano, hex]);
        }
      });
      // Inserción batch (mucho más rápido que appendRow N veces)
      if (nuevasFilas.length > 0) {
        var startRow = hI.getLastRow() + 1;
        hI.getRange(startRow, 1, nuevasFilas.length, 3).setValues(nuevasFilas);
      }
    }

    // 4) Plantillas semilla — idempotente por nombre (case-insensitive).
    // [v1.0.2] Antes solo se insertaban si la hoja estaba vacía. Ahora
    // también agrega plantillas semilla NUEVAS que pudieran sumarse en
    // futuras versiones (como las 3 QR del ecosistema sumadas en v1.0.2).
    // Si una semilla ya existe por nombre, NO se sobrescribe (respeta
    // ediciones del admin sobre las semillas originales).
    _adhInsertarSemillasIdempotente(hP);

    return {
      ok: true,
      hojaPlantillasCreada: hojaCreada,
      iconosCargados: payload.iconos ? Object.keys(payload.iconos).length : 0,
      plantillas: _adhListarPlantillas().length
    };
  } catch(e) {
    return { ok: false, error: 'setup falló: ' + e.message };
  } finally {
    if (lockHeld) try { lock.releaseLock(); } catch(_){}
  }
}

// [v1.0.2] Catálogo MAESTRO de semillas. Cualquier plantilla que se agregue
// aquí se inserta automáticamente en el próximo setupAdhesivosBase si NO
// existe ya por nombre (case-insensitive). Esto permite versionar semillas
// nuevas sin perder ediciones del admin sobre las existentes.
function _adhCatalogoSemillas() {
  return [
    // ═══ ORIGINALES v1.0.0 ════════════════════════════════════════
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
    },
    // ═══ AGREGADAS v1.0.2 — QR del ecosistema MOS ══════════════════
    // Diseño profesional: borde rect + icono identificador + branding
    // grande + tagline + QR escaneable 10mm. El operador puede pegar
    // estos adhesivos en estaciones de trabajo y abrir las apps
    // escaneando con la cámara del celular.
    {
      nombre: 'ABRIR_MOS_ADMIN',
      descripcion: 'QR para abrir el panel admin MOS desde el celular',
      json: {
        version: 1,
        tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
        capas: [
          { id: 'qr-mos-bd', tipo: 'rectangulo', x_mm: 0, y_mm: 0, ancho_mm: 50, alto_mm: 25, grosor: 2, relleno: false },
          { id: 'qr-mos-ic', tipo: 'icono', x_mm: 2, y_mm: 3, idIcono: 'diana', tamano_dots: 48 },
          { id: 'qr-mos-t1', tipo: 'texto', x_mm: 10, y_mm: 2, texto: 'MOS', font: 5, alineacion: 'left' },
          { id: 'qr-mos-ln', tipo: 'linea', x_mm: 2, y_mm: 13, ancho_mm: 22, alto_mm: 0.4 },
          { id: 'qr-mos-t2', tipo: 'texto', x_mm: 2, y_mm: 14, texto: 'ADMIN', font: 3, alineacion: 'left' },
          { id: 'qr-mos-t3', tipo: 'texto', x_mm: 2, y_mm: 20, texto: 'Escanea', font: 2, alineacion: 'left' },
          { id: 'qr-mos-qr', tipo: 'qr', x_mm: 28, y_mm: 4, codigo: 'https://levo19.github.io/MOS/', tamano_dots: 80 }
        ]
      }
    },
    {
      nombre: 'ABRIR_WAREHOUSEMOS',
      descripcion: 'QR para abrir warehouseMos (almacen) desde el celular',
      json: {
        version: 1,
        tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
        capas: [
          { id: 'qr-wh-bd', tipo: 'rectangulo', x_mm: 0, y_mm: 0, ancho_mm: 50, alto_mm: 25, grosor: 2, relleno: false },
          { id: 'qr-wh-ic', tipo: 'icono', x_mm: 2, y_mm: 3, idIcono: 'caja', tamano_dots: 48 },
          { id: 'qr-wh-t1', tipo: 'texto', x_mm: 10, y_mm: 2, texto: 'WH', font: 5, alineacion: 'left' },
          { id: 'qr-wh-ln', tipo: 'linea', x_mm: 2, y_mm: 13, ancho_mm: 22, alto_mm: 0.4 },
          { id: 'qr-wh-t2', tipo: 'texto', x_mm: 2, y_mm: 14, texto: 'ALMACEN', font: 3, alineacion: 'left' },
          { id: 'qr-wh-t3', tipo: 'texto', x_mm: 2, y_mm: 20, texto: 'Escanea', font: 2, alineacion: 'left' },
          { id: 'qr-wh-qr', tipo: 'qr', x_mm: 28, y_mm: 4, codigo: 'https://levo19.github.io/warehouseMos-/', tamano_dots: 80 }
        ]
      }
    },
    {
      nombre: 'ABRIR_MOSEXPRESS',
      descripcion: 'QR para abrir MosExpress (POS caja) desde el celular',
      json: {
        version: 1,
        tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
        capas: [
          { id: 'qr-me-bd', tipo: 'rectangulo', x_mm: 0, y_mm: 0, ancho_mm: 50, alto_mm: 25, grosor: 2, relleno: false },
          { id: 'qr-me-ic', tipo: 'icono', x_mm: 2, y_mm: 3, idIcono: 'rayo', tamano_dots: 48 },
          { id: 'qr-me-t1', tipo: 'texto', x_mm: 10, y_mm: 2, texto: 'ME', font: 5, alineacion: 'left' },
          { id: 'qr-me-ln', tipo: 'linea', x_mm: 2, y_mm: 13, ancho_mm: 22, alto_mm: 0.4 },
          { id: 'qr-me-t2', tipo: 'texto', x_mm: 2, y_mm: 14, texto: 'EXPRESS', font: 3, alineacion: 'left' },
          { id: 'qr-me-t3', tipo: 'texto', x_mm: 2, y_mm: 20, texto: 'POS Caja', font: 2, alineacion: 'left' },
          { id: 'qr-me-qr', tipo: 'qr', x_mm: 28, y_mm: 4, codigo: 'https://levo19.github.io/MosExpress/', tamano_dots: 80 }
        ]
      }
    }
  ];
}

// [v1.0.2] Inserción idempotente: agrega semillas que no existan por nombre.
// Preserva ediciones del admin sobre semillas anteriores.
function _adhInsertarSemillasIdempotente(hP) {
  var semillas = _adhCatalogoSemillas();
  // Leer plantillas existentes (índice por nombre lowercase)
  var existentesPorNombre = {};
  if (hP.getLastRow() > 1) {
    var data = hP.getDataRange().getValues();
    for (var r = 1; r < data.length; r++) {
      existentesPorNombre[String(data[r][1] || '').toLowerCase()] = true;
    }
  }
  var now = new Date();
  var creador = 'SYSTEM';
  var nuevas = [];
  semillas.forEach(function(s, i) {
    if (existentesPorNombre[s.nombre.toLowerCase()]) return;  // skip si ya existe
    // ID estable: usa timestamp + slug del nombre para evitar colisión
    var idSlug = s.nombre.replace(/[^A-Z0-9]/gi, '').toUpperCase().substring(0, 12);
    var id = 'ADH-SEED-' + idSlug;
    nuevas.push([id, s.nombre, s.descripcion, '50x25', JSON.stringify(s.json), creador, now, now, true]);
  });
  if (nuevas.length > 0) {
    var startRow = hP.getLastRow() + 1;
    hP.getRange(startRow, 1, nuevas.length, 9).setValues(nuevas);
  }
  return nuevas.length;
}

// Wrapper legacy (compat con código existente)
function _adhInsertarSemillas(hP) {
  return _adhInsertarSemillasIdempotente(hP);
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

  // [v1.0.1 SENIOR AUDIT] Lectura de data DENTRO del lock (antes era stale:
  // si otro proceso modificaba la hoja entre lectura y check, los índices
  // de fila quedaban incorrectos y podías sobrescribir la plantilla equivocada).
  var lock = LockService.getScriptLock();
  var lockHeld = false;
  try {
    lock.waitLock(10000);
    lockHeld = true;
    var ss = SpreadsheetApp.getActiveSpreadsheet();
    var hP = ss.getSheetByName(ADH_HOJA_PLANTILLAS);
    if (!hP) return { ok: false, error: 'Hoja ' + ADH_HOJA_PLANTILLAS + ' no existe. Corre setupAdhesivosBase()' };
    // Re-leer DENTRO del lock — no antes
    var data = hP.getDataRange().getValues();

    var ahora = new Date();
    var creador = params.creadoPor || 'ADMIN';
    var idPlantilla = params.idPlantilla;
    var tamanoStr = (jsonObj.tamano.ancho_mm || 50) + 'x' + (jsonObj.tamano.alto_mm || 25);
    var jsonStr = JSON.stringify(jsonObj);

    if (idPlantilla) {
      // Actualizar fila existente — batch setValues para 1 sola operación
      for (var r = 1; r < data.length; r++) {
        if (String(data[r][0]) === String(idPlantilla)) {
          hP.getRange(r + 1, 2, 1, 4).setValues([[nombre, params.descripcion || '', tamanoStr, jsonStr]]);
          hP.getRange(r + 1, 8, 1, 2).setValues([[ahora, true]]);
          return { ok: true, idPlantilla: idPlantilla, actualizado: true };
        }
      }
      return { ok: false, error: 'idPlantilla no encontrada: ' + idPlantilla };
    } else {
      // [v1.0.1] Chequear que nombre no esté duplicado (case-insensitive)
      var nombreLc = nombre.toLowerCase();
      for (var rN = 1; rN < data.length; rN++) {
        if (String(data[rN][1] || '').toLowerCase() === nombreLc
            && (data[rN][8] === true || String(data[rN][8]).toUpperCase() === 'TRUE')) {
          return { ok: false, error: 'Ya existe plantilla activa con nombre "' + nombre + '"' };
        }
      }
      idPlantilla = 'ADH-' + Utilities.getUuid().substring(0, 8).toUpperCase();
      hP.appendRow([
        idPlantilla, nombre, params.descripcion || '', tamanoStr,
        jsonStr, creador, ahora, ahora, true
      ]);
      return { ok: true, idPlantilla: idPlantilla, creado: true };
    }
  } catch(e) {
    return { ok: false, error: 'guardar falló: ' + e.message };
  } finally {
    if (lockHeld) try { lock.releaseLock(); } catch(_){}
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

  // [v1.0.1 SENIOR AUDIT] LockService — antes 2 admins concurrentes leían el
  // mismo printsCount y los offsets de drift se calculaban mal en la 2ª tanda,
  // descalibrando la impresora a la mitad del lote.
  var lock = LockService.getScriptLock();
  var lockHeld = false;
  try {
    lock.waitLock(15000);
    lockHeld = true;

    var p = _adhBuscarPlantilla(id);
    if (!p) return { ok: false, error: 'no encontrada: ' + id };
    if (p.activo !== true && String(p.activo).toUpperCase() !== 'TRUE') {
      return { ok: false, error: 'plantilla inactiva' };
    }

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

    return _adhEnviarPrintNode(bytesTotal, cantidad, p.nombre);
  } catch(e) {
    return { ok: false, error: 'imprimir falló: ' + e.message };
  } finally {
    if (lockHeld) try { lock.releaseLock(); } catch(_){}
  }
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
  return _adhEnviarPrintNode(bytes, 1, '[TEST] ' + (p.nombre || p.idPlantilla));
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
    if (_adhEsActivo(obj.activo)) {
      // [v1.0.4] Parsear JSON server-side. Antes lo devolvíamos como string
      // y el frontend hacía JSON.parse en cada uso — error-prone si la
      // plantilla está corrupta (frontend caía con SyntaxError raw, sin
      // posibilidad de mostrar UX limpio). Ahora server-side parsing con
      // try/catch + flag jsonCorrupto si falla.
      var jsonParseado = null;
      var jsonCorrupto = false;
      try {
        jsonParseado = typeof obj.json === 'string' ? JSON.parse(obj.json) : obj.json;
      } catch(e) {
        jsonCorrupto = true;
        try { Logger.log('[_adhListarPlantillas] JSON corrupto en ' + obj.idPlantilla + ': ' + e.message); } catch(_){}
      }
      rows.push({
        idPlantilla:  obj.idPlantilla,
        nombre:       obj.nombre,
        descripcion:  obj.descripcion,
        tamanoCanvas: obj.tamanoCanvas,
        json:         jsonParseado,
        jsonCorrupto: jsonCorrupto,
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

// [v1.0.1 SENIOR AUDIT] Validador endurecido:
//   • isFinite() previene NaN/Infinity llegando a TSPL como string "NaN"
//   • Clamp duro de alto_dots/narrow/tamano_dots → rechaza valores raros
//   • Validación tipos (rotacion debe ser 0/90/180/270 según TSPL)
//   • Valida tipo desconocido (capa con tipo='xxx' inválido)
var ADH_TIPOS_VALIDOS = ['texto', 'icono', 'linea', 'rectangulo', 'barcode', 'qr'];
var ADH_ROTACIONES_VALIDAS = [0, 90, 180, 270];

function _adhValidar(jsonObj) {
  var errores = [];
  if (!jsonObj || typeof jsonObj !== 'object') {
    errores.push('JSON inválido'); return errores;
  }
  if (!jsonObj.tamano || !isFinite(jsonObj.tamano.ancho_mm) || !isFinite(jsonObj.tamano.alto_mm)) {
    errores.push('Falta o inválido tamano.ancho_mm / alto_mm');
  }
  if (!Array.isArray(jsonObj.capas)) {
    errores.push('Falta capas[]'); return errores;
  }
  if (jsonObj.capas.length === 0) errores.push('Plantilla sin capas');
  if (jsonObj.capas.length > ADH_MAX_CAPAS) {
    errores.push('Demasiadas capas (' + jsonObj.capas.length + ' > ' + ADH_MAX_CAPAS + ')');
  }
  var anchoMm = jsonObj.tamano && jsonObj.tamano.ancho_mm;
  var altoMm  = jsonObj.tamano && jsonObj.tamano.alto_mm;
  jsonObj.capas.forEach(function(c, i) {
    var prefix = '[Capa ' + (i + 1) + ' ' + (c.tipo || '?') + ']';
    if (!c || typeof c !== 'object') {
      errores.push(prefix + ' no es objeto'); return;
    }
    if (ADH_TIPOS_VALIDOS.indexOf(c.tipo) < 0) {
      errores.push(prefix + ' tipo desconocido: ' + c.tipo); return;
    }
    if (!isFinite(c.x_mm) || !isFinite(c.y_mm)) {
      errores.push(prefix + ' x_mm/y_mm no numéricos'); return;
    }
    if (c.x_mm < -1 || c.y_mm < -1) errores.push(prefix + ' posición negativa');
    if (c.x_mm > anchoMm) errores.push(prefix + ' X fuera del lienzo');
    if (c.y_mm > altoMm)  errores.push(prefix + ' Y fuera del lienzo');
    if (c.tipo === 'texto') {
      if (!c.texto || !String(c.texto).trim()) errores.push(prefix + ' texto vacío');
      if (c.font && [1,2,3,4,5].indexOf(parseInt(c.font)) < 0) errores.push(prefix + ' font inválida');
      if (c.rotacion !== undefined && ADH_ROTACIONES_VALIDAS.indexOf(parseInt(c.rotacion)) < 0) {
        errores.push(prefix + ' rotacion debe ser 0/90/180/270');
      }
    }
    if (c.tipo === 'icono') {
      if (!c.idIcono) errores.push(prefix + ' falta idIcono');
      if (c.tamano_dots !== undefined && (!isFinite(c.tamano_dots) || c.tamano_dots < 16 || c.tamano_dots > 192)) {
        errores.push(prefix + ' tamano_dots fuera de rango (16-192)');
      }
    }
    if (c.tipo === 'barcode') {
      if (!c.codigo) errores.push(prefix + ' falta código');
      if (c.alto_dots !== undefined && (!isFinite(c.alto_dots) || c.alto_dots < 16 || c.alto_dots > 200)) {
        errores.push(prefix + ' alto_dots fuera de rango (16-200)');
      }
      if (c.narrow !== undefined && (!isFinite(c.narrow) || c.narrow < 1 || c.narrow > 5)) {
        errores.push(prefix + ' narrow fuera de rango (1-5)');
      }
    }
    if (c.tipo === 'qr') {
      if (!c.codigo) errores.push(prefix + ' falta contenido QR');
      if (c.tamano_dots !== undefined && (!isFinite(c.tamano_dots) || c.tamano_dots < 16 || c.tamano_dots > 200)) {
        errores.push(prefix + ' tamano_dots QR fuera de rango (16-200)');
      }
    }
    if (c.tipo === 'linea' || c.tipo === 'rectangulo') {
      if (c.ancho_mm !== undefined && !isFinite(c.ancho_mm)) errores.push(prefix + ' ancho_mm inválido');
      if (c.alto_mm !== undefined && !isFinite(c.alto_mm)) errores.push(prefix + ' alto_mm inválido');
    }
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
      // [v1.0.1] Negrita: usar xMul=2 y yMul=2 (escala uniforme) en lugar
      // de solo xMul=2 (que estiraba horizontal — preview mostraba peso
      // pero impresión salía ALARGADA). Ahora coincide con SVG font-weight.
      var xMul = c.negrita ? 2 : 1, yMul = c.negrita ? 2 : 1;
      var texto = String(c.texto || '').replace(/"/g, "'");
      // Char width aproximado por Font (Font 1=8, 2=12, 3=16, 4=24, 5=32 dots)
      var fontW = { '1': 8, '2': 12, '3': 16, '4': 24, '5': 32 }[font] || 16;
      var fpx = { '1': 12, '2': 20, '3': 24, '4': 32, '5': 48 }[font] || 24;
      // Multilínea por \n
      var lineas = texto.split('\n');
      lineas.forEach(function(ln, idx) {
        var lineWidth = ln.length * fontW * xMul;
        // [v1.0.1 SENIOR AUDIT] Soporte de alineación CENTER/RIGHT en TSPL —
        // antes backend siempre alineaba left aunque preview mostraba centro.
        // Inconsistencia crítica: lo que el admin diseñaba con alineación
        // centrada salía con alineación izquierda en impresión.
        // [v1.0.4 defensa NaN] c.ancho_mm puede ser undefined/0/NaN. Si no es
        // un número finito > 0, fallback al ancho restante del canvas.
        var xFinal = x;
        var anchoDisponibleDots;
        if (isFinite(c.ancho_mm) && c.ancho_mm > 0) {
          anchoDisponibleDots = c.ancho_mm * ADH_DOTS_POR_MM;
        } else {
          anchoDisponibleDots = jsonObj.tamano.ancho_mm * ADH_DOTS_POR_MM - x;
        }
        if (c.alineacion === 'center') {
          xFinal = x + Math.round((anchoDisponibleDots - lineWidth) / 2);
          if (xFinal < 0) xFinal = 0;
        } else if (c.alineacion === 'right') {
          xFinal = x + Math.round(anchoDisponibleDots - lineWidth);
          if (xFinal < 0) xFinal = 0;
        }
        var yLine = y + idx * Math.round(fpx * 1.05);
        lines.push('TEXT ' + xFinal + ',' + yLine + ',"' + font + '",' + rot + ',' + xMul + ',' + yMul + ',"' + ln + '"');
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
      // [v1.0.1] Clamp defensivo — admin puede haber metido valores raros vía
      // edición manual del JSON. Sin clamp: alto=99999 → TSPL falla o sale ilegible.
      var alto = isFinite(c.alto_dots) ? Math.max(16, Math.min(200, c.alto_dots)) : 48;
      var narrow = isFinite(c.narrow) ? Math.max(1, Math.min(5, c.narrow)) : 2;
      lines.push('BARCODE ' + x + ',' + y + ',"128",' + alto + ',0,0,' + narrow + ',' + narrow + ',"' + codigo + '"');
    }
    else if (c.tipo === 'qr') {
      var qrCod = String(c.codigo || '').replace(/"/g, '');
      // QRCODE TSPL cellWidth: 1-10 dots por celda
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
  hex = String(hex || '').replace(/[^0-9A-Fa-f]/g, '');  // [v1.0.1] solo hex chars
  // [v1.0.1] Truncar si longitud impar (último char queda colgando = NaN al parsear)
  if (hex.length % 2 !== 0) hex = hex.substring(0, hex.length - 1);
  for (var i = 0; i < hex.length; i += 2) {
    var val = parseInt(hex.substring(i, i + 2), 16);
    b.push(isNaN(val) ? 0 : val);
  }
  return b;
}

// ════════════════════════════════════════════════════════════════════
// PrintNode envío directo
// [v1.0.4 SENIOR AUDIT] Fix arquitectural reportado por usuario:
//   ANTES: leía printerId de Script Properties (ADH_PRINTER_ID o
//          ENVASADO_PRINTER_ID) — fuente de verdad DUPLICADA con
//          la tabla IMPRESORAS y propensa a inconsistencias.
//   AHORA: lee desde hoja IMPRESORAS (tipo=ADHESIVO + idZona=ALMACEN
//          + activo=true + printNodeId no vacío) — MISMA fuente que
//          getPrinterNodeId() de WH/Envasados.gs/Membretes.gs.
//          Centralizado, consistente, sin duplicación.
// ════════════════════════════════════════════════════════════════════
function _adhGetPrinterNodeId() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName('IMPRESORAS');
  if (!sheet) throw new Error('Hoja IMPRESORAS no encontrada en MOS');
  var rows = _sheetToObjects(sheet);
  // 1ª preferencia: tipo=ADHESIVO + idZona=ALMACEN activa
  var imp = rows.find(function(r) {
    return r.tipo === 'ADHESIVO'
        && r.idZona === 'ALMACEN'
        && _adhEsActivo(r.activo)
        && String(r.printNodeId || '').trim() !== '';
  });
  if (!imp) {
    // 2ª preferencia: cualquier ADHESIVO activa (otra zona)
    imp = rows.find(function(r) {
      return r.tipo === 'ADHESIVO'
          && _adhEsActivo(r.activo)
          && String(r.printNodeId || '').trim() !== '';
    });
  }
  if (!imp) {
    throw new Error('No hay impresora tipo ADHESIVO activa con printNodeId en hoja IMPRESORAS');
  }
  return String(imp.printNodeId).trim();
}

function _adhEsActivo(v) {
  if (v === true || v === 1) return true;
  var s = String(v || '').toUpperCase().trim();
  return s === 'TRUE' || s === '1' || s === 'SI' || s === 'YES';
}

function _adhEnviarPrintNode(bytes, cantidad, nombrePlantilla) {
  // [v1.0.4] Defensa contra TSPL vacío (caso edge si validador deja pasar
  // plantilla degenerada) — PrintNode rechazaría con error críptico.
  if (!bytes || bytes.length === 0) {
    return { ok: false, error: 'TSPL vacío — plantilla sin contenido imprimible' };
  }
  if (bytes.length > 1024 * 1024) {
    return { ok: false, error: 'TSPL muy grande (' + bytes.length + ' bytes) — revisar plantilla' };
  }
  var apiKey = PropertiesService.getScriptProperties().getProperty('PRINTNODE_API_KEY');
  if (!apiKey) return { ok: false, error: 'Falta PRINTNODE_API_KEY en Script Properties de MOS' };

  var printerId;
  try {
    printerId = _adhGetPrinterNodeId();
  } catch(e) {
    return { ok: false, error: e.message };
  }

  // [v1.0.4] Title con nombre de plantilla → debugging desde PrintNode dashboard
  var title = 'Aviso ' + (nombrePlantilla ? '"' + String(nombrePlantilla).substring(0, 40) + '" ' : '')
            + 'x' + cantidad;

  var b64 = Utilities.base64Encode(bytes);
  var payload = {
    printerId: parseInt(printerId),
    title: title,
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
      return { ok: true, jobId: body, cantidad: cantidad, printerId: printerId };
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
