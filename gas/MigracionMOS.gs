/**
 * ============================================================
 * MIGRACIÓN SUPABASE — FASE 1 · Backfill TRANSACCIONAL de MOS (esquema mos)
 * ============================================================
 * Vive en el GAS de MOS (app maestra). El CATÁLOGO (10 tablas) ya se migró en
 * Fase 0 vía MigracionCatalogo.gs. Esto cubre las hojas TRANSACCIONALES propias
 * (finanzas, proveedores, seguridad, editor de avisos) que faltan.
 *
 * Requiere: Supabase.gs (ya está), Script Properties SUPABASE_URL/SERVICE_KEY (ya), SPREADSHEET_ID (ya).
 *
 * PASO 1 (este archivo): inspección read-only para escribir DDL+specs sin adivinar.
 *   dumpHeadersMOS()      // headers + conteo de TODOS los candidatos (decide alcance)
 *   chequearPKsMOS()      // cardinalidad de PK candidatas del núcleo a migrar
 *   inspeccionarMOS(n)    // headers + 2 filas viejas/nuevas de UNA hoja (ver shift de layout)
 */

// ---------- conversores defensivos (patrón WH/ME) ----------
function _mosText(v){ return (v==null||v==='')?null:String(v); }
function _mosNum(v){ if(v==null||v==='')return null; if(typeof v==='number')return isNaN(v)?null:v; var s=String(v).trim(); if(s.charAt(0)==='#')return null; var n=parseFloat(s.replace(',','.')); return isNaN(n)?null:n; }
function _mosInt(v){ var n=_mosNum(v); return n==null?null:Math.round(n); }
function _mosDate(v){ if(v==null||v==='')return null;
  // date-only STRING ('2026-06-08') → new Date lo lee como UTC y al formatear en Lima cae al día anterior.
  // Anclar a medianoche Lima lo deja consistente con los Date de Sheets (00:00 Lima = 05:00 UTC) → PK estable.
  if(!(v instanceof Date) && /^\d{4}-\d{2}-\d{2}$/.test(String(v).trim())) v=String(v).trim()+'T00:00:00-05:00';
  var d=(v instanceof Date)?v:new Date(v); if(isNaN(d.getTime()))return null; return Utilities.formatDate(d,'America/Lima',"yyyy-MM-dd'T'HH:mm:ssXXX"); }
function _mosHora(v){ if(v==null||v==='')return null; if(v instanceof Date)return Utilities.formatDate(v,Session.getScriptTimeZone(),'HH:mm:ss'); return String(v); }
function _mosBool(v){ if(v==null||v==='')return null; if(typeof v==='boolean')return v; var s=String(v).trim().toLowerCase(); if(s==='true'||s==='1'||s==='si'||s==='sí'||s==='verdadero'||s==='x')return true; if(s==='false'||s==='0'||s==='no'||s==='falso')return false; return null; }
function _mosJson(v){ if(v==null||v==='')return null; if(typeof v==='object')return v; try{var p=JSON.parse(String(v)); return (p&&typeof p==='object')?p:null;}catch(e){return null;} }

function _mosVal(raw,t){
  if(t==='text')return _mosText(raw);
  if(t==='num') return _mosNum(raw);
  if(t==='int') return _mosInt(raw);
  if(t==='date')return _mosDate(raw);
  if(t==='hora')return _mosHora(raw);
  if(t==='bool')return _mosBool(raw);
  if(t==='json')return _mosJson(raw);
  return _mosText(raw);
}
function _mosRowMap(obj,spec){ var r={}; for(var i=0;i<spec.length;i++){ r[spec[i][0]]=_mosVal(obj[spec[i][1]],spec[i][2]); } return r; }

/** Lector CRUDO por header (preserva Date/valores → _mosDate formatea timestamp completo; ignora headers vacíos). */
function _mosSheetRows(name){
  var sh=getSheet(name);
  if(!sh) throw new Error('Hoja no encontrada: '+name);
  var data=sh.getDataRange().getValues();
  if(data.length<2) return [];
  var headers=data[0].map(function(h){ return String(h).trim(); }), out=[];
  for(var r=1;r<data.length;r++){
    var row=data[r], obj={}, any=false;
    for(var c=0;c<headers.length;c++){
      var h=headers[c]; if(h==='') continue;
      var v=row[c]; obj[h]=v;
      if(v!==''&&v!==null&&v!==undefined) any=true;
    }
    if(any) out.push(obj);
  }
  return out;
}

// ---------- candidatos de hojas (clasificados por intención de alcance) ----------
// CORE = a migrar en Fase 1; QUEST = decidir por conteo; ESPIA = NO migrar (queda en GAS, plan v3)
var _MOS_INSPECT = {
  CORE: ['PROVEEDORES_MASTER','HISTORIAL_PRECIOS','PEDIDOS_PROVEEDOR','PAGOS_PROVEEDOR',
    'JORNADAS','GASTOS','LIQUIDACIONES','LIQUIDACIONES_DIA','LIQUIDACIONES_PAGOS','EVALUACIONES',
    'BLOQUEOS_USUARIO','SEGURIDAD_ALERTAS','CONFIG_HORARIOS_APPS','ALERTAS_LOG','CONEXIONES',
    'ETIQUETAS_ZONA','ADHESIVOS_PLANTILLAS','ICONOS_BITMAPS_ADH','PROVEEDORES_PRODUCTOS'],
  QUEST: ['DEVICE_STATE','QUOTA_DISPOSITIVOS_LOG','UBICACIONES_HISTORIAL','NOTIFICACIONES_LOG',
    'NOTIFICACIONES_CONFIG','MEMBRETES_ME_PENDIENTES','CIERRE_NOCT_LOG','PURGAS_HISTORICAS'],
  ESPIA: ['AUDIO_SESIONES','AUDIO_CHUNKS','RTC_SIGNALING','PUSH_TOKENS','AUDITORIA_ESPIA','DIAGNOSTICO_ESPIA']
};

/** Headers + conteo de TODOS los candidatos (compacto, no trunca). Decide alcance real. */
function dumpHeadersMOS(){
  var ss=getSpreadsheet(), out={};
  ['CORE','QUEST','ESPIA'].forEach(function(grupo){
    _MOS_INSPECT[grupo].forEach(function(n){
      var sh=ss.getSheetByName(n);
      if(!sh){ out[n]={grupo:grupo, estado:'(NO EXISTE)'}; return; }
      var lc=sh.getLastColumn(), lr=sh.getLastRow();
      out[n]={ grupo:grupo, cols:lc, filas:(lr-1), headers: lc>0 ? sh.getRange(1,1,1,lc).getValues()[0] : [] };
    });
  });
  Logger.log(JSON.stringify(out,null,2));
  return out;
}

// Candidatos de PK por hoja (nombres de columna CORREGIDOS tras dumpHeadersMOS). '|' = compuesta.
var _MOS_PK_CANDIDATOS = {
  HISTORIAL_PRECIOS:['id','skuBase|fecha'],
  LIQUIDACIONES_DIA:['idDia','fecha|idPersonal'],
  LIQUIDACIONES_PAGOS:['idPago','idPago|idPersonal|fecha','idPago|idPersonal'],
  ETIQUETAS_ZONA:['idEtiq'],
  PROVEEDORES_PRODUCTOS:['idPP'],
  NOTIFICACIONES_CONFIG:['idNotif']
};

/** Cardinalidad de claves candidatas → decide PK simple vs compuesta. Solo lectura, compacto. */
function chequearPKsMOS(){
  var ss=getSpreadsheet(), out={};
  Object.keys(_MOS_PK_CANDIDATOS).forEach(function(hoja){
    var sh=ss.getSheetByName(hoja);
    if(!sh){ out[hoja]='(NO EXISTE)'; return; }
    var rows=_sheetToObjects(sh);
    var info={ filas:rows.length, candidatos:{} };
    _MOS_PK_CANDIDATOS[hoja].forEach(function(cand){
      var cols=cand.split('|'), seen={}, dups=0, ej=null, vacios=0;
      rows.forEach(function(r){
        var falta=cols.some(function(c){ return r[c]==null||r[c]===''; });
        if(falta){ vacios++; }
        var k=cols.map(function(c){ return String(r[c]==null?'':r[c]); }).join('||');
        if(seen[k]){ dups++; if(!ej) ej=k; } else seen[k]=true;
      });
      info.candidatos[cand]={ distintos:Object.keys(seen).length, duplicados:dups, conVacio:vacios, unico:(dups===0&&vacios===0), ejDup:ej };
    });
    out[hoja]=info;
  });
  Logger.log(JSON.stringify(out,null,2));
  return out;
}

/** Headers + 2 filas viejas + 2 nuevas de UNA hoja (ver evolución de layout). */
function inspeccionarMOS(nombre){
  var sh=getSpreadsheet().getSheetByName(nombre);
  if(!sh){ var e={error:'NO EXISTE: '+nombre}; Logger.log(JSON.stringify(e)); return e; }
  var lc=sh.getLastColumn(), lr=sh.getLastRow();
  var out={ hoja:nombre, columnas:lc, filas:(lr-1),
    headers: lc>0 ? sh.getRange(1,1,1,lc).getValues()[0] : [],
    primeras: lr>1 ? sh.getRange(2,1,Math.min(2,lr-1),lc).getValues() : [],
    ultimas:  lr>2 ? sh.getRange(lr-1,1,2,lc).getValues() : []
  };
  Logger.log(JSON.stringify(out,null,2));
  return out;
}

// ============================================================
// BACKFILL — specs + motor (patrón WH; sin lineaBy, claves naturales)
// ============================================================
var _MOS_SPECS = {
  proveedores: { sheet:'PROVEEDORES_MASTER', onConflict:'id_proveedor', keyHeader:'idProveedor', spec:[
    ['id_proveedor','idProveedor','text'],['nombre','nombre','text'],['ruc','ruc','text'],['imagen','imagen','text'],
    ['telefono','telefono','text'],['banco','banco','text'],['numero_cuenta','numeroCuenta','text'],['cci','cci','text'],
    ['email','email','text'],['dia_pedido','diaPedido','text'],['dia_pago','diaPago','text'],['dia_entrega','diaEntrega','text'],
    ['forma_pago','formaPago','text'],['plazo_credito','plazoCredito','text'],['responsable','responsable','text'],
    ['categoria_producto','categoriaProducto','text'],['estado','estado','text']
  ]},
  historial_precios: { sheet:'HISTORIAL_PRECIOS', onConflict:'id', keyHeader:'id', spec:[
    ['id','id','text'],['sku_base','skuBase','text'],['codigo_barra','codigoBarra','text'],['descripcion','descripcion','text'],
    ['precio_anterior','precioAnterior','num'],['precio_nuevo','precioNuevo','num'],['usuario','usuario','text'],
    ['motivo','motivo','text'],['app_origen','appOrigen','text'],['fecha','fecha','date']
  ]},
  pedidos_proveedor: { sheet:'PEDIDOS_PROVEEDOR', onConflict:'id_pedido', keyHeader:'idPedido', spec:[
    ['id_pedido','idPedido','text'],['id_proveedor','idProveedor','text'],['items','items','json'],['monto_estimado','montoEstimado','num'],
    ['estado','estado','text'],['fecha_creacion','fechaCreacion','date'],['fecha_estimada','fechaEstimada','date'],
    ['usuario','usuario','text'],['notas','notas','text']
  ]},
  pagos_proveedor: { sheet:'PAGOS_PROVEEDOR', onConflict:'id_pago', keyHeader:'idPago', spec:[
    ['id_pago','idPago','text'],['id_proveedor','idProveedor','text'],['monto','monto','num'],['fecha','fecha','date'],
    ['numero_factura','numeroFactura','text'],['estado','estado','text'],['observacion','observacion','text'],['registrado_por','registradoPor','text']
  ]},
  jornadas: { sheet:'JORNADAS', onConflict:'id_jornada', keyHeader:'idJornada', spec:[
    ['id_jornada','idJornada','text'],['fecha','fecha','date'],['id_personal','idPersonal','text'],['nombre','nombre','text'],
    ['rol','rol','text'],['app_origen','appOrigen','text'],['zona','zona','text'],['monto_jornal','montoJornal','num'],
    ['observacion','observacion','text'],['registrado_por','registradoPor','text'],['fuente','fuente','text']
  ]},
  gastos: { sheet:'GASTOS', onConflict:'id_gasto', keyHeader:'idGasto', spec:[
    ['id_gasto','idGasto','text'],['fecha','fecha','date'],['categoria','categoria','text'],['tipo','tipo','text'],
    ['descripcion','descripcion','text'],['monto','monto','num'],['comprobante','comprobante','text'],['registrado_por','registradoPor','text']
  ]},
  liquidaciones_dia: { sheet:'LIQUIDACIONES_DIA', onConflict:'id_dia', keyHeader:'idDia', spec:[
    ['id_dia','idDia','text'],['fecha','fecha','date'],['id_personal','idPersonal','text'],['nombre','nombre','text'],['rol','rol','text'],
    ['app_origen','appOrigen','text'],['virtual','virtual','text'],['monto_base','montoBase','num'],['pago_envasado','pagoEnvasado','num'],
    ['bono_meta','bonoMeta','num'],['sancion','sancion','num'],['total_dia','totalDia','num'],['auditado','auditado','bool'],
    ['evaluaciones_count','evaluacionesCount','num'],['score_final','scoreFinal','num'],['tarifa_envasado','tarifaEnvasado','num'],
    ['presente','presente','bool'],['estado','estado','text'],['id_pago','idPago','text'],['ts_creado','ts_creado','date'],
    ['ts_actualizado','ts_actualizado','date'],['bonificacion','bonificacion','num'],['bonificacion_motivo','bonificacionMotivo','text'],
    ['sancion_motivo','sancionMotivo','text']
  ]},
  liquidaciones_pagos: { sheet:'LIQUIDACIONES_PAGOS', onConflict:'id_pago,id_personal,fecha', keyHeader:'idPago', spec:[
    ['id_pago','idPago','text'],['id_personal','idPersonal','text'],['fecha','fecha','date'],['nombre','nombre','text'],['rol','rol','text'],
    ['app_origen','appOrigen','text'],['monto_base','montoBase','num'],['pago_envasado','pagoEnvasado','num'],['bono_meta','bonoMeta','num'],
    ['sancion','sancion','num'],['total_dia','totalDia','num'],['ticket_job_id','ticketJobId','text'],['pagado_por','pagadoPor','text'],
    ['pagado_ts','pagadoTs','date'],['estado','estado','text'],['comentario','comentario','text'],['id_gasto_generado','idGastoGenerado','text']
  ]},
  evaluaciones: { sheet:'EVALUACIONES', onConflict:'id_eval', keyHeader:'idEval', spec:[
    ['id_eval','idEval','text'],['fecha','fecha','date'],['id_personal','idPersonal','text'],['rol','rol','text'],['hora','hora','hora'],
    ['limpieza_pct','limpiezaPct','num'],['limpieza_prof_pct','limpiezaProfPct','num'],['control_checks','controlChecks','json'],
    ['comentario','comentario','text'],['evaluado_por','evaluadoPor','text'],['aplica_comision','aplicaComision','bool'],
    ['aplica_bono_meta','aplicaBonoMeta','bool'],['activo','activo','bool'],['sancion','sancion','num'],['sancion_motivo','sancionMotivo','text'],
    ['bonificacion','bonificacion','num'],['bonificacion_motivo','bonificacionMotivo','text']
  ]},
  bloqueos_usuario: { sheet:'BLOQUEOS_USUARIO', onConflict:'id_bloqueo', keyHeader:'idBloqueo', spec:[
    ['id_bloqueo','idBloqueo','text'],['id_personal','idPersonal','text'],['nombre','nombre','text'],['app_origen','appOrigen','text'],
    ['motivo','motivo','text'],['bloqueado_por','bloqueadoPor','text'],['fecha_bloqueo','fechaBloqueo','date'],
    ['unlock_hasta','unlockHasta','date'],['desbloqueado_por','desbloqueadoPor','text']
  ]},
  seguridad_alertas: { sheet:'SEGURIDAD_ALERTAS', onConflict:'id_alerta', keyHeader:'idAlerta', spec:[
    ['id_alerta','idAlerta','text'],['tipo','tipo','text'],['id_dispositivo','idDispositivo','text'],['id_personal','idPersonal','text'],
    ['fecha','fecha','date'],['descripcion','descripcion','text'],['prioridad','prioridad','text'],['estado','estado','text'],
    ['revisada_por','revisada_por','text'],['revisada_en','revisada_en','date'],['datos_extra_json','datos_extra_json','json']
  ]},
  config_horarios_apps: { sheet:'CONFIG_HORARIOS_APPS', onConflict:'app', keyHeader:'app', spec:[
    ['app','app','text'],['horario_json','horarioJson','json'],['admins_libres','admins_libres','text'],
    ['actualizado_por','actualizadoPor','text'],['fecha_actualizacion','fechaActualizacion','date']
  ]},
  alertas_log: { sheet:'ALERTAS_LOG', onConflict:'id', keyHeader:'id', spec:[
    ['id','id','text'],['tipo','tipo','text'],['urgencia','urgencia','text'],['mensaje','mensaje','text'],['app_origen','appOrigen','text'],
    ['datos','datos','text'],['fecha','fecha','date'],['leida','leida','bool']
  ]},
  conexiones: { sheet:'CONEXIONES', onConflict:'id_app', keyHeader:'idApp', spec:[
    ['id_app','idApp','text'],['nombre','nombre','text'],['gas_url','gasUrl','text'],['ss_id','ssId','text'],
    ['activo','activo','bool'],['ultima_sync','ultimaSync','date'],['descripcion','descripcion','text']
  ]},
  etiquetas_zona: { sheet:'ETIQUETAS_ZONA', onConflict:'id_etiq', keyHeader:'idEtiq', spec:[
    ['id_etiq','idEtiq','text'],['id_zona','idZona','text'],['zona_nombre','zonaNombre','text'],['id_producto','idProducto','text'],
    ['descripcion','descripcion','text'],['codigo_barra','codigoBarra','text'],['sku_base','skuBase','text'],
    ['precio_anterior','precioAnterior','num'],['precio_nuevo','precioNuevo','num'],['ts_cambio','ts_cambio','date'],
    ['cambiado_por','cambiadoPor','text'],['estado','estado','text'],['visto_csv','visto_csv','text'],['ts_impresa','ts_impresa','date'],
    ['impresa_por','impresaPor','text'],['job_id','jobId','text'],['ts_pegada','ts_pegada','date'],['pegada_por','pegadaPor','text'],
    ['comentario','comentario','text']
  ]},
  proveedores_productos: { sheet:'PROVEEDORES_PRODUCTOS', onConflict:'id_pp', keyHeader:'idPP', spec:[
    ['id_pp','idPP','text'],['id_proveedor','idProveedor','text'],['sku_base','skuBase','text'],['codigo_barra','codigoBarra','text'],
    ['descripcion','descripcion','text'],['precio_referencia','precioReferencia','num'],['minimo_compra','minimoCompra','num'],
    ['dias_entrega','diasEntrega','num'],['ultima_actualizacion','ultimaActualizacion','date'],['activa','activa','bool'],
    ['notas','notas','text'],['unidades_por_bulto','unidadesPorBulto','num']
  ]},
  notificaciones_config: { sheet:'NOTIFICACIONES_CONFIG', onConflict:'id_notif', keyHeader:'idNotif', spec:[
    ['id_notif','idNotif','text'],['origen','origen','text'],['titulo','titulo','text'],['descripcion','descripcion','text'],
    ['icono','icono','text'],['activa','activa','bool'],['audiencia_roles','audiencia_roles','text'],['audiencia_usuarios','audiencia_usuarios','text'],
    ['excluir_origen','excluir_origen','text'],['prioridad','prioridad','text'],['silenciada_hasta','silenciada_hasta','date'],
    ['sonido_custom','sonido_custom','text'],['ts_actualizado','ts_actualizado','date'],['actualizado_por','actualizado_por','text']
  ]}
};

var _MOS_ORDEN=['proveedores','historial_precios','pedidos_proveedor','pagos_proveedor','jornadas','gastos',
  'liquidaciones_dia','liquidaciones_pagos','evaluaciones','bloqueos_usuario','seguridad_alertas',
  'config_horarios_apps','alertas_log','conexiones','etiquetas_zona','proveedores_productos','notificaciones_config'];

var _MOS_TIME_BUDGET = 4.5*60*1000;
var _MOS_BATCH = 100;

/** Construye filas pg (mapeo + filtro PK + dedupe gana-el-último). */
function _mosBuildRows(tabla){
  var cfg=_MOS_SPECS[tabla];
  var objs=_mosSheetRows(cfg.sheet);
  var rows=objs.map(function(o){ var r=_mosRowMap(o,cfg.spec); if(cfg.post) r=cfg.post(r,o); return r; });
  var pkCols=String(cfg.onConflict).split(',').map(function(c){ return c.trim(); });
  rows=rows.filter(function(r){ return pkCols.every(function(c){ return r[c]!=null && r[c]!==''; }); });
  var seen={}; rows.forEach(function(r){ var k=pkCols.map(function(c){ return String(r[c]); }).join('||'); seen[k]=r; });
  return Object.keys(seen).map(function(k){ return seen[k]; });
}

/** Backfill. opts:{dryRun, soloTabla} */
function migrarMOS(opts){
  opts=opts||{};
  var props=PropertiesService.getScriptProperties();
  var t0=Date.now();
  var tablas=opts.soloTabla?[opts.soloTabla]:_MOS_ORDEN;
  var resumen={};
  for(var ti=0; ti<tablas.length; ti++){
    var tabla=tablas[ti], cfg=_MOS_SPECS[tabla];
    if(!cfg){ resumen[tabla]={error:'spec desconocida'}; continue; }
    try{
      if(!getSheet(cfg.sheet)){ resumen[tabla]={saltado:'hoja no existe: '+cfg.sheet}; continue; }
      if(!opts.dryRun && !opts.soloTabla && props.getProperty('MOSBF_DONE_'+tabla)==='1'){
        resumen[tabla]={saltado:'ya completada (resetCheckpointsMOS para rehacer)'}; continue;
      }
      var rows=_mosBuildRows(tabla);
      if(opts.dryRun){ resumen[tabla]={dryRun:true, filasValidas:rows.length, muestra:rows[0]||null}; continue; }
      var ckKey='MOSBF_'+tabla;
      var start=parseInt(props.getProperty(ckKey)||'0',10);
      var errores=[], upserted=0, corto=false;
      for(var i=start; i<rows.length; i+=_MOS_BATCH){
        if(Date.now()-t0 > _MOS_TIME_BUDGET){
          props.setProperty(ckKey,String(i));
          resumen[tabla]={incompleto:true, desde:i, total:rows.length, nota:'re-corre backfillMOS'};
          Logger.log(JSON.stringify(resumen,null,2)); return resumen;
        }
        var lote=rows.slice(i,i+_MOS_BATCH);
        if(JSON.stringify(lote).length>10000000){ errores.push('lote '+i+': payload muy grande, omitido'); props.setProperty(ckKey,String(i+_MOS_BATCH)); continue; }
        var r=_sbUpsert('mos.'+tabla,lote,cfg.onConflict);
        if(r.ok){ upserted+=lote.length; props.setProperty(ckKey,String(i+_MOS_BATCH)); }
        else { errores.push('lote '+i+': HTTP '+r.code+' '+(r.error||'')); corto=true; break; }
      }
      if(errores.length===0){ props.deleteProperty(ckKey); props.setProperty('MOSBF_DONE_'+tabla,'1'); }
      resumen[tabla]={filas:rows.length, upserted:upserted, errores:errores, ok:errores.length===0, incompleto:corto};
    }catch(e){ resumen[tabla]={error:String(e&&e.message||e)}; }
  }
  Logger.log(JSON.stringify(resumen,null,2));
  return resumen;
}

/** Cuadre sheet (filas reales a migrar) vs supabase. */
function verificarCuadreMOS(){
  var out={};
  _MOS_ORDEN.forEach(function(tabla){
    var cfg=_MOS_SPECS[tabla], nSheet=-1;
    try{
      if(!getSheet(cfg.sheet)){ out[tabla]={sheet:'(no existe)', supabase:_sbCount('mos.'+tabla,null)}; return; }
      nSheet=_mosBuildRows(tabla).length;
    }catch(e){ nSheet=-1; }
    var nPg=_sbCount('mos.'+tabla,null);
    out[tabla]={sheet:nSheet, supabase:nPg, cuadra:(nSheet===nPg)};
  });
  Logger.log(JSON.stringify(out,null,2));
  return out;
}

// ---------- sync background (Fase 1.C) ----------
function _syncMOSImpl(full){
  var resumen={};
  _MOS_ORDEN.forEach(function(tabla){
    var cfg=_MOS_SPECS[tabla];
    try{
      if(!getSheet(cfg.sheet)){ return; }
      var rows=_mosBuildRows(tabla);
      var tail=99999;   // tablas MOS son chicas (max ~325) → re-sync completo siempre
      var slice = (full || rows.length<=tail) ? rows : rows.slice(rows.length-tail);
      var err=[], up=0;
      for(var i=0;i<slice.length;i+=100){
        var lote=slice.slice(i,i+100);
        var r=_sbUpsert('mos.'+tabla,lote,cfg.onConflict);
        if(r.ok) up+=lote.length; else err.push('lote '+i+': HTTP '+r.code+' '+(r.error||''));
      }
      resumen[tabla]={sync:up, de:slice.length, errores:err};
    }catch(e){ resumen[tabla]={error:String(e&&e.message||e)}; }
  });
  Logger.log(JSON.stringify(resumen,null,2));
  return resumen;
}
function syncMOSReciente(){ return _syncMOSImpl(false); }
function syncMOSCompleto(){ return _syncMOSImpl(true); }

/** Instala (idempotente) triggers: 15 min + 4am. Ejecutar 1 vez. */
function instalarTriggersSyncMOS(){
  ScriptApp.getProjectTriggers().forEach(function(t){
    var h=t.getHandlerFunction(); if(h==='syncMOSReciente'||h==='syncMOSCompleto') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('syncMOSReciente').timeBased().everyMinutes(15).create();
  ScriptApp.newTrigger('syncMOSCompleto').timeBased().everyDays(1).atHour(4).create();
  Logger.log('Triggers instalados: syncMOSReciente (15min) + syncMOSCompleto (4am)');
  return {ok:true};
}
function desinstalarTriggersSyncMOS(){
  var n=0; ScriptApp.getProjectTriggers().forEach(function(t){
    var h=t.getHandlerFunction(); if(h==='syncMOSReciente'||h==='syncMOSCompleto'){ ScriptApp.deleteTrigger(t); n++; }
  });
  return {ok:true, eliminados:n};
}

// ---------- wrappers editor ----------
function dryRunMOS(){ return migrarMOS({dryRun:true}); }
function backfillMOS(){ return migrarMOS(); }
function resetCheckpointsMOS(){
  var props=PropertiesService.getScriptProperties();
  var n=0; _MOS_ORDEN.forEach(function(t){
    ['MOSBF_'+t,'MOSBF_DONE_'+t].forEach(function(k){ if(props.getProperty(k)!=null){ props.deleteProperty(k); n++; } });
  });
  Logger.log('Checkpoints/flags borrados: '+n); return {ok:true, borrados:n};
}
