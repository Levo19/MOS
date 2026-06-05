// ============================================================
// ProyectoMOS — Code.gs
// Router principal. Desplegar como Web App: Execute as Me, Anyone
// Este es el cerebro del ecosistema InversionMos.
// ============================================================

var SS_ID = PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID');

function getSpreadsheet() { return SpreadsheetApp.openById(SS_ID); }
function getSheet(name)   { return getSpreadsheet().getSheetByName(name); }

function doGet(e)  { return _respond(_route('GET',  e)); }
function doPost(e) { return _respond(_route('POST', e)); }

function _respond(data) {
  return ContentService.createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}

function _route(method, e) {
  try {
    var params = (method === 'GET')
      ? e.parameter
      : JSON.parse(e.postData ? e.postData.contents : '{}');
    var action = params.action || '';

    return (function() { switch(action) {

      // ── Catálogo maestro (Productos) ───────────────────────
      case 'getProductos':         return getProductosMaster(params);
      case 'getProducto':          return getProductoMaster(params.codigo);
      case 'getProductoPorCodigo': return getProductoPorCodigo(params);
      case 'crearProducto':        return crearProductoMaster(params);
      case 'actualizarProducto':         return actualizarProductoMaster(params);
      case 'actualizarSegmentosPrecio':  return actualizarSegmentosPrecio(params);
      case 'getProductosEditadosRecientes': return getProductosEditadosRecientes(params);
      case 'actualizarProductoMaster':   return actualizarProductoMaster(params);
      case 'getEquivalencias':       return getEquivalencias(params);
      case 'crearEquivalencia':      return crearEquivalencia(params);
      case 'actualizarEquivalencia': return actualizarEquivalencia(params);
      case 'getHistorialPrecios':  return getHistorialPrecios(params);
      case 'publicarPrecio':       return publicarPrecio(params);

      // ── Auditoría de integridad ─────────────────────────────
      case 'getAuditoriaIntegridad':   return getAuditoriaIntegridad(params);
      case 'auditarIntegridad':        return auditarIntegridadProductos();
      case 'resolverAlertaAuditoria':  return resolverAlertaAuditoria(params);

      // ── Política de precios (categorías + sugerencia) ──────
      case 'getCategorias':           return getCategorias(params);
      case 'crearCategoria':          return crearCategoria(params);
      case 'actualizarCategoria':     return actualizarCategoria(params);
      case 'migrarPoliticaPrecios':   return migrarPoliticaPrecios();
      case 'migrarCatalogoCompleto': return migrarCatalogoCompleto();

      // ── Almacén unificado (WH + Zonas ME) ──────────────────
      case 'getDashboardAlmacen':    return getDashboardAlmacen();
      case 'getCatalogoStockResumen': return getCatalogoStockResumen(params);
      case 'getStockUnificado':      return getStockUnificado(params);
      case 'getGuiasYPreingresos':   return getGuiasYPreingresos(params);
      case 'getOperacionesUnificadas': return getOperacionesUnificadas(params);
      case 'getOperacionesConDetalle': return getOperacionesConDetalle(params);
      case 'getOperacionDetalle':    return getOperacionDetalle(params);
      case 'imprimirCostosGuia':     return imprimirCostosGuia(params);
      case 'aplicarRespuestaJefa':   return aplicarRespuestaJefa(params);
      case 'ocrComprobanteGuia':     return ocrComprobanteGuia(params);
      case 'ocrTicketJefa':          return ocrTicketJefa(params);
      case 'getContextoTicketJefa':  return getContextoTicketJefa(params);
      case 'llenarCostosGuia':       return llenarCostosGuia(params);
      case 'aplicarPreciosVentaSugeridos': return aplicarPreciosVentaSugeridos(params);
      case 'getRankingZonas':        return getRankingZonas(params);
      case 'getProductosSinVenta':   return getProductosSinVenta(params);
      case 'getInsightsStock':       return getInsightsStock(params);
      case 'recalcularStockMinMaxAuto': return recalcularStockMinMaxAuto(params);
      case 'getLastAutoMinMaxTs':       return getLastAutoMinMaxTs();
      case 'getAlertasOperativas':   return getAlertasOperativas(params);
      case 'bustAlmacenCache':       return bustAlmacenCache();
      case 'warmupAlmacen':          return warmupAlmacen();
      case 'getAlmacenWarmupStatus': return getAlmacenWarmupStatus();

      // ── Proveedores maestros ───────────────────────────────
      case 'getProveedores':              return getProveedoresMaster(params);
      case 'crearProveedor':              return crearProveedorMaster(params);
      case 'actualizarProveedor':         return actualizarProveedorMaster(params);
      case 'getPagos':                    return getPagosProveedor(params);
      case 'registrarPago':               return registrarPago(params);
      case 'getPedidos':                  return getPedidosProveedor(params);
      case 'crearPedido':                 return crearPedidoProveedor(params);
      case 'getProveedoresQueVenden':     return getProveedoresQueVenden(params);
      case 'getHistoricoProveedor':       return getHistoricoProveedor(params);
      case 'getProveedorProductos':       return getProveedorProductos(params);
      case 'agregarProductoProveedor':    return agregarProductoProveedor(params);
      case 'actualizarProductoProveedor': return actualizarProductoProveedor(params);
      case 'eliminarProductoProveedor':   return eliminarProductoProveedor(params);
      case 'upsertProductoProveedor':     return upsertProductoProveedor(params);
      case 'jalarProductosProveedor':     return jalarProductosProveedor(params);
      case 'getProductosProveedorConStock': return getProductosProveedorConStock(params);

      // ── Promociones (centralizadas en hoja MosExpress) ─────
      case 'getPromociones':              return getPromociones(params);
      case 'crearPromocion':              return crearPromocion(params);
      case 'actualizarPromocion':         return actualizarPromocion(params);
      case 'eliminarPromocion':           return eliminarPromocion(params);

      // ── Conexiones cross-app ───────────────────────────────
      case 'getStockWarehouse':    return getStockWarehouse(params);
      case 'getAlertasWarehouse':  return getAlertasWarehouse();
      case 'getMermasWarehouse':   return getMermasWarehouse(params);
      case 'getEnvasadosWarehouse':return getEnvasadosWarehouse(params);
      case 'getGuiasWarehouse':    return getGuiasWarehouse(params);
      case 'getProductosNuevosWH': return getProductosNuevosWarehouse(params);
      case 'lanzarProductoNuevo':  return lanzarProductoNuevo(params);
      case 'wh_editarPNCantidad':  return postToWarehouse('editarPNCantidad', params);
      // ── Devoluciones zona (two-party witness · puente ME ↔ WH desde MOS) ──
      case 'reportarQuotaDispositivo':       return reportarQuotaDispositivo(params);
      case 'wh_crearDevolucionZona':         return postToWarehouse('crearDevolucionZona', params);
      // [v2.43.29] Salud de stock WH (auditoría + reconciliación desde MOS)
      case 'wh_auditarStockGlobal':          return postToWarehouse('auditarStockGlobal', params);
      case 'wh_getAlertasStock':             return postToWarehouse('getAlertasStock', params);
      case 'wh_reconciliarStockMasivo':      return postToWarehouse('reconciliarStockMasivo', params);
      case 'wh_reconciliarStockProducto':    return postToWarehouse('reconciliarStockProducto', params);
      case 'wh_aceptarTeoricoAlerta':        return postToWarehouse('aceptarTeoricoAlerta', params);
      case 'cronSaludStockWH':               return cronSaludStockWH();
      case 'setupSaludStockTrigger':         return setupSaludStockTrigger();
      case 'verificarTriggerSalud':          return verificarTriggerSalud();
      // [v2.43.30] Horarios apps + custom por usuario
      case 'getHorariosApps':               return getHorariosApps();
      case 'setHorarioApp':                 return setHorarioApp(params);
      case 'setHorarioCustomPersonal':      return setHorarioCustomPersonal(params);
      case 'resolverHorarioPersonal':       return resolverHorarioPersonal(params);
      // [v2.43.129] Aliases front + listado para SeguridadSystem
      case 'verificarHorario':              return verificarHorario(params);
      case 'getPersonalConHorarioCustom':   return getPersonalConHorarioCustom();
      // [v2.43.37] Rotación semanal WH para Catálogo (pre-carga al login)
      case 'wh_getRotacionSemanal':          return postToWarehouse('getRotacionSemanal', params);
      // [v2.43.38] Foto del producto (canónico + presentaciones + equivalentes
      // del mismo skuBase comparten la misma foto). Carpeta "MOS Catálogo Fotos".
      case 'subirFotoProducto':              return subirFotoProducto(params);
      case 'jalarFotoDePNCatalogo':          return jalarFotoDePNCatalogo(params);
      // [v2.43.51] Purga de catálogo (solo MASTER, tier 3)
      case 'getCandidatosEliminacion':       return getCandidatosEliminacion(params);
      case 'eliminarItemsCatalogo':          return eliminarItemsCatalogo(params);
      // [v2.43.57] Modo espía WebRTC — signaling p2p admin ↔ dispositivo
      case 'espiaCrearSesion':               return espiaCrearSesion(params);
      case 'espiaSubirOferta':               return espiaSubirOferta(params);
      case 'espiaLeerOferta':                return espiaLeerOferta(params);
      case 'espiaSubirRespuesta':            return espiaSubirRespuesta(params);
      case 'espiaLeerRespuesta':             return espiaLeerRespuesta(params);
      case 'espiaSubirRenegOferta':          return espiaSubirRenegOferta(params);
      case 'espiaLeerRenegOferta':           return espiaLeerRenegOferta(params);
      case 'espiaSubirRenegRespuesta':       return espiaSubirRenegRespuesta(params);
      case 'espiaLeerRenegRespuesta':        return espiaLeerRenegRespuesta(params);
      case 'espiaAgregarIce':                return espiaAgregarIce(params);
      case 'espiaLeerIce':                   return espiaLeerIce(params);
      case 'espiaEstadoSesion':              return espiaEstadoSesion(params);
      case 'espiaReportarStreams':           return espiaReportarStreams(params);
      case 'espiaCerrarSesion':              return espiaCerrarSesion(params);
      // [v2.43.89] Batch endpoints — 1 round-trip por poll en vez de 3
      case 'espiaSync':                      return espiaSync(params);
      case 'espiaPushBatch':                 return espiaPushBatch(params);
      // [v2.43.90] Production hardening — config (TURN) + device init (token HMAC)
      case 'espiaConfig':                    return espiaConfig();
      case 'espiaIniciarDispositivo':        return espiaIniciarDispositivo(params);
      case 'espiaSubirChunk':                return espiaSubirChunk(params);
      // [v2.43.61] Timeline + cleanup
      case 'espiaListarChunks':              return espiaListarChunks(params);
      case 'cronLimpiarBufferEspia':         return cronLimpiarBufferEspia();
      case 'setupEspiaCleanupTrigger':       return setupEspiaCleanupTrigger();
      case 'wh_getDevolucionesZona':         return postToWarehouse('getDevolucionesZona', params);
      case 'wh_getDevolucionDetalle':        return postToWarehouse('getDevolucionDetalle', params);
      case 'wh_confirmarRecepcionDevolucion': return postToWarehouse('confirmarRecepcionDevolucion', params);
      case 'wh_reconciliarDevolucionZona':   return postToWarehouse('reconciliarDevolucionZona', params);
      // Adhesivos / etiquetas (modal en módulo Almacén → Envasado)
      case 'wh_imprimirEtiqueta':            return postToWarehouse('imprimirEtiqueta', params);
      case 'wh_estadoImpresoraAdhesivo':     return postToWarehouse('estadoImpresoraAdhesivo', params);
      case 'wh_calibrarImpresoraAdhesivo':   return postToWarehouse('calibrarImpresoraAdhesivo', params);
      case 'wh_previsualizarTSPLEtq':        return postToWarehouse('previsualizarTSPLEtq', params);
      // [v2.43.119] Sistema de lotes de adhesivos (sub-jobs + tracking + GAPDETECT condicional)
      case 'wh_crearLoteAdhesivo':           return postToWarehouse('crearLoteAdhesivo', params);
      case 'wh_imprimirSubLoteAdhesivo':     return postToWarehouse('imprimirSubLoteAdhesivo', params);
      case 'wh_getEstadoLoteAdhesivo':       return postToWarehouse('getEstadoLoteAdhesivo', params);
      case 'wh_pausarLoteAdhesivo':          return postToWarehouse('pausarLoteAdhesivo', params);
      case 'wh_cancelarLoteAdhesivo':        return postToWarehouse('cancelarLoteAdhesivo', params);
      case 'wh_getLotesAdhesivoPendientes':  return postToWarehouse('getLotesAdhesivoPendientes', params);
      // [v2.43.143] Historial lotes adhesivo por tipoEtiqueta
      case 'wh_getLotesAdhesivoHistorial':   return postToWarehouse('getLotesAdhesivoHistorial', params);
      // [v2.43.144] Diagnóstico + auto-install trigger procesarLotes
      case 'wh_diagnosticoTriggerLotes':     return postToWarehouse('diagnosticoTriggerLotes', params);
      case 'wh_asegurarTriggerLotes':        return postToWarehouse('asegurarTriggerLotes', params);
      case 'wh_procesarAhoraTodos':          return postToWarehouse('procesarAhoraTodos', params);
      case 'wh_diagnosticoPrintNodeAdhesivo':return postToWarehouse('diagnosticoPrintNodeAdhesivo', params);
      // [v2.43.125] Calibración inteligente + membretes ME/WH
      case 'wh_estadoCalibracionRollo':      return postToWarehouse('estadoCalibracionRollo', params);
      case 'wh_imprimirCalibradoresAdhesivo':return postToWarehouse('imprimirCalibradoresAdhesivo', params);
      case 'wh_aplicarDriftDetectado':       return postToWarehouse('aplicarDriftDetectado', params);
      case 'wh_ajustarDriftManual':          return postToWarehouse('ajustarDriftManual', params);
      case 'wh_resetearContadorPrints':      return postToWarehouse('resetearContadorPrints', params);
      case 'wh_resetearDriftEmergencia':     return postToWarehouse('resetearDriftEmergencia', params);  // [v2.43.161]
      case 'wh_inspeccionarSheetLotes':      return postToWarehouse('inspeccionarSheetLotes', params);  // [v2.43.164]
      case 'wh_repararOrdenSheetLotes':      return postToWarehouse('repararOrdenSheetLotes', params);  // [v2.43.165]
      case 'wh_diagnosticarBackendLotes':    return postToWarehouse('diagnosticarBackendLotes', params); // [v2.43.165]
      case 'wh_crearLoteMembrete':           return postToWarehouse('crearLoteMembrete', params);
      // [v2.43.125] Alertas de precio para membretes ME (locales MOS)
      case 'getMembretesMePendientes':       return getMembretesMePendientes(params);
      case 'marcarMembreteMeImpreso':        return marcarMembreteMeImpreso(params);
      case 'ignorarMembreteMe':              return ignorarMembreteMe(params);
      // [v2.43.154] Alias con prefijo wh_ porque el módulo membrete-modal
      // siempre prefija con 'wh_' (endpointPrefix: 'wh_'), pero estos endpoints
      // viven EN MOS, no en WH. Bug síntoma: 'Acción no reconocida: wh_getMembretesMePendientes'.
      case 'wh_getMembretesMePendientes':    return getMembretesMePendientes(params);
      case 'wh_marcarMembreteMeImpreso':     return marcarMembreteMeImpreso(params);
      case 'wh_ignorarMembreteMe':           return ignorarMembreteMe(params);
      // [v2.43.129] Seguridad: dispositivos + horarios + alertas
      case 'diagnosticoSetupSeguridad':      return diagnosticoSetupSeguridad();
      case 'getSeguridadAlertas':            return getSeguridadAlertas(params);
      case 'desbloquearTemporalDispositivo': return desbloquearTemporalDispositivo(params);
      case 'reactivarDispositivoSuspendido': return reactivarDispositivoSuspendido(params);
      case 'solicitarExtensionHorario':      return solicitarExtensionHorario(params);
      case 'aprobarExtensionHorario':        return aprobarExtensionHorario(params);
      case 'notificarmeCuandoAbra':          return notificarmeCuandoAbra(params);
      case 'extenderHorarioHoy':             return extenderHorarioHoy(params);
      case 'wh_invalidarCacheHorario':       return postToWarehouse('invalidarCacheHorario', params);
      case 'wh_verificarHorario':            return postToWarehouse('verificarHorario', params);
      case 'getVentasMosExpress':  return getVentasMosExpress(params);
      case 'getRotacion':            return getRotacionProductos(params);
      case 'getAnaliticaProducto':   return getAnaliticaProducto(params);
      case 'getConexiones':        return getConexiones();
      case 'setConexion':          return setConexion(params);
      case 'getEcoStatus':         return getEcoStatus();
      case 'forwardWHPickup':      return forwardWHPickup(params);
      case 'forwardWHAction':      return forwardWHAction(params);

      // ── Config ─────────────────────────────────────────────
      case 'getConfig':            return getConfigMos();
      case 'setConfig':            return setConfigMos(params);

      // ── Dispositivos ───────────────────────────────────────
      case 'getDispositivos':              return getDispositivos(params);
      case 'crearDispositivo':             return crearDispositivo(params);
      case 'actualizarDispositivo':        return actualizarDispositivo(params);
      case 'registrarConexion':            return registrarConexionDispositivo(params);
      case 'registrarSesionDispositivo':   return registrarSesionDispositivo(params);
      case 'getDispositivosPendientes':    return getDispositivosPendientes();
      case 'consultarEstadoDispositivo':   return consultarEstadoDispositivo(params);
      case 'forzarPushDispositivo':        return forzarPushDispositivo(params);
      case 'limpiarFlagDevice':            return limpiarFlagDevice(params);
      case 'verificarMiTokenRegistrado':   return verificarMiTokenRegistrado(params);
      case 'aprobarDispositivoPendiente':  return aprobarDispositivoPendiente(params);
      case 'aprobarDispositivoEnSitu':     return aprobarDispositivoEnSitu(params);
      case 'reactivarDispositivoSuspendido': return reactivarDispositivoSuspendido(params);  // [v2.43.167]
      case 'forzarReVerifyDispositivo':    return forzarReVerifyDispositivo(params);         // [v2.43.167]
      case 'alertarDispositivosInactivos2a7d': return alertarDispositivosInactivos2a7d();    // [v2.43.167]
      case 'cancelarPendientesAntiguos':     return cancelarPendientesAntiguos();             // [v2.43.172 R6]
      case 'instalarTriggerCancelarPendientes': return instalarTriggerCancelarPendientes();   // [v2.43.172 R6]
      case 'reinstalarTriggersSeguridadNocturno': return reinstalarTriggersSeguridadNocturno(); // [v2.43.173]
      case 'rechazarDispositivoPendiente': return rechazarDispositivoPendiente(params);
      case 'vincularBrowserDispositivo':   return vincularBrowserDispositivo(params);
      case 'limpiarPendientesMOS':         return limpiarPendientesMOS();
      case 'notificarInicioSesionVendedor': return notificarInicioSesionVendedor(params);
      case 'registrarPermisosDispositivo': return registrarPermisosDispositivo(params);
      case 'marcarWizardMostrado':         return marcarWizardMostrado(params);
      case 'forzarWizardDispositivo':      return forzarWizardDispositivo(params);
      case 'revocarDispositivo':           return revocarDispositivo(params);
      case 'purgarDispositivosInactivos':  return purgarDispositivosInactivos(params);

      // ── Zonas (puntos de venta) ────────────────────────────
      case 'getZonas':             return getZonas(params);
      case 'crearZona':            return crearZona(params);
      case 'actualizarZona':       return actualizarZona(params);

      // ── Estaciones ─────────────────────────────────────────
      case 'getEstaciones':        return getEstaciones(params);
      case 'crearEstacion':        return crearEstacion(params);
      case 'actualizarEstacion':   return actualizarEstacion(params);
      case 'verificarPinEstacion': return verificarPinEstacion(params);
      case 'getEstacionesParaApp': return getEstacionesParaApp(params);

      // ── Impresoras ─────────────────────────────────────────
      case 'getImpresoras':        return getImpresoras(params);
      case 'crearImpresora':       return crearImpresora(params);
      case 'actualizarImpresora':  return actualizarImpresora(params);

      // ── Series documentales ────────────────────────────────
      case 'getSeries':            return getSeries(params);
      case 'crearSerie':           return crearSerie(params);
      case 'actualizarSerie':      return actualizarSerie(params);

      // ── Personal master ────────────────────────────────────
      case 'getPersonalMaster':         return getPersonalMaster(params);
      case 'crearPersonalMaster':       return crearPersonalMaster(params);
      case 'actualizarPersonalMaster':  return actualizarPersonalMaster(params);
      case 'verificarPinPersonal':      return verificarPinPersonal(params);
      case 'registrarConexionPersonal': return registrarConexionPersonal(params);
      case 'getHistorialPersonal':      return getHistorialPersonal(params);

      // ── Finanzas ────────────────────────────────────────────
      case 'getFinanzasDia':             return getFinanzasDia(params);
      case 'getFinanzasRango':           return getFinanzasRango(params);
      case 'getJornadas':                return getJornadas(params);
      case 'registrarJornada':           return registrarJornada(params);
      case 'eliminarJornada':            return eliminarJornada(params);
      case 'rehabilitarJornada':         return rehabilitarJornada(params);
      case 'importarJornadasDesdeCajas': return importarJornadasDesdeCajas(params);
      case 'getGastos':                  return getGastos(params);
      case 'registrarGasto':             return registrarGasto(params);
      case 'eliminarGasto':              return eliminarGasto(params);
      case 'actualizarCostoPorSku':      return actualizarCostoPorSku(params);

      // ── Push notifications ─────────────────────────────────────
      case 'registrarPushToken':        return registrarPushToken(params);
      case 'enviarPushNotif':           return enviarPushNotif(params);
      case 'enviarPushUsuario':         return enviarPushUsuario(params);

      // ── Evaluaciones de personal ──────────────────────────────
      case 'crearEvaluacion':           return crearEvaluacion(params);
      case 'getEvaluacionesDia':        return getEvaluacionesDia(params);
      case 'getResumenDia':             return getResumenDia(params);
      case 'getResumenTodosDia':        return getResumenTodosDia(params);
      case 'getLiquidacionSemana':      return getLiquidacionSemana(params);

      // ── Notificaciones (catálogo + log + test) ─────────────
      case 'getNotificacionesConfig':   return getNotificacionesConfig();
      case 'actualizarNotifConfig':     return actualizarNotifConfig(params);
      case 'restaurarNotifDefault':     return restaurarNotifDefault(params);
      case 'probarNotificacion':        return probarNotificacion(params);
      case 'getNotifLog':                return getNotifLog(params);
      case 'reenviarNotificacion':       return reenviarNotificacion(params);

      // ── Monitoreo de impresoras ────────────────────────────
      case 'verificarImpresorasAhora':   return verificarImpresorasAhora();
      case 'listarImpresorasPN':        return listarImpresorasPN();
      case 'getPrintNodePrinters':      return listarImpresorasPN();
      case 'imprimirLiquidacionDia':    return imprimirLiquidacionDia(params);

      // ── Liquidaciones v2 (modelo acumulativo por día) ──────
      case 'getLiquidacionesPendientes': return getLiquidacionesPendientes(params);
      case 'marcarPagos':                return marcarPagos(params);
      case 'anularPago':                 return anularPago(params);
      case 'getLiquidacionesPagadas':    return getLiquidacionesPagadas(params);
      // [v2.41.31] Vetar/desvetar inline desde pendientes
      case 'vetarLiquidacionDia':        return vetarLiquidacionDia(params);
      case 'desvetarLiquidacionDia':     return desvetarLiquidacionDia(params);
      case 'getLiquidacionesVetadas':    return getLiquidacionesVetadas(params);
      // [v2.41.32] Recomputar fila individual + backfill últimos N días
      case 'recomputarLiquidacionDia':   return recomputarLiquidacionDia(params);
      case 'backfillLiquidacionesDia':   return backfillLiquidacionesDia(params);
      // [v2.41.60] Lectura/escritura directa de bonificacion/sancion en LIQUIDACIONES_DIA
      case 'getLiqDiaBonSan':            return getLiqDiaBonSan(params);
      // [v2.41.62] Endpoint fast: lee Personal del Día directo de la tabla plana
      case 'getPersonalDiaFast':         return getPersonalDiaFast(params);
      // [v2.41.34] Setup trigger horario de auto-sync
      case 'setupLiqSyncTrigger':        return setupLiqSyncTrigger();
      // [v2.41.36] Cierre nocturno 23h — sesiones WH + cajas ME
      case 'cierreNocturnoTodos':        return cierreNocturnoTodos();
      case 'setupCierreNocturnoTrigger': return setupCierreNocturnoTrigger();
      // [v2.41.76] Diagnóstico cron + manejo flag Forzar_Logout
      case 'getCronStatus':              return getCronStatus();
      case 'marcarLogoutHonrado':        return marcarLogoutHonrado(params);
      // [v2.41.82] PrinterPicker — verificar estado fresh de 1 impresora
      case 'verificarImpresoraAhora':    return verificarImpresoraAhora(params);
      case 'getPagoDetalle':             return getPagoDetalle(params);
      case 'imprimirTicketPago':         return imprimirTicketPago(params);
      case 'migrarLiquidacionesV2':      return migrarLiquidacionesV2();
      // Liquidaciones DIA (materializado)
      case 'getLiquidacionesPendientesDia':     return getLiquidacionesPendientesDia(params);
      case 'backfillLiquidacionesDia':          return backfillLiquidacionesDia(params);
      case 'configurarTriggerLiquidacionDia':   return configurarTriggerLiquidacionDia();

      // ── Etiquetas (membretes por zona) ─────────────────────
      case 'getEtiquetasPendientes':            return getEtiquetasPendientes(params);
      case 'marcarVistoEtiqueta':               return marcarVistoEtiqueta(params);
      case 'marcarPegadaEtiqueta':              return marcarPegadaEtiqueta(params);
      case 'marcarPegadasBatch':                return marcarPegadasBatch(params);
      case 'imprimirBatchEtiquetasZona':        return imprimirBatchEtiquetasZona(params);
      case 'reimprimirEtiqueta':                return reimprimirEtiqueta(params);
      case 'getEtiquetasPorZona':               return getEtiquetasPorZona();
      case 'configurarTriggerEtiquetas':        return configurarTriggerEtiquetas();

      // ── Liquidaciones legacy (stubs que delegan o devuelven vacío) ──
      case 'getLiquidacionesPendientesSemana': return getLiquidacionesPendientesSemana(params);
      case 'getDetalleDiasPendientes':         return getDetalleDiasPendientes(params);
      case 'emitirLiquidacion':                return emitirLiquidacion(params);
      case 'emitirLiquidacionesTodas':         return emitirLiquidacionesTodas(params);
      case 'marcarLiquidacionPagada':          return marcarLiquidacionPagada(params);
      case 'anularLiquidacion':                return anularLiquidacion(params);
      case 'getLiquidacionesEmitidas':         return getLiquidacionesEmitidas(params);
      case 'getLiquidacionDetalle':            return getLiquidacionDetalle(params);
      case 'anularJornadas':                   return anularJornadas(params);

      // ── Bloqueo remoto de usuarios (ME / WH) ───────────────
      case 'getEstadoBloqueoUsuario':   return getEstadoBloqueoUsuario(params);
      case 'desbloquearUsuarioTemporal':return desbloquearUsuarioTemporal(params);
      case 'getBloqueosActivos':        return getBloqueosActivos(params);
      case 'bloquearVendedorME':        return bloquearVendedorME(params);
      case 'bloquearUsuario':           return bloquearVendedorME(params); // alias genérico (ME + WH + cualquier app)
      case 'getVendedoresMEBloqueados': return getVendedoresMEBloqueados(params);

      // ── Bloqueo por UUID de dispositivo (encarcela el aparato) ────
      case 'bloquearDispositivosDeUsuario': return bloquearDispositivosDeUsuario(params);
      case 'liberarDispositivoBloqueado':   return liberarDispositivoBloqueado(params);
      case 'getDispositivosBloqueados':     return getDispositivosBloqueados(params);

      // ── DeviceState: snapshot remoto de sesión por deviceId ──
      case 'syncDeviceState':           return syncDeviceState(params);
      case 'getDeviceState':            return getDeviceState(params.deviceId);

      // ── Seguridad: clave admin global unificada ────────────
      case 'verificarClaveAdmin':       return verificarClaveAdmin(params);
      case 'getClaveAdminGlobal':       return getClaveAdminGlobal(params);
      case 'rotarClaveAdminGlobal':     return rotarClaveAdminGlobal(params);
      case 'getAdminPinsCache':         return getAdminPinsCache(params);
      case 'getAuditoriaAdmin':         return getAuditoriaAdmin(params);
      // [v2.41.83] Catálogo de acciones admin para AdminAuthModal universal
      case 'getAuthCatalogo':           return getAuthCatalogo();

      // ── Audio: escucha remota on-demand desde MOS ─────────
      case 'iniciarEscuchaAudio':       return iniciarEscuchaAudio(params);
      case 'detenerEscuchaAudio':       return detenerEscuchaAudio(params);
      case 'subirChunkAudio':           return subirChunkAudio(params);
      case 'getSesionesAudio':          return getSesionesAudio(params);
      case 'getChunksAudioSesion':      return getChunksAudioSesion(params);
      case 'getChunkAudioContent':      return getChunkAudioContent(params);
      case 'getEstadoAudio':            return getEstadoAudio(params);

      // ── GPS: tracking de dispositivos (anti-robo) ─────────
      case 'registrarUbicacion':            return registrarUbicacion(params);
      case 'getUltimaUbicacionDispositivo': return getUltimaUbicacionDispositivo(params);
      case 'getUbicacionesDispositivo':     return getUbicacionesDispositivo(params);

      // ── Cajas MosExpress ────────────────────────────────────
      case 'getCierresCaja':            return getCierresCaja(params);
      case 'anularTicketME':            return anularTicketME(params);
      case 'cambiarMetodoME':           return cambiarMetodoME(params);
      case 'imprimirTicketZCierre':     return imprimirTicketZCierre(params);
      case 'getTicketZTexto':           return getTicketZTexto(params);
      case 'datosTurno':               return datosTurno(params);

      // ── Editar tickets desde MOS (puente a ME) ─────────────
      case 'meCobrarCredito':           return meCobrarCredito(params);
      case 'meEditarFormaPago':         return meEditarFormaPago(params);
      case 'meAprobarComoCredito':      return meAprobarComoCredito(params);
      case 'meEditarCliente':           return meEditarCliente(params);
      case 'meConvertirNVaCPE':         return meConvertirNVaCPE(params);
      case 'meBajaCPE':                 return meBajaCPE(params);
      case 'meHistorialVenta':          return meHistorialVenta(params);
      case 'meHistorialCliente':        return meHistorialCliente(params);
      case 'meHistorialExtra':          return meHistorialExtra(params);
      case 'meDetalleVenta':            return meDetalleVenta(params);
      case 'meCajasAbiertas':           return meCajasAbiertas();
      case 'meEstadoCajas':             return meEstadoCajas();
      case 'meConsultarCliente':        return meConsultarCliente(params);
      // [v2.41.92] Centro Tributario (admin/master)
      case 'tribResumenMes':            return tribResumenMes(params);
      case 'tribIGVFavorMes':           return tribIGVFavorMes(params);
      case 'tribIGVEmitidoMes':         return tribIGVEmitidoMes(params);
      case 'tribReintentarCPE':         return tribReintentarCPE(params);
      case 'tribReprocesarOCR':         return tribReprocesarOCR(params);
      case 'tribHistorico12meses':      return tribHistorico12meses();
      case 'tribLimpiarVentasHuerfanas': return tribLimpiarVentasHuerfanas();
      case 'tribReconciliarCPEs':       return tribReconciliarCPEsPendientes();
      case 'tribOCRMasivo':             return tribOCRMasivo(params);
      // [v40.3] Sistema de cobro asignado de créditos
      case 'meGetCreditosPendientes':   return meGetCreditosPendientes(params);
      case 'meAsignarCobroCajero':      return meAsignarCobroCajero(params);
      // [v2.41.87] Cobros en vuelo + cancelar + reasignar
      case 'meCobrosEnVuelo':           return meCobrosEnVuelo();
      case 'meCancelarCobroAsignado':   return meCancelarCobroAsignado(params);
      case 'meReasignarCobroAsignado':  return meReasignarCobroAsignado(params);
      // [v41.3] Cierre forzado de caja por admin/master desde MOS
      case 'meCerrarCajaForzado':       return meCerrarCajaForzado(params);

      // [v2.41.75] Warmup ping ultraligero — calienta el script GAS
      // post-login para que las próximas llamadas no paguen el frío.
      case 'ping': return { ok: true, pong: Date.now() };

      default:
        return { ok: false, error: 'Acción no reconocida: ' + action };
    }})();
  } catch(err) {
    return { ok: false, error: err.message, stack: err.stack };
  }
}

// ============================================================
// Helpers compartidos
// ============================================================
function _sheetToObjects(sheet) {
  var data = sheet.getDataRange().getValues();
  if (data.length < 2) return [];
  var headers = data[0].map(function(h) { return String(h).trim(); });
  var tz = Session.getScriptTimeZone();
  return data.slice(1).map(function(row) {
    var obj = {};
    headers.forEach(function(h, i) {
      if (!h) return;
      var v = row[i];
      if (v instanceof Date) {
        obj[h] = Utilities.formatDate(v, tz, 'yyyy-MM-dd');
      } else if (typeof v === 'string' && /^\d+,\d+$/.test(v.trim())) {
        // Celda guardada como texto con separador decimal de coma (ej: "4,5" → 4.5)
        obj[h] = parseFloat(v.trim().replace(',', '.'));
      } else {
        obj[h] = v;
      }
    });
    return obj;
  }).filter(function(obj) {
    return Object.values(obj).some(function(v){ return v !== '' && v !== null && v !== undefined; });
  });
}

function _generateId(prefix) { return prefix + new Date().getTime(); }

function getConfigMos() {
  var rows = _sheetToObjects(getSheet('CONFIG_MOS'));
  var cfg = {};
  rows.forEach(function(r){ cfg[r.clave] = r.valor; });
  return { ok: true, data: cfg };
}

function setConfigMos(params) {
  var sheet = getSheet('CONFIG_MOS');
  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] === params.clave) {
      sheet.getRange(i + 1, 2).setValue(params.valor);
      return { ok: true };
    }
  }
  sheet.appendRow([params.clave, params.valor, params.descripcion || '']);
  return { ok: true };
}
