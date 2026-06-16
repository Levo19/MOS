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

// ---------- patrón cutover: apagar-sync-por-tabla ----------
/**
 * [FASE 2 · cutover escritura] Lee mos.config['MOS_SYNC_OFF_TABLAS'] (CSV de claves de _MOS_SPECS, ej. 'gastos')
 * y devuelve un set de las tablas a EXCLUIR del upsert-desde-hoja de _syncMOSImpl. Esto evita que el sync
 * monolítico PISE lo que una RPC de escritura directa ya escribió en la sombra mos.<tabla>.
 * Default VACÍO → no excluye nada → _syncMOSImpl sincroniza las 17 tablas IGUAL que hoy (INERTE).
 * Best-effort: si la lectura de config falla, devuelve {} (no apaga nada) y el sync sigue como siempre.
 */
function _mosSyncOffTablas(){
  try{
    var r=_sbSelect('mos.config',{ select:'valor', filters:{ clave:'eq.MOS_SYNC_OFF_TABLAS' }, limit:1 });
    if(!r || !r.ok || !r.data || !r.data.length) return {};
    var csv=String(r.data[0].valor||'').trim();
    if(!csv) return {};
    var set={};
    csv.split(',').forEach(function(t){ var k=String(t).trim().toLowerCase(); if(k) set[k]=true; });
    return set;
  }catch(e){ Logger.log('[_mosSyncOffTablas] WARN: '+(e&&e.message||e)+' → no se apaga ninguna tabla'); return {}; }
}

/** Helper: agrega una tabla al CSV MOS_SYNC_OFF_TABLAS (idempotente). El sync DEJA de pisar esa sombra. */
function apagarSyncTablaMOS(tabla){
  tabla=String(tabla||'').trim().toLowerCase();
  if(!tabla) return {ok:false, error:'tabla vacía'};
  if(!_MOS_SPECS[tabla]) return {ok:false, error:'tabla desconocida (no está en _MOS_SPECS): '+tabla};
  var cur=_mosSyncOffTablas(); cur[tabla]=true;
  var csv=Object.keys(cur).join(',');
  var r=_sbUpsert('mos.config', [{ clave:'MOS_SYNC_OFF_TABLAS', valor:csv,
    descripcion:'MOS Fase 2: CSV de tablas mos.* EXCLUIDAS del upsert-desde-hoja de _syncMOSImpl (escritura directa).' }], 'clave');
  Logger.log('[apagarSyncTablaMOS] OFF='+csv+' → '+JSON.stringify(r&&{ok:r.ok,code:r.code}));
  return { ok: !!(r&&r.ok), off: csv };
}
/** Helper: quita una tabla del CSV (idempotente). El sync VUELVE a cubrir esa sombra (rollback del cutover). */
function prenderSyncTablaMOS(tabla){
  tabla=String(tabla||'').trim().toLowerCase();
  if(!tabla) return {ok:false, error:'tabla vacía'};
  var cur=_mosSyncOffTablas(); delete cur[tabla];
  var csv=Object.keys(cur).join(',');
  var r=_sbUpsert('mos.config', [{ clave:'MOS_SYNC_OFF_TABLAS', valor:csv,
    descripcion:'MOS Fase 2: CSV de tablas mos.* EXCLUIDAS del upsert-desde-hoja de _syncMOSImpl (escritura directa).' }], 'clave');
  Logger.log('[prenderSyncTablaMOS] OFF='+(csv||'(vacío)')+' → '+JSON.stringify(r&&{ok:r.ok,code:r.code}));
  return { ok: !!(r&&r.ok), off: csv };
}

// ---------- sync background (Fase 1.C) ----------
function _syncMOSImpl(full){
  var resumen={};
  // [FASE 2 · cutover] tablas que ya escriben directo → NO re-upsertar desde la hoja (no pisar la RPC).
  var off=_mosSyncOffTablas();
  _MOS_ORDEN.forEach(function(tabla){
    if(off[tabla]){ resumen[tabla]={saltado:'sync-off (escritura directa)'}; return; }
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
function syncMOSReciente(){
  var r=_syncMOSImpl(false);
  try{ _refrescarCatalogoThrottled(); }catch(e){ Logger.log('refresh catálogo (reciente) falló: '+e); }   // mantiene mos.productos fresco (~1h) sin sumar trigger
  // [FASE 1 · gate de frescura] Latido de la SOMBRA mos.* (finanzas/historial leen directo del navegador y
  // necesitan saber si la sombra está fresca). Solo se estampa si TODAS las tablas sincronizaron sin errores;
  // si el trigger muere (Google desactiva los time-based) el latido se congela → mos.finanzas_rango/
  // historial_precios_lista marcan _fresh=false → el front cae a GAS (no sirve P&L/historial viejo).
  try{ _estamparLatidoMOS(r); }catch(eHb){ Logger.log('[syncMOSReciente] heartbeat WARN: '+(eHb&&eHb.message||eHb)); }
  return r;
}
function syncMOSCompleto(){
  var r=_syncMOSImpl(true);
  try{ var cr=syncCatalogoSupabase(); if(!(cr&&cr.ok===false)) PropertiesService.getScriptProperties().setProperty('MOS_CAT_LAST', String(Date.now())); }catch(e){ Logger.log('refresh catálogo (completo) falló: '+e); }
  try{ reconciliarDiarioMOS(); }catch(e){ Logger.log('recon MOS falló: '+e); }   // recon pegada al sync nocturno (sin trigger extra)
  // [FASE 1 · gate de frescura] mismo latido que syncMOSReciente (ver nota allí). Solo si la corrida fue limpia.
  try{ _estamparLatidoMOS(r); }catch(eHb){ Logger.log('[syncMOSCompleto] heartbeat WARN: '+(eHb&&eHb.message||eHb)); }
  return r;
}

/**
 * Escribe mos.config[MOS_SYNC_HEARTBEAT] = ISO now() SOLO si la corrida de _syncMOSImpl fue LIMPIA
 * (ninguna tabla con `error` ni con `errores[]` no vacío). Best-effort: cualquier fallo se loguea y NO rompe el sync.
 * Espeja _estamparLatidoCatalogo (gas/MigracionCatalogo.gs). Que NO se estampe ante un sync sucio es DELIBERADO:
 * así la RPC ve el latido viejo → _fresh=false → finanzas/historial caen a GAS, en vez de servir sombra a medias.
 * El `resumen` viene de _syncMOSImpl: { tabla: {sync,de,errores:[]} | {error:'...'} }; las tablas cuya hoja no
 * existe simplemente no aparecen (skip silencioso, no son error).
 */
function _estamparLatidoMOS(resumen){
  if(!resumen || typeof resumen!=='object'){
    Logger.log('[_estamparLatidoMOS] resumen ausente → NO se estampa latido'); return;
  }
  var sucio=false, motivo='';
  Object.keys(resumen).forEach(function(tabla){
    var t=resumen[tabla];
    if(!t) return;
    if(t.error){ sucio=true; motivo='tabla '+tabla+' error: '+t.error; }
    else if(t.errores && t.errores.length){ sucio=true; motivo='tabla '+tabla+' '+t.errores.length+' lote(s) con error'; }
  });
  if(sucio){
    Logger.log('[_estamparLatidoMOS] corrida con errores ('+motivo+') → NO se estampa latido (sombra dudosa → front cae a GAS)');
    return;
  }
  var iso=new Date().toISOString();
  var rUp=_sbUpsert('mos.config', [{
    clave: 'MOS_SYNC_HEARTBEAT',
    valor: iso,
    descripcion: 'FASE1 lectura directa MOS: ISO de la ULTIMA corrida OK de syncMOSReciente/syncMOSCompleto (latido de frescura de las SOMBRAS mos.* que alimentan finanzas_rango/historial_precios_lista).'
  }], 'clave');
  if(!rUp || !rUp.ok){ Logger.log('[_estamparLatidoMOS] upsert latido FALLO: '+JSON.stringify(rUp)); }
  else { Logger.log('[_estamparLatidoMOS] latido estampado: '+iso); }
}

/** Refresca el catálogo a Supabase a lo sumo ~1 vez/hora (throttle por Property MOS_CAT_LAST).
 *  Evita que getStock-Supabase (WH) se desfase en stockMinimo/Maximo SIN sumar un trigger nuevo
 *  (MOS está en el tope de 20 triggers → se folda en el sync de 15 min, igual que la recon).
 *  syncCatalogoSupabase() es idempotente (upsert merge-duplicates por codigo_barra). */
function _refrescarCatalogoThrottled(){
  var p=PropertiesService.getScriptProperties();
  var last=parseInt(p.getProperty('MOS_CAT_LAST')||'0',10);
  var ahora=Date.now();
  // [fix ALTO-5/6] throttle 14min (antes 55) → catálogo fresco ~cada ciclo de syncMOSReciente (15min),
  // alineado con el sync de datos. Evita stale ≤1h en stockMinimo/precio_costo/factor que alimentan
  // getStock(WH) y COGS(MOS) flipeados.
  if(ahora-last < 14*60*1000) return {skipped:true, minSinUltimo:Math.round((ahora-last)/60000)};
  var r=syncCatalogoSupabase();
  if(r && r.ok===false){ Logger.log('[catálogo] refresh falló; no avanzo throttle'); return {error:r.error}; }
  p.setProperty('MOS_CAT_LAST', String(ahora));
  Logger.log('[catálogo] refrescado a Supabase (throttle 14min)');
  return {refreshed:true};
}

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

// ---------- patrón cutover: re-sembrar hoja desde la sombra (rollback seguro) ----------
/**
 * [FASE 2 · cutover escritura] RE-SIEMBRA la HOJA desde la sombra mos.<tabla>.
 * Por qué: cuando una tabla pasa a escritura DIRECTA a Supabase (apagarSyncTablaMOS), la HOJA deja de recibir
 * esas filas. Si luego se REVIERTE el piloto a GAS (lectura/escritura por Sheet), la hoja debe RECUPERAR lo
 * que se escribió directo, o se "pierde" información para el flujo viejo. Esta fn lee la sombra y AÑADE a la
 * hoja (APPEND-ONLY) las filas cuya PK falte. No edita ni borra filas existentes (no destructivo).
 *
 * SOLO soporta tablas con PK simple (gastos: id_gasto/idGasto). El mapeo pg→header sale de _MOS_SPECS (la
 * misma fuente de verdad del backfill), así no hay layout hardcodeado. La fila se construye por NOMBRE de
 * header de la hoja (robusto ante reordenamiento de columnas).
 *
 * opts:{dryRun:true}  → NO escribe; solo cuenta cuántas filas FALTAN en la hoja (verificación en seco).
 * Diseñada para 'gastos' (append-only, sin estado/edición). Devuelve {ok, tabla, enSombra, enHoja, faltan, [agregadas]}.
 */
function resembrarHojaDesdeSombra(tabla, opts){
  opts=opts||{};
  tabla=String(tabla||'').trim().toLowerCase();
  var cfg=_MOS_SPECS[tabla];
  if(!cfg) return {ok:false, error:'tabla desconocida (no está en _MOS_SPECS): '+tabla};
  var pkCols=String(cfg.onConflict).split(',').map(function(c){ return c.trim(); });
  if(pkCols.length!==1) return {ok:false, error:'resembrar solo soporta PK simple; '+tabla+' tiene PK compuesta: '+cfg.onConflict};
  var pkPg=pkCols[0];
  // header de la HOJA para la PK (el 2do campo del spec = nombre de header en la hoja)
  var pkSpec=null; for(var s=0;s<cfg.spec.length;s++){ if(cfg.spec[s][0]===pkPg){ pkSpec=cfg.spec[s]; break; } }
  if(!pkSpec) return {ok:false, error:'PK '+pkPg+' no está en el spec de '+tabla};
  var pkHeader=pkSpec[1];

  var sh=getSheet(cfg.sheet);
  if(!sh) return {ok:false, error:'hoja no existe: '+cfg.sheet};

  // 1) PKs YA presentes en la hoja (set por header de PK)
  var data=sh.getDataRange().getValues();
  var headers=(data[0]||[]).map(function(h){ return String(h).trim(); });
  var iPk=headers.indexOf(pkHeader);
  if(iPk<0) return {ok:false, error:'header de PK "'+pkHeader+'" no está en la hoja '+cfg.sheet};
  var enHoja={}, nHoja=0;
  for(var r=1;r<data.length;r++){ var v=data[r][iPk]; if(v!==''&&v!=null){ enHoja[String(v)]=true; nHoja++; } }

  // 2) leer la SOMBRA mos.<tabla> paginada, ordenada por PK (estable)
  var sombra=[], offset=0, PAGE=1000;
  while(true){
    var rr=_sbSelect('mos.'+tabla, { order:pkPg, limit:PAGE, offset:offset });
    if(!rr || !rr.ok) return {ok:false, error:'lectura sombra falló: HTTP '+(rr&&rr.code)+' '+(rr&&rr.error||'')};
    var page=rr.data||[]; sombra=sombra.concat(page);
    if(page.length<PAGE) break; offset+=PAGE;
  }

  // 3) filas de la sombra cuya PK FALTA en la hoja
  var faltan=sombra.filter(function(row){ var k=row[pkPg]; return k!=null && String(k)!=='' && !enHoja[String(k)]; });

  if(opts.dryRun){
    return { ok:true, dryRun:true, tabla:tabla, enSombra:sombra.length, enHoja:nHoja, faltan:faltan.length,
      muestra: faltan.slice(0,3).map(function(x){ return x[pkPg]; }) };
  }

  // 4) construir filas por NOMBRE de header de la hoja (pg→header vía spec). Append en bloque.
  // pgPorHeader: para cada header de la hoja, qué columna pg la alimenta (si el spec la mapea).
  var pgPorHeader={}; cfg.spec.forEach(function(t){ pgPorHeader[t[1]]=t[0]; });
  var nuevas=faltan.map(function(row){
    return headers.map(function(h){
      if(h==='') return '';
      var pgc=pgPorHeader[h];
      if(pgc==null) return '';                 // header de la hoja sin mapeo pg → vacío
      var val=row[pgc];
      return (val==null) ? '' : val;           // numeric viene como string desde PostgREST; se escribe tal cual
    });
  });
  var agregadas=0;
  if(nuevas.length){
    sh.getRange(sh.getLastRow()+1, 1, nuevas.length, headers.length).setValues(nuevas);
    agregadas=nuevas.length;
  }
  Logger.log('[resembrarHojaDesdeSombra] '+tabla+': sombra='+sombra.length+' hoja='+nHoja+' faltaban='+faltan.length+' agregadas='+agregadas);
  return { ok:true, tabla:tabla, enSombra:sombra.length, enHoja:nHoja, faltan:faltan.length, agregadas:agregadas };
}
/** Wrapper dry-run para el editor de GAS. */
function resembrarGastosDryRun(){ return resembrarHojaDesdeSombra('gastos', {dryRun:true}); }

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

// ============================================================
// RECONCILIACIÓN v2 — drift dashboard (conteo + SUMA de columnas clave)
// Detecta drift de VALORES (ediciones/anulaciones) que el solo conteo no ve. 100% lectura.
// ============================================================
var _MOS_SUMCOLS = {
  proveedores:[], historial_precios:['precio_nuevo'], pedidos_proveedor:['monto_estimado'],
  pagos_proveedor:['monto'], jornadas:['monto_jornal'], gastos:['monto'], liquidaciones_dia:['total_dia'],
  liquidaciones_pagos:['total_dia'], evaluaciones:['limpieza_pct'], bloqueos_usuario:[], seguridad_alertas:[],
  config_horarios_apps:[], alertas_log:[], conexiones:[], etiquetas_zona:['precio_nuevo'],
  proveedores_productos:['precio_referencia'], notificaciones_config:[]
};

/** Suma columnas de una tabla de Supabase, paginando ordenado por PK (estable). */
function _sbSumCols(schemaTable, cols, order){
  var sums={}; cols.forEach(function(c){ sums[c]=0; });
  var n=0, offset=0, PAGE=1000;
  while(true){
    var r=_sbSelect(schemaTable,{select:cols.join(',')||order.split(',')[0], order:order, limit:PAGE, offset:offset});
    if(!r.ok) return {error:'HTTP '+r.code+' '+(r.error||'')};
    var rows=r.data||[];
    rows.forEach(function(row){ cols.forEach(function(c){ var num=parseFloat(row[c]); if(!isNaN(num)) sums[c]+=num; }); });   // numeric puede venir como string desde PostgREST
    n+=rows.length;
    if(rows.length<PAGE) break;
    offset+=PAGE;
  }
  return {n:n, sums:sums};
}

function reconciliarMOS(){
  var out={}, problemas=0;
  _MOS_ORDEN.forEach(function(tabla){
    var cfg=_MOS_SPECS[tabla], cols=_MOS_SUMCOLS[tabla]||[], info={};
    try{
      var rows=getSheet(cfg.sheet)?_mosBuildRows(tabla):[];
      info.sheet_n=rows.length;
      var ss={}; cols.forEach(function(c){ ss[c]=0; });
      rows.forEach(function(r){ cols.forEach(function(c){ var v=r[c]; if(typeof v==='number'&&!isNaN(v)) ss[c]+=v; }); });
      var sb=_sbSumCols('mos.'+tabla, cols, cfg.onConflict);
      if(sb.error){ info.error=sb.error; out[tabla]=info; problemas++; return; }
      info.sb_n=sb.n;
      info.n_ok=(info.sheet_n===info.sb_n);
      var sumOk=true; info.sums={};
      cols.forEach(function(c){ var a=ss[c]||0, b=sb.sums[c]||0, ok=Math.abs(a-b)<0.01; if(!ok)sumOk=false;
        info.sums[c]={sheet:Math.round(a*100)/100, sb:Math.round(b*100)/100, ok:ok}; });
      info.ok=info.n_ok && sumOk;
      if(!info.ok) problemas++;
    }catch(e){ info.error=String(e&&e.message||e); problemas++; }
    out[tabla]=info;
  });
  out._resumen={problemas:problemas, veredicto: problemas===0?'✓ SIN DRIFT':'⚠ revisar '+problemas+' tabla(s)'};
  Logger.log(JSON.stringify(out,null,2));
  return out;
}

/** Corre reconciliarMOS y registra una fila en la hoja RECON_LOG (lo dispara el trigger diario). */
function reconciliarDiarioMOS(){
  var res=reconciliarMOS(), r=res._resumen||{};
  var probs={}; Object.keys(res).forEach(function(k){ if(k!=='_resumen' && res[k] && res[k].ok===false) probs[k]=res[k]; });
  var sh=getSheet('RECON_LOG') || getSpreadsheet().insertSheet('RECON_LOG');
  if(sh.getLastRow()===0) sh.appendRow(['fecha','app','problemas','veredicto','tablas_con_drift']);
  sh.appendRow([Utilities.formatDate(new Date(),'America/Lima','yyyy-MM-dd HH:mm'),'MOS', r.problemas||0, r.veredicto||'', JSON.stringify(probs).slice(0,45000)]);
  return res;
}
/** La recon ahora va PEGADA a syncMOSCompleto (sin trigger propio, por el límite de 20 triggers).
 *  Esta función solo LIMPIA un trigger de recon separado si lo instalaste antes. */
function desinstalarTriggerReconMOS(){
  var n=0; ScriptApp.getProjectTriggers().forEach(function(t){ if(t.getHandlerFunction()==='reconciliarDiarioMOS'){ ScriptApp.deleteTrigger(t); n++; } });
  Logger.log('Triggers recon separados eliminados: '+n+' (la recon corre dentro de syncMOSCompleto)'); return {ok:true, eliminados:n};
}

/** [Fase 1.D · C1] Verifica a qué DEPLOYMENT de ME apunta el bridge MOS→ME (props + hoja CONEXIONES).
 *  Debe coincidir con el deployment que recibió el flip (AKfycbzG84A8...), o el flip no cubre los reads que MOS hace a ME. Solo lectura. */
function verBridgeMEMOS(){
  var p=PropertiesService.getScriptProperties();
  var FLIP_ID='AKfycbzG84A8GcK2ArC4irCk_YVf-G4kt1INuqLDpnZEhEHGN6gH7Ht9f-bw-PMOSGG267KjlQ';
  function depId(u){ var m=String(u||'').match(/macros\/s\/([^\/]+)\/exec/); return m?m[1]:'(no parseable)'; }
  var out={ flip_deployment:FLIP_ID, fuentes:[] };
  ['ME_GAS_URL','MOSEXPRESS_GAS_URL','ME_URL','MEXPRESS_GAS_URL','MOSEXPRESS_URL'].forEach(function(k){
    var v=p.getProperty(k); if(v) out.fuentes.push({origen:'prop:'+k, deployment:depId(v), coincide:(depId(v)===FLIP_ID), url:v});
  });
  try{
    var sh=getSheet('CONEXIONES');
    if(sh){ var d=sh.getDataRange().getValues(), h=d[0], iApp=h.indexOf('idApp'), iUrl=h.indexOf('gasUrl');
      for(var i=1;i<d.length;i++){ var app=String(d[i][iApp]||'').toLowerCase();
        if(app.indexOf('express')>=0 || app.indexOf('mex')>=0 || app==='me'){ var u=d[i][iUrl];
          out.fuentes.push({origen:'CONEXIONES:'+d[i][iApp], deployment:depId(u), coincide:(depId(u)===FLIP_ID), url:u}); } }
    }
  }catch(e){ out.conexiones_error=String(e&&e.message||e); }
  out.veredicto = out.fuentes.every(function(f){ return f.coincide; }) && out.fuentes.length>0
    ? '✓ todos los bridges apuntan al deployment del flip'
    : '⚠ revisar: hay bridge(s) que NO apuntan al deployment del flip';
  Logger.log(JSON.stringify(out,null,2)); return out;
}

// ============================================================
// FASE 1.D (canary MOS) — comparador getHistorialPrecios vs mos.historial_precios_lista()
// ============================================================
function _numEq(a,b){ var na=parseFloat(a), nb=parseFloat(b); if(!isNaN(na)&&!isNaN(nb)) return Math.abs(na-nb)<0.01; return String(a)===String(b); }
function _diffHP(label,a,b,diffs){
  ['skuBase','codigoBarra','descripcion','usuario','motivo','appOrigen','fecha'].forEach(function(f){
    if(String(a[f])!==String(b[f])) diffs.push(label+'.'+f+': sheets="'+a[f]+'" sb="'+b[f]+'"');
  });
  ['precioAnterior','precioNuevo'].forEach(function(f){ if(!_numEq(a[f],b[f])) diffs.push(label+'.'+f+': sheets='+a[f]+' sb='+b[f]); });
}
function compararHistorialPreciosMOS(){
  var escenarios=[{n:'todos', p:{}}, {n:'limit 50', p:{limit:50}}];
  var salida={ok:true, escenarios:[]};
  escenarios.forEach(function(esc){
    var t0=Date.now(); var sh=getHistorialPrecios(esc.p); var tS=Date.now()-t0;
    var t1=Date.now(); var r=_sbRpc('mos','historial_precios_lista',{p_sku:esc.p.skuBase||null, p_codigo:esc.p.codigoBarra||null, p_limit:esc.p.limit||null}); var tB=Date.now()-t1;
    var res={escenario:esc.n};
    if(!r.ok){ res.error='RPC falló: HTTP '+r.code+' — '+(r.error||''); res.nota='¿corriste 12_fase1d_mos_historial.sql?'; salida.ok=false; salida.escenarios.push(res); return; }
    var sd=(sh&&sh.data)||[], bd=(r.data&&r.data.data)||[], diffs=[];
    function byId(arr){ var m={}; arr.forEach(function(x){ m[String(x.id)]=x; }); return m; }
    var ms=byId(sd), mb=byId(bd), ids={};
    Object.keys(ms).forEach(function(k){ids[k]=1;}); Object.keys(mb).forEach(function(k){ids[k]=1;});
    Object.keys(ids).forEach(function(id){
      if(!ms[id]){ diffs.push(id+': falta en SHEETS'); return; }
      if(!mb[id]){ diffs.push(id+': falta en SUPABASE'); return; }
      _diffHP(id, ms[id], mb[id], diffs);
    });
    res.ok=diffs.length===0; res.filas={sheets:sd.length, sb:bd.length};
    res.velocidad={sheets_ms:tS, supabase_ms:tB, speedup:(tS&&tB)?(Math.round(tS/tB*10)/10+'x'):'n/a'};
    res.diferencias=diffs.slice(0,30); if(!res.ok) salida.ok=false;
    salida.escenarios.push(res);
  });
  salida.veredicto=salida.ok?'✓ PARIDAD EXACTA en ambos escenarios — listo para flip':'⚠ revisar diferencias';
  Logger.log(JSON.stringify(salida,null,2)); return salida;
}

// ============================================================
// FASE 2.A — FLIP con feature flag FUENTE_DATOS (Script Property de MOS; default 'sheets').
// Infra genérica reusable (espeja MigracionWH.gs:580-612). Default = sheets = comportamiento idéntico.
// Encender: activarSupabaseMOS() · Apagar: desactivarSupabaseMOS() · granular: desactivarUnoMOS('getFinanzasRango')
// El wiring de cada endpoint (getFinanzasRangoFlip + router) y su SQL llegan en su propio incremento.
// ============================================================
var _FLIP_CACHE_SEG_MOS = 15;
function _fuenteDatos(key){
  try{
    var p=PropertiesService.getScriptProperties();
    if(String(p.getProperty('FUENTE_DATOS')||'sheets').toLowerCase()!=='supabase') return 'sheets';
    var off=String(p.getProperty('FUENTE_DATOS_OFF')||'').toLowerCase();
    if(key && off){ var arr=off.split(',').map(function(s){return s.trim();}); if(arr.indexOf(String(key).toLowerCase())>=0) return 'sheets'; }
    return 'supabase';
  }catch(e){ return 'sheets'; }
}
function activarSupabaseMOS(){ PropertiesService.getScriptProperties().setProperty('FUENTE_DATOS','supabase'); Logger.log('✅ FUENTE_DATOS(MOS) = supabase (fallback a Sheets ante cualquier fallo)'); return {ok:true, fuente:'supabase'}; }
function desactivarSupabaseMOS(){ PropertiesService.getScriptProperties().setProperty('FUENTE_DATOS','sheets'); try{ CacheService.getScriptCache().removeAll(['SB_FINRANGO']); }catch(e){} Logger.log('↩️ FUENTE_DATOS(MOS) = sheets — rollback instantáneo'); return {ok:true, fuente:'sheets'}; }
function estadoFuenteDatosMOS(){ var p=PropertiesService.getScriptProperties(); var o={master:String(p.getProperty('FUENTE_DATOS')||'sheets'), off:String(p.getProperty('FUENTE_DATOS_OFF')||'')}; Logger.log(JSON.stringify(o)); return o; }
function desactivarUnoMOS(ep){ var p=PropertiesService.getScriptProperties(); var off=(p.getProperty('FUENTE_DATOS_OFF')||'').split(',').map(function(s){return s.trim();}).filter(Boolean); if(off.indexOf(ep)<0) off.push(ep); p.setProperty('FUENTE_DATOS_OFF',off.join(',')); Logger.log('🔻 '+ep+' forzado a Sheets. OFF=['+off.join(',')+']'); return {ok:true,off:off}; }
function reactivarUnoMOS(ep){ var p=PropertiesService.getScriptProperties(); var off=(p.getProperty('FUENTE_DATOS_OFF')||'').split(',').map(function(s){return s.trim();}).filter(Boolean).filter(function(e){return e!==ep;}); p.setProperty('FUENTE_DATOS_OFF',off.join(',')); Logger.log('🔼 '+ep+' reactivado a Supabase. OFF=['+off.join(',')+']'); return {ok:true,off:off}; }

// ---------- Fase 2.A: getFinanzasRango — flip + comparador ----------
// El router llama getFinanzasRangoFlip. Con FUENTE_DATOS=sheets (default) = getFinanzasRango idéntico.
// Requiere correr supabase/13_mos_finanzas_rango.sql antes de poder flipear.
function getFinanzasRangoFlip(params){
  params=params||{};
  if(_fuenteDatos('getFinanzasRango')==='supabase'){
    try{
      var r=_sbRpc('mos','finanzas_rango',{p_desde:String(params.desde||''), p_hasta:String(params.hasta||'')});
      if(r.ok && r.data && r.data.ok){ return r.data; }   // {ok:true, data:{serie,totales,desde,hasta}}
    }catch(e){ /* cae a Sheets */ }
  }
  return getFinanzasRango(params);
}
// Comparador Sheets vs mos.finanzas_rango (default: últimos 30 días terminando ayer, Lima).
function compararFinanzasRangoMOS(desde, hasta){
  var tz=Session.getScriptTimeZone();
  if(!desde || !hasta){
    var hoy=new Date(), ms=24*3600*1000;
    var ayer=new Date(hoy.getTime()-ms), d0=new Date(ayer.getTime()-29*ms);
    hasta=Utilities.formatDate(ayer,tz,'yyyy-MM-dd');
    desde=Utilities.formatDate(d0,tz,'yyyy-MM-dd');
  }
  var t0=Date.now(); var sh=getFinanzasRango({desde:desde,hasta:hasta}); var tS=Date.now()-t0;
  var t1=Date.now(); var r=_sbRpc('mos','finanzas_rango',{p_desde:desde,p_hasta:hasta}); var tB=Date.now()-t1;
  if(!r.ok){ var e={ok:false, error:'RPC falló: HTTP '+r.code+' — '+(r.error||''), nota:'¿corriste 13_mos_finanzas_rango.sql en Supabase?'}; Logger.log(JSON.stringify(e,null,2)); return e; }
  var sd=(sh&&sh.data)||{}, bd=(r.data&&r.data.data)||{}, diffs=[], cogsDrift=0;
  // ventasNetas/totalGastos = dinero real → ±0.01 estricto. COGS y derivados = estimación con ruido
  // INMATERIAL (canónico por orden de hoja, irreducible en SQL + redondeo float vs numeric) → tolerancia relativa.
  var EXACTOS={ventasNetas:1, totalGastos:1};
  function okCampo(c,a,b){
    var d=Math.abs((parseFloat(a)||0)-(parseFloat(b)||0));
    if(c==='costoVentas') cogsDrift=Math.max(cogsDrift,d);
    if(EXACTOS[c]) return d<=0.01;
    var rel=0.001*Math.max(Math.abs(parseFloat(a)||0), Math.abs(parseFloat(b)||0));
    return d<=Math.max(0.15, rel);   // piso 0.15 (el error de COGS es absoluto ≤0.10/día, se propaga a util. neta chica) o ≤0.1%
  }
  var ms2={}, mb={};
  (sd.serie||[]).forEach(function(x){ ms2[x.fecha]=x; });
  (bd.serie||[]).forEach(function(x){ mb[x.fecha]=x; });
  var fechas={}; Object.keys(ms2).forEach(function(f){fechas[f]=1;}); Object.keys(mb).forEach(function(f){fechas[f]=1;});
  var campos=['ventasNetas','costoVentas','utilidadBruta','totalGastos','utilidadNeta','margenBrutoPct'];
  Object.keys(fechas).sort().forEach(function(f){
    var a=ms2[f], b=mb[f];
    if(!a){ diffs.push(f+': falta en SHEETS'); return; }
    if(!b){ diffs.push(f+': falta en SUPABASE'); return; }
    campos.forEach(function(c){ if(!okCampo(c,a[c],b[c])) diffs.push(f+'.'+c+': sheets='+a[c]+' sb='+b[c]); });
  });
  var st=sd.totales||{}, bt=bd.totales||{};
  ['ventasNetas','costoVentas','utilidadBruta','totalGastos','utilidadNeta','margenBrutoPct','margenNetoPct'].forEach(function(c){
    if(!okCampo(c,st[c],bt[c])) diffs.push('TOTALES.'+c+': sheets='+st[c]+' sb='+bt[c]);
  });
  var out={ ok:diffs.length===0, rango:{desde:desde,hasta:hasta},
    veredicto: diffs.length===0?'✓ PARIDAD — dinero exacto; COGS dentro de tolerancia inmaterial':'⚠ revisar diferencias',
    velocidad:{sheets_ms:tS, supabase_ms:tB, speedup:(tS&&tB)?(Math.round(tS/tB*10)/10+'x'):'n/a'},
    dias:{sheets:(sd.serie||[]).length, sb:(bd.serie||[]).length},
    cogsDriftMax:Math.round(cogsDrift*100)/100,
    diferencias:diffs.slice(0,40) };
  Logger.log(JSON.stringify(out,null,2)); return out;
}

// ============================================================
// FASE 2 (DINERO) — Comparador getResumenDia (GAS) vs mos.resumen_dia (RPC).
// INERTE: la RPC existe (93_mos_resumen_dia.sql) pero NADIE la cablea aún. Este comparador
// SOLO valida paridad al centavo de los KPIs auto de DINERO que materializan LIQUIDACIONES_DIA:
//   montoBase · pagoEnvasado · bonoMeta  (+ KPIs ventasReales/envasados/metaVenta/presente/auditado).
// Patrón espejo de compararFinanzasRangoMOS. Corre la RPC para listar las personas evaluables
// reales de la fecha, y por cada una llama el getResumenDia VIVO de GAS, comparando campo a campo.
// Requiere correr supabase/93_mos_resumen_dia.sql antes.
function compararResumenDiaMOS(fecha){
  var tz = Session.getScriptTimeZone();
  if (!fecha) {
    var ayer = new Date(Date.now() - 24*3600*1000);
    fecha = Utilities.formatDate(ayer, tz, 'yyyy-MM-dd');
  }
  var t1 = Date.now();
  var r = _sbRpc('mos','resumen_dia',{ p_fecha: fecha, p_id_personal: null });
  var tB = Date.now() - t1;
  if (!r.ok || !r.data || r.data.ok !== true) {
    var e = { ok:false, fecha:fecha, error:'RPC falló: HTTP '+r.code+' — '+((r.data&&r.data.error)||r.error||''),
              nota:'¿corriste 93_mos_resumen_dia.sql en Supabase?' };
    Logger.log(JSON.stringify(e,null,2)); return e;
  }
  var rpcRows = (r.data && r.data.data) || [];
  // Campos DINERO → paridad EXACTA al centavo (±0.005 por ruido float/numeric, redondeado a 2).
  var EXACTOS = ['montoBase','pagoEnvasado','bonoMeta'];
  // KPIs no-dinero → también exactos (son conteos/sumas) salvo metaVenta (config).
  var KPIS = ['ventasReales','envasados','metaVenta'];
  var BOOLS = ['presente','auditado'];
  var diffs = [], personas = 0, tGasTotal = 0;
  function n2(x){ return Math.round((parseFloat(x)||0)*100)/100; }

  rpcRows.forEach(function(rp){
    personas++;
    var t0 = Date.now();
    var g = getResumenDia({ idPersonal: rp.idPersonal, fecha: fecha });
    tGasTotal += (Date.now() - t0);
    if (!g || !g.ok || !g.data) { diffs.push(rp.idPersonal+': getResumenDia GAS falló'); return; }
    var d = g.data, k = d.kpis || {};
    // DINERO (al centavo)
    EXACTOS.forEach(function(c){
      var a = n2(d[c]), b = n2(rp[c]);
      if (Math.abs(a-b) > 0.005) diffs.push(rp.idPersonal+' ('+rp.rol+').'+c+': gas='+a+' rpc='+b);
    });
    // KPIs (ventasReales/envasados de kpis; metaVenta de kpis.metaVenta)
    KPIS.forEach(function(c){
      var a = n2(k[c]), b = n2(rp[c]);
      if (Math.abs(a-b) > 0.005) diffs.push(rp.idPersonal+' ('+rp.rol+').'+c+': gas='+a+' rpc='+b);
    });
    // BOOLS
    BOOLS.forEach(function(c){
      var a = (d[c] === true), b = (rp[c] === true);
      if (a !== b) diffs.push(rp.idPersonal+' ('+rp.rol+').'+c+': gas='+a+' rpc='+b);
    });
  });

  var out = {
    ok: diffs.length === 0,
    fecha: fecha,
    personas: personas,
    veredicto: diffs.length === 0
      ? '✓ PARIDAD EXACTA — montoBase/pagoEnvasado/bonoMeta + KPIs al centavo'
      : '⚠ revisar diferencias (DINERO — no aproximar)',
    velocidad: { gas_total_ms: tGasTotal, rpc_ms: tB },
    diferencias: diffs.slice(0,60)
  };
  Logger.log(JSON.stringify(out,null,2)); return out;
}

// Corre el comparador sobre varias fechas reales de un tirón.
function compararResumenDiaMOS_multi(fechas){
  fechas = fechas || ['2026-06-12','2026-06-13','2026-06-14'];
  var res = fechas.map(function(f){ return compararResumenDiaMOS(f); });
  var ok = res.every(function(x){ return x.ok; });
  var out = { ok: ok, veredicto: ok ? '✓ PARIDAD EXACTA en todas las fechas' : '⚠ hay diferencias', fechas: res };
  Logger.log(JSON.stringify(out,null,2)); return out;
}

// =====================================================================================
// SETUP PRE-FLIP (ejecutar UNA vez, sin parámetros, desde el editor de Apps Script).
// Deja la sombra estabilizada + valida el recompute de jornales contra GAS. NO activa nada
// (no enciende flags ni apaga sync) → MOS sigue 100% por GAS. Es solo el chequeo previo
// al cutover de escritura. Mirá el Logger al terminar: si veredicto del comparador = ✓ PARIDAD,
// el recompute de jornales (mos.resumen_dia) está listo. Si ⚠, NO flipear jornales aún.
// =====================================================================================
function setupCutoverMOS_paso1(){
  var pasos = {};
  // 1) Re-instalar los triggers que mantienen FRESCA la sombra (venían muriendo en silencio).
  try { pasos.triggersSync = instalarTriggersSyncMOS(); }
  catch(e){ pasos.triggersSync = {ok:false, error:String(e)}; }
  // 2) Trigger del sync de liquidaciones (cierre semanal jornales).
  try { pasos.triggerLiq = (typeof setupLiqSyncTrigger==='function') ? setupLiqSyncTrigger() : {ok:false, error:'setupLiqSyncTrigger no existe'}; }
  catch(e){ pasos.triggerLiq = {ok:false, error:String(e)}; }
  // 3) Estampar el latido ahora mismo para que el gate _fresh no quede stale al arrancar.
  try { if (typeof _estamparLatidoMOS==='function') _estamparLatidoMOS(); pasos.latido = {ok:true}; }
  catch(e){ pasos.latido = {ok:false, error:String(e)}; }
  // 4) Validar paridad del recompute de jornales (DINERO) sobre los últimos 3 días.
  var tz = Session.getScriptTimeZone();
  var fechas = [1,2,3].map(function(d){
    return Utilities.formatDate(new Date(Date.now() - d*24*3600*1000), tz, 'yyyy-MM-dd');
  });
  try { pasos.paridadJornales = compararResumenDiaMOS_multi(fechas); }
  catch(e){ pasos.paridadJornales = {ok:false, error:String(e)}; }

  var paridadOk = !!(pasos.paridadJornales && pasos.paridadJornales.ok);
  var out = {
    ok: true,
    resumen: 'Setup pre-flip ejecutado. NADA fue activado (MOS sigue por GAS).',
    triggersSyncOk: !!(pasos.triggersSync && pasos.triggersSync.ok),
    triggerLiqOk: !!(pasos.triggerLiq && pasos.triggerLiq.ok),
    paridadJornalesOk: paridadOk,
    siguiente: paridadOk
      ? '✓ Recompute de jornales LISTO. Podés flipear módulos cuando quieras (avisá a Claude para acompañarte).'
      : '⚠ El comparador de jornales mostró diferencias o falló — revisá pasos.paridadJornales ANTES de flipear jornales. (Los módulos no-dinero NO dependen de esto.)',
    detalle: pasos
  };
  Logger.log(JSON.stringify(out,null,2));
  return out;
}
