// ============================================================
// MOS — Horarios.gs
// [v2.43.30] Control central de horarios de apertura/cierre de las
// apps del ecosistema (WH y ME) + horarios custom por usuario.
//
// Modelo:
//   1. CONFIG_HORARIOS_APPS  → 1 fila por app, JSON con 7 días
//   2. PERSONAL_MASTER.horarioCustom  → JSON opcional por usuario
//
// JSON formato semana:
//   {
//     lun: {activo:true, apertura:"07:00", cierre:"19:00"},
//     mar: {...}, mie: {...}, jue: {...}, vie: {...},
//     sab: {...},
//     dom: {activo:false}  ← cerrado
//   }
//
// Política de resolución:
//   - Si idPersonal tiene horarioCustom.activo === true → prevalece
//   - Si rol es MASTER/ADMINISTRADOR y app.admins_libres → permitido siempre
//   - Si no → usa horario de la app (CONFIG_HORARIOS_APPS)
// ============================================================

var _HOR_DIAS = ['lun','mar','mie','jue','vie','sab','dom'];

// Auto-crea hoja CONFIG_HORARIOS_APPS con valores por defecto
function _asegurarHojaHorariosApps() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName('CONFIG_HORARIOS_APPS');
  if (!sh) {
    sh = ss.insertSheet('CONFIG_HORARIOS_APPS');
    sh.appendRow(['app','horarioJson','admins_libres','actualizadoPor','fechaActualizacion']);
    sh.getRange(1, 1, 1, 5).setFontWeight('bold')
      .setBackground('#0f172a').setFontColor('#67e8f9');
    sh.setFrozenRows(1);
    // Defaults (mantiene compatibilidad con hardcoded _horarioPermitido WH viejo)
    var defaultWH = {
      lun: { activo: true, apertura: '07:00', cierre: '19:00' },
      mar: { activo: true, apertura: '07:00', cierre: '19:00' },
      mie: { activo: true, apertura: '07:00', cierre: '19:00' },
      jue: { activo: true, apertura: '07:00', cierre: '19:00' },
      vie: { activo: true, apertura: '07:00', cierre: '19:00' },
      sab: { activo: true, apertura: '07:00', cierre: '19:00' },
      dom: { activo: true, apertura: '07:00', cierre: '16:00' }
    };
    var defaultME = {
      lun: { activo: true, apertura: '06:00', cierre: '23:00' },
      mar: { activo: true, apertura: '06:00', cierre: '23:00' },
      mie: { activo: true, apertura: '06:00', cierre: '23:00' },
      jue: { activo: true, apertura: '06:00', cierre: '23:00' },
      vie: { activo: true, apertura: '06:00', cierre: '23:00' },
      sab: { activo: true, apertura: '06:00', cierre: '23:00' },
      dom: { activo: true, apertura: '07:00', cierre: '22:00' }
    };
    sh.appendRow(['warehouseMos', JSON.stringify(defaultWH), true, 'sistema', new Date()]);
    sh.appendRow(['mosExpress',   JSON.stringify(defaultME), true, 'sistema', new Date()]);
  }
  return sh;
}

// [v2.43.30] Devuelve horarios de TODAS las apps. Frontend MOS lo usa para
// el panel Personal.
function getHorariosApps() {
  var sh = _asegurarHojaHorariosApps();
  var rows = _sheetToObjects(sh);
  var byApp = {};
  rows.forEach(function(r) {
    var hor = {};
    try { hor = r.horarioJson ? JSON.parse(r.horarioJson) : {}; } catch(_) {}
    byApp[r.app] = {
      app:            r.app,
      horario:        hor,
      admins_libres:  String(r.admins_libres) === 'true' || r.admins_libres === true,
      actualizadoPor: r.actualizadoPor || '',
      fechaActualizacion: r.fechaActualizacion instanceof Date ? r.fechaActualizacion.toISOString() : String(r.fechaActualizacion || '')
    };
  });
  return { ok: true, data: byApp };
}

// [v2.43.30] Setea horario completo de una app + push a operadores afectados
function setHorarioApp(params) {
  var app = String(params.app || '').trim();
  if (!app) return { ok: false, error: 'app requerida' };
  if (app !== 'warehouseMos' && app !== 'mosExpress') {
    return { ok: false, error: 'app no soportada (warehouseMos | mosExpress)' };
  }
  var horario = params.horario || {};
  // Validar 7 días
  var horValidado = {};
  _HOR_DIAS.forEach(function(d) {
    var c = horario[d] || {};
    horValidado[d] = {
      activo:   c.activo !== false,
      apertura: String(c.apertura || '07:00'),
      cierre:   String(c.cierre   || '19:00')
    };
  });

  var sh = _asegurarHojaHorariosApps();
  var data = sh.getDataRange().getValues();
  var h = data[0];
  var iApp = h.indexOf('app');
  var iHor = h.indexOf('horarioJson');
  var iAdm = h.indexOf('admins_libres');
  var iAct = h.indexOf('actualizadoPor');
  var iFec = h.indexOf('fechaActualizacion');

  var filaFound = -1;
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iApp]) === app) { filaFound = i + 1; break; }
  }
  var admins_libres = params.admins_libres !== false;
  var actualizadoPor = String(params.actualizadoPor || 'admin-mos');
  var ts = new Date();
  if (filaFound > 0) {
    sh.getRange(filaFound, iHor + 1).setValue(JSON.stringify(horValidado));
    sh.getRange(filaFound, iAdm + 1).setValue(admins_libres);
    sh.getRange(filaFound, iAct + 1).setValue(actualizadoPor);
    sh.getRange(filaFound, iFec + 1).setValue(ts);
  } else {
    sh.appendRow([app, JSON.stringify(horValidado), admins_libres, actualizadoPor, ts]);
  }

  // [v2.43.30] Push obligatorio a operadores de la app afectada
  try {
    var resumen = _resumenHorarioParaPush(horValidado);
    var titulo  = '🕐 Horario actualizado · ' + (app === 'warehouseMos' ? 'Almacén' : 'POS');
    var cuerpo  = resumen + ' · revisa al iniciar sesión';
    if (typeof _enviarPushTodos === 'function') {
      var appFiltro = app === 'warehouseMos' ? 'WH' : 'ME';
      _enviarPushTodos(titulo, cuerpo, { idNotif: 'MOS_HORARIO_APP', soloRolesME: app === 'mosExpress', soloRolesWH: app === 'warehouseMos' });
    }
  } catch(eP) { Logger.log('[setHorarioApp] push fallo: ' + eP.message); }

  return { ok: true, data: { app: app, horario: horValidado, admins_libres: admins_libres } };
}

function _resumenHorarioParaPush(hor) {
  var partes = [];
  _HOR_DIAS.forEach(function(d) {
    var c = hor[d];
    if (!c || !c.activo) partes.push(d + ': cerrado');
    else partes.push(d + ': ' + c.apertura + '-' + c.cierre);
  });
  // Si todos iguales, simplifica
  var primero = partes[0];
  if (partes.every(function(p) { return p === primero; })) return primero;
  return partes.join(' · ');
}

// [v2.43.30] Set/eliminar horario custom de UN usuario específico.
// Lo guarda en columna horarioCustom de PERSONAL_MASTER (auto-crea si falta).
function setHorarioCustomPersonal(params) {
  var idPersonal = String(params.idPersonal || '').trim();
  if (!idPersonal) return { ok: false, error: 'idPersonal requerido' };
  var horarioCustom = params.horarioCustom || null;

  var sheet = getSheet('PERSONAL_MASTER');
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var idxId = hdrs.indexOf('idPersonal');
  var idxHC = hdrs.indexOf('horarioCustom');
  // Auto-añadir columna horarioCustom si no existe
  if (idxHC < 0) {
    var newCol = hdrs.length + 1;
    sheet.getRange(1, newCol).setValue('horarioCustom');
    sheet.getRange(1, newCol).setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
    idxHC = newCol - 1;
  }
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][idxId]) !== idPersonal) continue;
    var fila = i + 1;
    if (!horarioCustom || horarioCustom.activo === false) {
      sheet.getRange(fila, idxHC + 1).setValue('');
      // Push obligatorio al operador
      try {
        var nombre = String(data[i][hdrs.indexOf('nombre')] || '');
        if (typeof _enviarPushTodos === 'function') {
          _enviarPushTodos(
            '🕐 Horario custom eliminado',
            'Hola ' + nombre + ' · vuelves al horario general de la app',
            { idNotif: 'MOS_HORARIO_CUSTOM' }
          );
        }
      } catch(_){}
      return { ok: true, data: { idPersonal: idPersonal, accion: 'ELIMINADO' } };
    }
    // Validar JSON: 7 días con activo/apertura/cierre
    var hcValido = {};
    _HOR_DIAS.forEach(function(d) {
      var c = (horarioCustom.dias && horarioCustom.dias[d]) || horarioCustom[d] || {};
      hcValido[d] = {
        activo:   c.activo !== false,
        apertura: String(c.apertura || '07:00'),
        cierre:   String(c.cierre   || '19:00')
      };
    });
    var horarioFinal = {
      activo:  true,
      dias:    hcValido,
      motivo:  String(horarioCustom.motivo || ''),
      ts:      new Date().toISOString()
    };
    sheet.getRange(fila, idxHC + 1).setValue(JSON.stringify(horarioFinal));
    // Push obligatorio
    try {
      var nombre2 = String(data[i][hdrs.indexOf('nombre')] || '');
      if (typeof _enviarPushTodos === 'function') {
        _enviarPushTodos(
          '🕐 Horario personalizado activo',
          'Hola ' + nombre2 + ' · ' + _resumenHorarioParaPush(hcValido),
          { idNotif: 'MOS_HORARIO_CUSTOM' }
        );
      }
    } catch(_){}
    return { ok: true, data: { idPersonal: idPersonal, accion: 'ACTUALIZADO', horarioCustom: horarioFinal } };
  }
  return { ok: false, error: 'idPersonal no encontrado' };
}

// [v2.43.30] Resuelve si UN operador puede acceder ahora.
// Cliente (WH/ME) consulta esto al login y heartbeat.
//
// Política:
//   1. Si rol MASTER/ADMINISTRADOR y admins_libres de la app → permitido
//   2. Si idPersonal tiene horarioCustom.activo → usa custom
//   3. Sino usa horario de la app
//   4. Si día actual no activo → bloqueado
//   5. Si hora actual fuera del rango activo → bloqueado
function resolverHorarioPersonal(params) {
  var idPersonal = String(params.idPersonal || '').trim();
  var rol  = String(params.rol  || '').toUpperCase();
  var app  = String(params.app  || '').trim();
  if (!app) return { ok: false, error: 'app requerida' };

  var horariosRes = getHorariosApps();
  var byApp = (horariosRes && horariosRes.data) || {};
  var appConf = byApp[app] || { horario: {}, admins_libres: true };

  if ((rol === 'MASTER' || rol === 'ADMINISTRADOR') && appConf.admins_libres) {
    return { ok: true, data: { permitido: true, motivo: 'rol_admin_libre', fuente: 'app' } };
  }

  // Buscar horarioCustom del operador
  var horarioOperador = null;
  var fuente = 'app';
  if (idPersonal) {
    try {
      var pSh = getSheet('PERSONAL_MASTER');
      var pd  = pSh.getDataRange().getValues();
      var ph  = pd[0];
      var iId = ph.indexOf('idPersonal');
      var iHC = ph.indexOf('horarioCustom');
      if (iHC >= 0) {
        for (var i = 1; i < pd.length; i++) {
          if (String(pd[i][iId]) === idPersonal) {
            var hcRaw = pd[i][iHC];
            if (hcRaw) {
              try {
                var hcObj = JSON.parse(hcRaw);
                if (hcObj && hcObj.activo && hcObj.dias) {
                  horarioOperador = hcObj.dias;
                  fuente = 'custom';
                }
              } catch(_){}
            }
            break;
          }
        }
      }
    } catch(_){}
  }
  if (!horarioOperador) horarioOperador = appConf.horario || {};

  // Calcular si hoy/ahora permitido
  var tz = Session.getScriptTimeZone();
  var ahora = new Date();
  var diaIdx = parseInt(Utilities.formatDate(ahora, tz, 'u'), 10);  // 1=lun, 7=dom
  var diaKey = _HOR_DIAS[Math.max(0, Math.min(6, diaIdx - 1))];
  var configDia = horarioOperador[diaKey] || {};
  if (!configDia.activo) {
    return {
      ok: true,
      data: {
        permitido: false,
        motivo: 'dia_cerrado',
        fuente: fuente,
        dia: diaKey,
        apertura: configDia.apertura || null,
        cierre: configDia.cierre || null
      }
    };
  }
  var horaActual = parseInt(Utilities.formatDate(ahora, tz, 'H'), 10);
  var minActual  = parseInt(Utilities.formatDate(ahora, tz, 'm'), 10);
  var horaDecimal = horaActual + (minActual / 60);
  var apert = _parseHora(configDia.apertura);
  var cierre= _parseHora(configDia.cierre);
  if (apert === null || cierre === null) {
    return { ok: true, data: { permitido: true, motivo: 'hora_invalida_permitir', fuente: fuente, dia: diaKey } };
  }
  var permitido = horaDecimal >= apert && horaDecimal < cierre;
  return {
    ok: true,
    data: {
      permitido: permitido,
      motivo: permitido ? 'en_horario' : (horaDecimal < apert ? 'antes_apertura' : 'despues_cierre'),
      fuente: fuente,
      dia: diaKey,
      apertura: configDia.apertura,
      cierre: configDia.cierre
    }
  };
}

function _parseHora(s) {
  s = String(s || '').trim();
  var m = s.match(/^(\d{1,2}):?(\d{2})?$/);
  if (!m) return null;
  return parseInt(m[1], 10) + (parseInt(m[2] || '0', 10) / 60);
}
