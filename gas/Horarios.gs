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
    // [v2.43.31] App MOS — 24/7 por defecto (admins libres)
    var defaultMOS = {
      lun: { activo: true, apertura: '00:00', cierre: '23:59' },
      mar: { activo: true, apertura: '00:00', cierre: '23:59' },
      mie: { activo: true, apertura: '00:00', cierre: '23:59' },
      jue: { activo: true, apertura: '00:00', cierre: '23:59' },
      vie: { activo: true, apertura: '00:00', cierre: '23:59' },
      sab: { activo: true, apertura: '00:00', cierre: '23:59' },
      dom: { activo: true, apertura: '00:00', cierre: '23:59' }
    };
    sh.appendRow(['warehouseMos', JSON.stringify(defaultWH), true, 'sistema', new Date()]);
    sh.appendRow(['mosExpress',   JSON.stringify(defaultME), true, 'sistema', new Date()]);
    sh.appendRow(['MOS',          JSON.stringify(defaultMOS), true, 'sistema', new Date()]);
  }
  return sh;
}

// [v2.43.30] Devuelve horarios de TODAS las apps. Frontend MOS lo usa para
// el panel Personal.
function getHorariosApps() {
  var dir = _sbLeerObjetoMOS('horarios_apps', {}, 'MOS_HORARIO_LECTURA');
  if (dir !== null) return { ok: true, data: dir };
  var sh = _asegurarHojaHorariosApps();
  var rows = _sheetToObjects(sh);
  var byApp = {};
  rows.forEach(function(r) {
    var hor = {};
    try { hor = r.horarioJson ? JSON.parse(r.horarioJson) : {}; } catch(_) {}
    byApp[r.app] = {
      app:            r.app,
      horario:        hor,
      dias:           hor,  // [v2.43.130 FIX] alias para SeguridadSystem (que lee .dias)
      admins_libres:  String(r.admins_libres) === 'true' || r.admins_libres === true,
      actualizadoPor: r.actualizadoPor || '',
      fechaActualizacion: r.fechaActualizacion instanceof Date ? r.fechaActualizacion.toISOString() : String(r.fechaActualizacion || '')
    };
  });
  return { ok: true, data: byApp };
}

// [v2.43.30] Setea horario completo de una app + push a operadores afectados
function setHorarioApp(params) {
  var _lock = LockService.getScriptLock();
  try { _lock.waitLock(15000); } catch(e) { return { ok: false, error: 'Sistema ocupado' }; }
  try {
  var app = String(params.app || '').trim();
  if (!app) return { ok: false, error: 'app requerida' };
  if (app !== 'warehouseMos' && app !== 'mosExpress' && app !== 'MOS') {
    return { ok: false, error: 'app no soportada (warehouseMos | mosExpress | MOS)' };
  }
  // [v2.43.132 FIX] Si viene claveAdmin la validamos (admin remoto).
  // Para llamadas internas desde el panel MOS el usuario ya está autenticado.
  if (params.claveAdmin) {
    var authH = verificarClaveAdmin({ clave: params.claveAdmin, accion: 'CAMBIAR_HORARIO_APP', appOrigen: app });
    if (!authH.ok) return authH;
    if (!authH.data || !authH.data.autorizado) {
      return { ok: true, data: { autorizado: false, error: (authH.data && authH.data.error) || 'Clave incorrecta' } };
    }
  }
  // [v2.43.130 FIX] Acepta dos shapes: { horario: {lun,...} } (legacy MOS) y
  // { dias: {lun,...} } (SeguridadSystem). Prefiere dias si viene.
  var horario = params.dias || params.horario || {};
  // [v2.43.132 FIX] Validar formato HH:MM antes de guardar
  var _validarHHMM = function(s) {
    var m = String(s || '').match(/^(\d{1,2}):(\d{2})$/);
    if (!m) return false;
    var hh = parseInt(m[1], 10), mm = parseInt(m[2], 10);
    return hh >= 0 && hh < 24 && mm >= 0 && mm < 60;
  };
  // Validar 7 días
  var horValidado = {};
  var hayInvalido = null;
  _HOR_DIAS.forEach(function(d) {
    var c = horario[d] || {};
    var activo = c.activo !== false;
    var ap = String(c.apertura || '07:00');
    var ci = String(c.cierre || '19:00');
    // [v2.43.133 FIX] Validar HH:MM solo si el día está activo (días cerrados pueden tener apertura/cierre arbitrarios)
    if (activo && (!_validarHHMM(ap) || !_validarHHMM(ci))) {
      hayInvalido = d + ' (' + ap + ' / ' + ci + ')';
    }
    horValidado[d] = { activo: activo, apertura: ap, cierre: ci };
  });
  if (hayInvalido) return { ok: false, error: 'Hora inválida en día: ' + hayInvalido };

  var admins_libres = params.admins_libres !== false;
  var actualizadoPor = String(params.actualizadoPor || 'admin-mos');
  var ts = new Date();

  // [DELETE-SAFE · directo-puro] Si MOS_HORARIO_DIRECTO=1 → upsert por PK `app` en mos.config_horarios_apps
  // vía RPC (la RPC re-valida 7 días + HH:MM y hace UPSERT atómico) y NO toca la HOJA. null ⇒ flag OFF /
  // RPC falló → escritura a HOJA + dual-write de siempre. Los SIDE-EFFECTS (push MOS + invalidar cache WH)
  // se ejecutan IGUAL más abajo en AMBOS caminos: la RPC NO los reproduce a propósito (orquestación = GAS).
  var _horarioDirecto = false;
  if (typeof _sbEscribirDirectoMOS === 'function') {
    var _hd = _sbEscribirDirectoMOS('actualizar_horario_app', {
      app: app, horario: horValidado, admins_libres: admins_libres, actualizadoPor: actualizadoPor
    }, 'MOS_HORARIO_DIRECTO');
    if (_hd) _horarioDirecto = true;
  }
  if (!_horarioDirecto) {
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
    if (filaFound > 0) {
      sh.getRange(filaFound, iHor + 1).setValue(JSON.stringify(horValidado));
      sh.getRange(filaFound, iAdm + 1).setValue(admins_libres);
      sh.getRange(filaFound, iAct + 1).setValue(actualizadoPor);
      sh.getRange(filaFound, iFec + 1).setValue(ts);
    } else {
      sh.appendRow([app, JSON.stringify(horValidado), admins_libres, actualizadoPor, ts]);
    }

    // [dual-write] Espejo inmediato a mos.config_horarios_apps (best-effort; Sheets = verdad).
    // app = PK natural (onConflict). horario_json es json → _mosJson acepta el objeto directo
    // (idéntico a parsear el string que escribe el batch). admins_libres es text → "true"/"false".
    try {
      if (typeof _dualWriteMOS === 'function') {
        _dualWriteMOS('config_horarios_apps', {
          app: app, horarioJson: horValidado, admins_libres: admins_libres,
          actualizadoPor: actualizadoPor, fechaActualizacion: ts
        });
      }
    } catch (eDW) { Logger.log('[dualWrite setHorarioApp] ' + (eDW && eDW.message)); }
  }

  // [v2.43.32] Push refinado: solo a MASTER+ADMIN (no a TODOS los operadores)
  try {
    var resumen = _resumenHorarioParaPush(horValidado);
    var appName = app === 'warehouseMos' ? 'Almacén'
                : app === 'mosExpress'   ? 'POS'
                : 'Panel MOS';
    var titulo  = '🕐 Horario ' + appName + ' actualizado';
    var cuerpo  = resumen;
    if (typeof _enviarPushTodos === 'function') {
      _enviarPushTodos(titulo, cuerpo, { idNotif: 'MOS_HORARIO_APP', soloRolesMOS: true });
    }
  } catch(eP) { Logger.log('[setHorarioApp] push fallo: ' + eP.message); }

  // [SF2] Invalidar cache de horario en WH para aplicar el cambio inmediato.
  // Sin esto el WH usaría el horario viejo durante 5 min (cache).
  try {
    if (app === 'warehouseMos') {
      _invalidarCacheHorarioApp('warehouseMos');
    }
  } catch(eC) { Logger.log('[setHorarioApp] invalidar cache fallo: ' + eC.message); }

  return { ok: true, data: { app: app, horario: horValidado, admins_libres: admins_libres } };
  } catch(e) { return { ok: false, error: e.message }; }
  finally { try { _lock.releaseLock(); } catch(_){} }
}

// [SF2] Llamar al endpoint invalidarCacheHorario de WH (sin idPersonal = global)
function _invalidarCacheHorarioApp(app) {
  if (app !== 'warehouseMos') return;
  try {
    var url = PropertiesService.getScriptProperties().getProperty('WH_GAS_URL') || '';
    if (!url) { Logger.log('[_invalidarCacheHorarioApp] WH_GAS_URL no configurada'); return; }
    var payload = JSON.stringify({ action: 'invalidarCacheHorario' });
    UrlFetchApp.fetch(url, {
      method: 'post', contentType: 'text/plain',
      payload: payload, muteHttpExceptions: true
    });
  } catch(e) { Logger.log('[_invalidarCacheHorarioApp] ' + e.message); }
}

// [SF2] Llamar a invalidarCacheHorario de WH específico para un usuario
function _invalidarCacheHorarioUsuario(idPersonal) {
  if (!idPersonal) return;
  try {
    var url = PropertiesService.getScriptProperties().getProperty('WH_GAS_URL') || '';
    if (!url) return;
    var payload = JSON.stringify({ action: 'invalidarCacheHorario', idPersonal: String(idPersonal) });
    UrlFetchApp.fetch(url, {
      method: 'post', contentType: 'text/plain',
      payload: payload, muteHttpExceptions: true
    });
  } catch(e) { Logger.log('[_invalidarCacheHorarioUsuario] ' + e.message); }
}

// [v2.43.32] Resumen agrupado: días consecutivos con mismo horario se juntan.
// Ej: "Lun a Vie 7→19 · Sab 7→14 · Dom cerrado"
function _resumenHorarioParaPush(hor) {
  var LBL = { lun:'Lun', mar:'Mar', mie:'Mie', jue:'Jue', vie:'Vie', sab:'Sab', dom:'Dom' };
  var grupos = [];
  var actual = null;
  _HOR_DIAS.forEach(function(d) {
    var c = hor[d] || {};
    var key = (c.activo === false) ? 'cerrado' : (String(c.apertura) + '-' + String(c.cierre));
    if (actual && actual.key === key) {
      actual.dias.push(d);
    } else {
      actual = { key: key, dias: [d], apertura: c.apertura, cierre: c.cierre, cerrado: c.activo === false };
      grupos.push(actual);
    }
  });
  return grupos.map(function(g) {
    var rango = g.dias.length === 1
      ? LBL[g.dias[0]]
      : (LBL[g.dias[0]] + ' a ' + LBL[g.dias[g.dias.length-1]]);
    if (g.cerrado) return rango + ' cerrado';
    return rango + ' ' + g.apertura + '→' + g.cierre;
  }).join(' · ');
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
      // [v2.43.32] Push solo al usuario afectado + admin/master
      try {
        var nombre = String(data[i][hdrs.indexOf('nombre')] || '');
        _enviarPushSegmentado(
          idPersonal,
          '🕐 Tu horario personalizado fue eliminado',
          'Hola ' + nombre + ' · vuelves al horario general de la app'
        );
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
    // [v2.43.32] Push al usuario afectado + admin/master
    try {
      var nombre2 = String(data[i][hdrs.indexOf('nombre')] || '');
      _enviarPushSegmentado(
        idPersonal,
        '🕐 Tu nuevo horario personalizado',
        'Hola ' + nombre2 + ' · ' + _resumenHorarioParaPush(hcValido)
      );
    } catch(_){}
    // [SF2] Invalidar cache específico de este usuario en WH
    try { _invalidarCacheHorarioUsuario(idPersonal); } catch(_){}
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

  // [v2.43.31] Política refinada: horarioCustom GANA SOBRE admins_libres
  // Si un admin tiene horario custom específico, ese se respeta. Sino,
  // el flag admins_libres de la app le da paso libre.
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
  // Si NO hay custom y rol es admin con admins_libres → permitido siempre
  if (!horarioOperador && (rol === 'MASTER' || rol === 'ADMINISTRADOR') && appConf.admins_libres) {
    return { ok: true, data: { permitido: true, motivo: 'rol_admin_libre', fuente: 'app' } };
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
  // [v2.43.132 FIX] Soportar horarios que cruzan medianoche (turno noche envasador 14:00-02:00)
  var permitido;
  if (cierre > apert) {
    permitido = horaDecimal >= apert && horaDecimal < cierre;       // 07:00-19:00
  } else if (cierre < apert) {
    permitido = horaDecimal >= apert || horaDecimal < cierre;       // 14:00-02:00 (cruza 00:00)
  } else {
    permitido = false;                                              // apert === cierre
  }
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

// [v2.43.129] Alias front-friendly: verificarHorario(idPersonal, rol, app)
// Compat con SeguridadSystem (ME llama esto desde el GAS MOS via fetch).
// Si no se pasa app, infiere mosExpress (el caso típico de ME).
function verificarHorario(params) {
  var app = String((params && params.app) || 'mosExpress').trim();
  var r = resolverHorarioPersonal({
    idPersonal: String((params && params.idPersonal) || '').trim(),
    rol:        String((params && params.rol) || '').trim(),
    app:        app
  });
  // SeguridadSystem espera { permitido, apertura, cierre, fuente, motivo } directo
  return r;  // ya viene como { ok, data: {...} }; el wrap se hace al lado JS
}

// [v2.43.129] Devuelve lista de PERSONAL_MASTER con horarioCustom no vacío
function getPersonalConHorarioCustom() {
  try {
    var sh = getSheet('PERSONAL_MASTER');
    if (!sh) return { ok: true, data: [] };
    var rows = sh.getDataRange().getValues();
    var hdr = rows[0];
    var iId = hdr.indexOf('idPersonal');
    var iNom = hdr.indexOf('nombre');
    var iRol = hdr.indexOf('rol');
    var iHC = hdr.indexOf('horarioCustom');
    if (iHC < 0) return { ok: true, data: [] };
    var out = [];
    for (var i = 1; i < rows.length; i++) {
      var hc = rows[i][iHC];
      if (hc) {
        out.push({
          idPersonal: String(rows[i][iId] || ''),
          nombre: String(rows[i][iNom] || ''),
          rol: String(rows[i][iRol] || ''),
          horarioCustom: String(hc)
        });
      }
    }
    return { ok: true, data: out };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

function _parseHora(s) {
  s = String(s || '').trim();
  var m = s.match(/^(\d{1,2}):?(\d{2})?$/);
  if (!m) return null;
  return parseInt(m[1], 10) + (parseInt(m[2] || '0', 10) / 60);
}

// [v2.43.32] Push dirigido: SOLO al usuario afectado + MASTER+ADMIN
// (no spammear a todos los operadores). Usa tokens FCM si existen.
function _enviarPushSegmentado(idPersonalDestino, titulo, cuerpo) {
  try {
    var disps = _dispositivosDesdeSombra({});   // [CERO-GAS] verdad = mos.dispositivos
    // Cargar PERSONAL_MASTER para resolver nombre del destinatario + admins
    var per = _sheetToObjects(getSheet('PERSONAL_MASTER'));
    var nombreDest = '';
    per.forEach(function(p) {
      if (String(p.idPersonal) === String(idPersonalDestino)) {
        nombreDest = (String(p.nombre || '') + ' ' + String(p.apellido || '')).trim().toLowerCase();
      }
    });
    var adminsLow = {};
    per.forEach(function(p) {
      var rol = String(p.rol || '').toUpperCase();
      if (rol === 'MASTER' || rol === 'ADMINISTRADOR' || rol === 'ADMIN' || String(p.appOrigen || '') === 'MOS') {
        adminsLow[(String(p.nombre || '') + ' ' + String(p.apellido || '')).trim().toLowerCase()] = true;
        adminsLow[String(p.nombre || '').toLowerCase().trim()] = true;
      }
    });
    var tokens = [];
    disps.forEach(function(d) {
      var tok = String(d.FCM_Token || '').trim();
      var est = String(d.Estado || '').toUpperCase();
      if (!tok || est === 'INACTIVO') return;
      var ses = String(d.Ultima_Sesion || '').toLowerCase().trim();
      // Match: el usuario afectado O un admin/master
      if (ses === nombreDest || adminsLow[ses]) tokens.push(tok);
    });
    if (!tokens.length) return;
    // Reusar el sender de Push.gs si existe
    if (typeof _fcmEnviar === 'function') {
      _fcmEnviar(tokens, titulo, cuerpo, { idNotif: 'MOS_HORARIO_DIRIGIDO' });
    } else if (typeof _enviarFCMv1 === 'function') {
      tokens.forEach(function(t) { try { _enviarFCMv1(t, titulo, cuerpo, {}); } catch(_){} });
    }
  } catch(e) { Logger.log('[_enviarPushSegmentado] ' + e.message); }
}
