// ============================================================
// ProyectoMOS — Cajas.gs
// Lee cajas y tickets de MosExpress directo por SS_ID.
// ============================================================

// ── Helpers locales ──────────────────────────────────────────
function _meSS() {
  var id = _getProp('ME_SS_ID');
  if (!id) throw new Error('ME_SS_ID no configurado en Script Properties.');
  return SpreadsheetApp.openById(id);
}

function _tipoCorto(tipoDoc) {
  var t = String(tipoDoc || '').toUpperCase();
  if (t === 'BOLETA')        return 'B';
  if (t === 'FACTURA')       return 'F';
  return 'NV'; // NOTA_DE_VENTA u otros
}

// ============================================================
// getCierresCaja — estado de cajas + todos los tickets (30d)
// ============================================================
function getCierresCaja(params) {
  var ss;
  try { ss = _meSS(); } catch(e) { return { ok: false, error: e.message }; }

  var cajasSheet  = ss.getSheetByName('CAJAS');
  var ventasSheet = ss.getSheetByName('VENTAS_CABECERA');
  var extrasSheet = ss.getSheetByName('MOVIMIENTOS_EXTRA');
  if (!cajasSheet) return { ok: false, error: 'Hoja CAJAS no encontrada en MosExpress.' };

  var tz      = Session.getScriptTimeZone();
  var hoy     = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd');
  var limite  = new Date(); limite.setDate(limite.getDate() - 30);
  var meGasUrl = _getProp('ME_GAS_URL');

  // ── 1. Mapa de cajas (id → vendedor, zona) ─────────────────
  var cajaMap = {};
  var cajasData = cajasSheet.getDataRange().getValues();
  for (var r = 1; r < cajasData.length; r++) {
    var row = cajasData[r];
    cajaMap[String(row[0] || '')] = {
      vendedor: String(row[1] || ''),
      zona:     String(row[8] || row[2] || '')
    };
  }

  // ── 2. Escanear VENTAS_CABECERA ────────────────────────────
  // Cols: 0=ID_Venta 1=Fecha 2=Vendedor 3=Estacion 4=Cliente_Doc
  //       5=Cliente_Nombre 6=Total 7=Tipo_Doc 8=FormaPago
  //       9=Correlativo 10=ID_Caja 11=ID_Disp 12=Estado_Envio
  //       13=Ref_Local 14=Obs
  var ventasPorCaja  = {};
  var ticketsPorCaja = {};
  var todosTickets   = [];
  var kpisTickets    = {
    hoy: { total:0, NV:0, B:0, F:0, anulados:0 },
    mes: { total:0, NV:0, B:0, F:0, anulados:0 }
  };

  if (ventasSheet) {
    var vd = ventasSheet.getDataRange().getValues();
    for (var v = 1; v < vd.length; v++) {
      var idCaja   = String(vd[v][10] || '');
      // La fuente de verdad de estado en ME es FormaPago (col 8):
      // 'ANULADO' = anulado, 'POR_COBRAR' = pendiente, 'CREDITO' = crédito, resto = cobrado
      var formaPago = String(vd[v][8] || 'EFECTIVO');
      // Estado derivado de FormaPago (igual que ME nativo)
      var estado    = (formaPago === 'ANULADO' || formaPago === 'CREDITO') ? formaPago
                    : (formaPago === 'POR_COBRAR' ? 'POR_COBRAR' : 'COMPLETADO');
      // Método para byMetodo solo cuando está cobrado (evita meter 'ANULADO' como método)
      var metodo    = formaPago;
      var tipoDoc   = String(vd[v][7]  || 'NOTA_DE_VENTA');
      var total   = parseFloat(vd[v][6]) || 0;
      var fRaw    = vd[v][1];
      var fecha   = fRaw instanceof Date ? Utilities.formatDate(fRaw, tz, 'yyyy-MM-dd') : String(fRaw || '').substring(0,10);
      var hora    = fRaw instanceof Date ? Utilities.formatDate(fRaw, tz, 'HH:mm') : '';

      // Ignorar tickets más viejos de 30 días
      if (fRaw instanceof Date && fRaw < limite) continue;

      var cajaInfo = cajaMap[idCaja] || { vendedor: '', zona: '' };
      var tipo     = _tipoCorto(tipoDoc);

      // Stats acumulados por caja
      if (idCaja) {
        if (!ventasPorCaja[idCaja]) {
          ventasPorCaja[idCaja] = { total:0, tickets:0, efectivo:0, otros:0,
                                    anulados:0, sinCobrar:0, byMetodo:{}, byDoc:{} };
        }
        var vc = ventasPorCaja[idCaja];
        if (estado === 'ANULADO') {
          vc.anulados++;
        } else if (estado === 'POR_COBRAR') {
          vc.sinCobrar++; vc.tickets++;
        } else {
          vc.total += total; vc.tickets++;
          if (metodo === 'EFECTIVO') { vc.efectivo += total; }
          else if (metodo.indexOf('MIXTO') === 0) {
            var _efeM = metodo.match(/EFE:([\d.]+)/i);
            var _virM = metodo.match(/VIR:([\d.]+)/i);
            var _efe = _efeM ? parseFloat(_efeM[1]) : 0;
            var _vir = _virM ? parseFloat(_virM[1]) : total - _efe;
            vc.efectivo += _efe; vc.otros += _vir;
          } else { vc.otros += total; }
          vc.byMetodo[metodo] = (vc.byMetodo[metodo] || 0) + total;
          vc.byDoc[tipoDoc]   = (vc.byDoc[tipoDoc]   || 0) + total;
        }
      }

      // Ticket individual para la lista maestra
      var tk = {
        idVenta:     String(vd[v][0]  || ''),
        fecha:       fecha,
        hora:        hora,
        correlativo: String(vd[v][9]  || ''),
        clienteDoc:  String(vd[v][4]  || ''),
        clienteNom:  String(vd[v][5]  || ''),
        total:       total,
        tipoDoc:     tipoDoc,
        tipo:        tipo,
        metodo:      metodo,
        estado:      estado,
        obs:         String(vd[v][14] || ''),
        idCaja:      idCaja,
        vendedor:    cajaInfo.vendedor,
        zona:        cajaInfo.zona
      };

      // Por caja (para card expandible)
      if (idCaja) {
        if (!ticketsPorCaja[idCaja]) ticketsPorCaja[idCaja] = [];
        ticketsPorCaja[idCaja].push(tk);
      }

      // Lista maestra (todos)
      todosTickets.push(tk);

      // KPIs tickets
      var esAnulado = (estado === 'ANULADO');
      if (fecha === hoy) {
        if (esAnulado) { kpisTickets.hoy.anulados++; }
        else { kpisTickets.hoy.total++; kpisTickets.hoy[tipo] = (kpisTickets.hoy[tipo] || 0) + 1; }
      }
      if (esAnulado) { kpisTickets.mes.anulados++; }
      else { kpisTickets.mes.total++; kpisTickets.mes[tipo] = (kpisTickets.mes[tipo] || 0) + 1; }
    }
  }

  // Ordenar todos los tickets: más reciente primero
  todosTickets.sort(function(a,b){ return (b.fecha+b.hora) > (a.fecha+a.hora) ? 1 : -1; });

  // ── 3. Escanear MOVIMIENTOS_EXTRA ──────────────────────────
  var extrasPorCaja     = {};
  var extrasListPorCaja = {};
  if (extrasSheet) {
    var ed = extrasSheet.getDataRange().getValues();
    for (var i = 1; i < ed.length; i++) {
      var ec   = String(ed[i][1] || ''); if (!ec) continue;
      var tipo2 = String(ed[i][3] || 'EGRESO');
      var mto  = parseFloat(ed[i][4]) || 0;
      var fEx  = ed[i][2];
      if (!extrasPorCaja[ec])     extrasPorCaja[ec]     = { entradas:0, salidas:0, entradasVirtual:0, salidasVirtual:0 };
      if (!extrasListPorCaja[ec]) extrasListPorCaja[ec] = [];
      if      (tipo2 === 'INGRESO')         extrasPorCaja[ec].entradas        += mto;
      else if (tipo2 === 'INGRESO_VIRTUAL') extrasPorCaja[ec].entradasVirtual += mto;
      else if (tipo2 === 'EGRESO')          extrasPorCaja[ec].salidas         += mto;
      else if (tipo2 === 'EGRESO_VIRTUAL')  extrasPorCaja[ec].salidasVirtual  += mto;
      extrasListPorCaja[ec].push({
        tipo: tipo2, monto: mto,
        concepto: String(ed[i][5] || ''),
        hora: fEx instanceof Date ? Utilities.formatDate(fEx, tz, 'HH:mm') : ''
      });
    }
  }

  // ── 4. Construir objetos de caja ───────────────────────────
  var abiertas = [];
  var cerradas = [];

  for (var rr = 1; rr < cajasData.length; rr++) {
    var crow    = cajasData[rr];
    var idC     = String(crow[0] || '');
    var est2    = String(crow[5] || '');
    var fApert  = crow[3] instanceof Date ? crow[3] : null;
    var fCierr  = crow[7] instanceof Date ? crow[7] : null;

    if (est2 === 'CERRADA' && fCierr && fCierr < limite) continue;
    if (est2 === 'CERRADA' && !fCierr) continue;

    var vc2  = ventasPorCaja[idC]  || { total:0, tickets:0, efectivo:0, otros:0, anulados:0, sinCobrar:0, byMetodo:{}, byDoc:{} };
    var ext  = extrasPorCaja[idC]  || { entradas:0, salidas:0 };
    var mIni = parseFloat(crow[4]) || 0;
    var mFin = parseFloat(crow[6]) || 0;
    var efectivoEsp = mIni + vc2.efectivo + ext.entradas - ext.salidas;
    var diferencia  = est2 === 'CERRADA' ? Math.round((mFin - efectivoEsp) * 100) / 100 : null;

    var obj = {
      idCaja:           idC,
      vendedor:         String(crow[1] || ''),
      estacion:         String(crow[2] || ''),
      zona:             String(crow[8] || ''),
      estado:           est2,
      fechaApertura:    fApert ? Utilities.formatDate(fApert, tz, 'yyyy-MM-dd HH:mm') : '',
      fechaCierre:      fCierr ? Utilities.formatDate(fCierr, tz, 'yyyy-MM-dd HH:mm') : '',
      montoInicial:     mIni,
      montoFinal:       mFin,
      totalVentas:      Math.round(vc2.total    * 100) / 100,
      tickets:          vc2.tickets,
      efectivo:         Math.round(vc2.efectivo * 100) / 100,
      otros:            Math.round(vc2.otros    * 100) / 100,
      anulados:         vc2.anulados,
      sinCobrar:        vc2.sinCobrar,
      byMetodo:         vc2.byMetodo,
      byDoc:            vc2.byDoc,
      entradas:         ext.entradas,
      salidas:          ext.salidas,
      efectivoEsperado: Math.round(efectivoEsp * 100) / 100,
      diferencia:       diferencia,
      ticketsList:      (ticketsPorCaja[idC] || []).slice().reverse(),
      extrasList:       extrasListPorCaja[idC] || [],
      urlReporte:       meGasUrl ? meGasUrl + '?accion=ver_cierre&id_caja=' + encodeURIComponent(idC) : ''
    };

    if (est2 === 'ABIERTA') abiertas.push(obj);
    else                    cerradas.push(obj);
  }

  cerradas.reverse();

  // ── 5. KPIs globales (solo hoy) ────────────────────────────
  var cajasHoy = abiertas.concat(cerradas.filter(function(c){
    return (c.fechaApertura || '').startsWith(hoy) || (c.fechaCierre || '').startsWith(hoy);
  }));
  var kpis = {
    cajasAbiertas: abiertas.length,
    cajasCerradas: cerradas.length,
    totalDia:     Math.round(cajasHoy.reduce(function(a,c){ return a + c.totalVentas; }, 0) * 100) / 100,
    ticketsDia:   cajasHoy.reduce(function(a,c){ return a + c.tickets;  }, 0),
    anuladosDia:  cajasHoy.reduce(function(a,c){ return a + c.anulados; }, 0),
    sinCobrarDia: cajasHoy.reduce(function(a,c){ return a + c.sinCobrar;}, 0)
  };

  return {
    ok: true,
    data: {
      kpis:         kpis,
      kpisTickets:  kpisTickets,
      abiertas:     abiertas,
      cerradas:     cerradas,
      todosTickets: todosTickets,
      generadoEn:   Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd HH:mm:ss')
    }
  };
}

// ============================================================
// anularTicketME — escribe ANULADO directo al SS de ME
// ============================================================
function anularTicketME(params) {
  if (!params.idVenta) return { ok: false, error: 'idVenta requerido' };
  var ss;
  try { ss = _meSS(); } catch(e) { return { ok: false, error: e.message }; }

  var sheet = ss.getSheetByName('VENTAS_CABECERA');
  if (!sheet) return { ok: false, error: 'VENTAS_CABECERA no encontrada' };

  var buscarId = String(params.idVenta).trim();
  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]).trim() === buscarId) {
      if (String(data[i][8]).trim() === 'ANULADO') return { ok: false, error: 'El ticket ya está anulado' };
      sheet.getRange(i + 1, 9).setValue('ANULADO'); // col 9 (1-idx) = FormaPago, igual que ME nativo
      return { ok: true };
    }
  }
  return { ok: false, error: 'Ticket no encontrado: ' + buscarId };
}

// ============================================================
// cambiarMetodoME — cambia FormaPago (y activa si era POR_COBRAR)
// ============================================================
function cambiarMetodoME(params) {
  if (!params.idVenta || !params.metodo) return { ok: false, error: 'idVenta y metodo requeridos' };
  var ss;
  try { ss = _meSS(); } catch(e) { return { ok: false, error: e.message }; }

  var sheet = ss.getSheetByName('VENTAS_CABECERA');
  if (!sheet) return { ok: false, error: 'VENTAS_CABECERA no encontrada' };

  var buscarId = String(params.idVenta).trim();
  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]).trim() === buscarId) {
      if (String(data[i][8]).trim() === 'ANULADO') return { ok: false, error: 'No se puede modificar un ticket anulado' };
      sheet.getRange(i + 1, 9).setValue(params.metodo); // FormaPago col 9 (1-idx), igual que cobrarVentaExistente en ME
      return { ok: true };
    }
  }
  return { ok: false, error: 'Ticket no encontrado: ' + buscarId };
}

// ============================================================
// datosTurno — devuelve JSON con todos los datos del turno
// para el visor HTML turno.html
// params: { idCaja }
// ============================================================
function datosTurno(params) {
  if (!params || !params.idCaja) return { ok: false, error: 'idCaja requerido' };
  var ss;
  try { ss = _meSS(); } catch(e) { return { ok: false, error: e.message }; }

  var tz     = Session.getScriptTimeZone();
  var idCaja = String(params.idCaja);

  // ── 1. Leer CAJAS ────────────────────────────────────────────
  var cajasSheet = ss.getSheetByName('CAJAS');
  if (!cajasSheet) return { ok: false, error: 'Hoja CAJAS no encontrada' };
  var caja = null;
  var cd = cajasSheet.getDataRange().getValues();
  for (var r = 1; r < cd.length; r++) {
    if (String(cd[r][0]) === idCaja) {
      caja = {
        idCaja:       idCaja,
        cajero:       String(cd[r][1] || ''),
        estacion:     String(cd[r][2] || ''),
        zona:         String(cd[r][8] || ''),
        fechaApert:   cd[r][3] instanceof Date ? Utilities.formatDate(cd[r][3], tz, 'dd/MM/yyyy HH:mm') : String(cd[r][3] || ''),
        montoInicial: parseFloat(cd[r][4]) || 0,
        estado:       String(cd[r][5] || ''),
        montoFinal:   parseFloat(cd[r][6]) || 0,
        fechaCierre:  cd[r][7] instanceof Date ? Utilities.formatDate(cd[r][7], tz, 'dd/MM/yyyy HH:mm') : String(cd[r][7] || '')
      };
      break;
    }
  }
  if (!caja) return { ok: false, error: 'Caja no encontrada: ' + idCaja };

  // ── 2. Leer VENTAS_CABECERA ──────────────────────────────────
  var tickets = [];
  var vSheet = ss.getSheetByName('VENTAS_CABECERA');
  if (vSheet) {
    var vd = vSheet.getDataRange().getValues();
    for (var v = 1; v < vd.length; v++) {
      if (String(vd[v][10]) !== idCaja) continue;
      tickets.push({
        idVenta:     String(vd[v][0]  || ''),
        hora:        vd[v][1] instanceof Date ? Utilities.formatDate(vd[v][1], tz, 'HH:mm') : '',
        vendedor:    String(vd[v][2]  || ''),
        clienteDoc:  String(vd[v][4]  || ''),
        clienteNom:  String(vd[v][5]  || ''),
        total:       parseFloat(vd[v][6]) || 0,
        tipoDoc:     String(vd[v][7]  || 'NOTA_DE_VENTA'),
        metodo:      String(vd[v][8]  || 'EFECTIVO'),
        correlativo: String(vd[v][9]  || ''),
        estado:      String(vd[v][12] || 'COMPLETADO'),
        obs:         String(vd[v][14] || '')
      });
    }
  }

  // ── 2b. Leer VENTAS_DETALLE y adjuntar ítems a cada ticket ──
  var ventasIds = {};
  tickets.forEach(function(tk) { ventasIds[tk.idVenta] = true; });
  var dSheet2 = ss.getSheetByName('VENTAS_DETALLE');
  if (dSheet2) {
    var dd = dSheet2.getDataRange().getValues();
    var itemsMap = {};
    for (var di = 1; di < dd.length; di++) {
      var dId = String(dd[di][0] || '');
      if (!ventasIds[dId]) continue;
      if (!itemsMap[dId]) itemsMap[dId] = [];
      itemsMap[dId].push({
        sku:      String(dd[di][1] || ''),
        nombre:   String(dd[di][2] || ''),
        cantidad: parseFloat(dd[di][3]) || 0,
        precio:   parseFloat(dd[di][4]) || 0,
        subtotal: parseFloat(dd[di][5]) || 0
      });
    }
    tickets.forEach(function(tk) { tk.items = itemsMap[tk.idVenta] || []; });
  } else {
    tickets.forEach(function(tk) { tk.items = []; });
  }

  // ── 3. Leer MOVIMIENTOS_EXTRA ────────────────────────────────
  var extras = [];
  var eSheet = ss.getSheetByName('MOVIMIENTOS_EXTRA');
  if (eSheet) {
    var ed = eSheet.getDataRange().getValues();
    for (var ei = 1; ei < ed.length; ei++) {
      if (String(ed[ei][1]) !== idCaja) continue;
      extras.push({
        tipo:     String(ed[ei][3] || 'EGRESO'),
        monto:    parseFloat(ed[ei][4]) || 0,
        concepto: String(ed[ei][5] || ''),
        obs:      String(ed[ei][6] || ''),
        hora:     ed[ei][2] instanceof Date ? Utilities.formatDate(ed[ei][2], tz, 'HH:mm') : ''
      });
    }
  }

  // ── 4. Calcular totales ──────────────────────────────────────
  var _parseMetodo = function(metodo, total) {
    var m = String(metodo || '').toUpperCase().trim();
    if (!m || m === 'POR_COBRAR' || m === 'CREDITO' || m === 'ANULADO') return { efe: 0, vir: 0 };
    if (m === 'EFECTIVO') return { efe: total, vir: 0 };
    if (m === 'VIRTUAL')  return { efe: 0, vir: total };
    if (m.indexOf('MIXTO') === 0) {
      var virM = metodo.match(/VIR:([\d.]+)/i);
      var efeM = metodo.match(/EFE:([\d.]+)/i);
      var vir  = virM ? parseFloat(virM[1]) : 0;
      var efe  = efeM ? parseFloat(efeM[1]) : Math.round((total - vir) * 100) / 100;
      return { efe: efe, vir: vir };
    }
    return { efe: 0, vir: total };
  };

  var anulados   = tickets.filter(function(t){ return t.metodo === 'ANULADO'; });
  var sinCobrar  = tickets.filter(function(t){ return t.metodo === 'POR_COBRAR'; });
  var creditos   = tickets.filter(function(t){ return t.metodo === 'CREDITO'; });
  var cobrados   = tickets.filter(function(t){ return t.metodo !== 'ANULADO' && t.metodo !== 'POR_COBRAR'; });
  var noAnul     = tickets.filter(function(t){ return t.metodo !== 'ANULADO'; });

  var tEfectivo = 0, tVirtual = 0;
  cobrados.filter(function(t){ return t.metodo !== 'CREDITO'; }).forEach(function(t) {
    var r = _parseMetodo(t.metodo, t.total);
    tEfectivo += r.efe;
    tVirtual  += r.vir;
  });
  tEfectivo = Math.round(tEfectivo * 100) / 100;
  tVirtual  = Math.round(tVirtual  * 100) / 100;

  var tExtrasIngreso        = extras.filter(function(x){ return x.tipo === 'INGRESO';         }).reduce(function(s,x){ return s+x.monto; }, 0);
  var tExtrasEgreso         = extras.filter(function(x){ return x.tipo === 'EGRESO';          }).reduce(function(s,x){ return s+x.monto; }, 0);
  var tExtrasIngresoVirtual = extras.filter(function(x){ return x.tipo === 'INGRESO_VIRTUAL'; }).reduce(function(s,x){ return s+x.monto; }, 0);
  var tExtrasEgresoVirtual  = extras.filter(function(x){ return x.tipo === 'EGRESO_VIRTUAL';  }).reduce(function(s,x){ return s+x.monto; }, 0);

  var montoFinalEfe  = Math.round((caja.montoInicial + tEfectivo + tExtrasIngreso - tExtrasEgreso) * 100) / 100;
  var virtualFinal   = Math.round((tVirtual + tExtrasIngresoVirtual - tExtrasEgresoVirtual) * 100) / 100;
  var tCredito       = creditos.reduce(function(s,t){ return s+t.total; }, 0);
  var tAnulTotal     = anulados.reduce(function(s,t){ return s+t.total; }, 0);
  var tSinCobrarTotal= sinCobrar.reduce(function(s,t){ return s+t.total; }, 0);

  // ── 5. Correlativos por tipo ─────────────────────────────────
  var corrPorTipo = {};
  noAnul.forEach(function(t) {
    if (!t.tipoDoc || !t.correlativo) return;
    if (!corrPorTipo[t.tipoDoc]) corrPorTipo[t.tipoDoc] = [];
    corrPorTipo[t.tipoDoc].push(t.correlativo);
  });

  // ── 6. Vendedores y desempeño ────────────────────────────────
  var pMap = {};
  noAnul.forEach(function(t) {
    var n = t.vendedor || 'Sin nombre';
    if (!pMap[n]) pMap[n] = { tks: 0, total: 0 };
    pMap[n].tks++;
    pMap[n].total += t.total;
  });
  var pTotal = Object.keys(pMap).reduce(function(s,k){ return s + pMap[k].total; }, 0);

  var vendedoresList = [];
  var vnSeen = {};
  noAnul.forEach(function(t) {
    if (t.vendedor && t.vendedor !== caja.cajero && !vnSeen[t.vendedor]) {
      vnSeen[t.vendedor] = true;
      vendedoresList.push(t.vendedor);
    }
  });

  // ── 7. Leer IMPRESORAS activas TICKET con PrintNode ID ───────
  // IMPRESORAS vive en ProyectoMOS_DB (este GAS), no en MosExpress
  var impresoras = [];
  var impSheet = getSpreadsheet().getSheetByName('IMPRESORAS');
  if (impSheet) {
    var impData = impSheet.getDataRange().getValues();
    var impHdrs = impData[0].map(function(h){ return String(h).trim(); });
    var iIdIdx   = impHdrs.indexOf('idImpresora');
    var iNomIdx  = impHdrs.indexOf('nombre');
    var iPnIdx   = impHdrs.indexOf('printNodeId');
    var iTipoIdx = impHdrs.indexOf('tipo');
    var iZonaIdx = impHdrs.indexOf('idZona');
    var iActIdx  = impHdrs.indexOf('activo');
    for (var ii = 1; ii < impData.length; ii++) {
      var ir = impData[ii];
      var activo = String(ir[iActIdx] || '').toLowerCase();
      if (activo !== '1' && activo !== 'true') continue;
      if (String(ir[iTipoIdx] || '').toUpperCase() !== 'TICKET') continue;
      var pnId = String(ir[iPnIdx] || '').trim();
      if (!pnId) continue;
      impresoras.push({
        id:          String(ir[iIdIdx]  || ''),
        nombre:      String(ir[iNomIdx] || ''),
        printNodeId: pnId,
        zona:        String(ir[iZonaIdx] || '')
      });
    }
  }

  return {
    ok: true,
    data: {
      caja:       caja,
      tickets:    tickets,
      anulados:   anulados,
      sinCobrar:  sinCobrar,
      creditos:   creditos,
      cobrados:   cobrados,
      extras:     extras,
      corrPorTipo: corrPorTipo,
      vendedores: vendedoresList,
      pMap:       pMap,
      pTotal:     pTotal,
      impresoras: impresoras,
      totales: {
        efectivo:             tEfectivo,
        virtual:              tVirtual,
        credito:              tCredito,
        anulados:             tAnulTotal,
        sinCobrar:            tSinCobrarTotal,
        extrasIngreso:        tExtrasIngreso,
        extrasEgreso:         tExtrasEgreso,
        extrasIngresoVirtual: tExtrasIngresoVirtual,
        extrasEgresoVirtual:  tExtrasEgresoVirtual,
        montoFinalEfe:        montoFinalEfe,
        virtualFinal:         virtualFinal
      }
    }
  };
}

// ============================================================
// imprimirTicketZCierre — regenera el Ticket Z de cualquier
// turno y lo envía a PrintNode.
// Requiere Script Property: PRINTNODE_API_KEY en ProyectoMOS.
// params: { idCaja, printerId, estacion? }
// Modo preview: params.preview = true  → devuelve { ok, texto } sin imprimir
// ============================================================
function getTicketZTexto(params) {
  return imprimirTicketZCierre(Object.assign({}, params, { preview: true, printerId: 'preview' }));
}

function imprimirTicketZCierre(params) {
  if (!params || !params.idCaja)  return { ok: false, error: 'idCaja requerido' };
  var isPreview = params.preview === true;
  if (!isPreview && !params.printerId) return { ok: false, error: 'printerId requerido' };

  var pnKey;
  if (!isPreview) {
    pnKey = PropertiesService.getScriptProperties().getProperty('PRINTNODE_API_KEY');
    if (!pnKey) return { ok: false, error: 'PRINTNODE_API_KEY no configurado en Script Properties de ProyectoMOS' };
  }

  var ss;
  try { ss = _meSS(); } catch(e) { return { ok: false, error: e.message }; }

  var tz     = Session.getScriptTimeZone();
  var idCaja = String(params.idCaja);

  // ── 1. Leer CAJAS ────────────────────────────────────────────
  var cajasSheet = ss.getSheetByName('CAJAS');
  if (!cajasSheet) return { ok: false, error: 'Hoja CAJAS no encontrada en MosExpress' };
  var caja = null;
  var cd   = cajasSheet.getDataRange().getValues();
  for (var r = 1; r < cd.length; r++) {
    if (String(cd[r][0]) === idCaja) {
      caja = {
        cajero:      String(cd[r][1] || ''),
        estacion:    String(params.estacion || cd[r][2] || ''),
        fechaApert:  cd[r][3] instanceof Date ? Utilities.formatDate(cd[r][3], tz, 'dd/MM/yyyy HH:mm') : String(cd[r][3] || ''),
        montoInicial:parseFloat(cd[r][4]) || 0,
        montoFinal:  parseFloat(cd[r][6]) || 0,
        fechaCierre: cd[r][7] instanceof Date ? Utilities.formatDate(cd[r][7], tz, 'dd/MM/yyyy HH:mm') : String(cd[r][7] || '')
      };
      break;
    }
  }
  if (!caja) return { ok: false, error: 'Caja no encontrada: ' + idCaja };

  // ── 2. Leer VENTAS_CABECERA ──────────────────────────────────
  var tickets = [];
  var vSheet  = ss.getSheetByName('VENTAS_CABECERA');
  if (vSheet) {
    var vd = vSheet.getDataRange().getValues();
    for (var v = 1; v < vd.length; v++) {
      if (String(vd[v][10]) !== idCaja) continue;
      tickets.push({
        vendedor:    String(vd[v][2]  || ''),
        total:       parseFloat(vd[v][6]) || 0,
        tipoDoc:     String(vd[v][7]  || 'NOTA_DE_VENTA'),
        metodo:      String(vd[v][8]  || 'EFECTIVO'),
        correlativo: String(vd[v][9]  || ''),
        obs:         String(vd[v][14] || '')
      });
    }
  }

  // ── 3. Leer MOVIMIENTOS_EXTRA ────────────────────────────────
  var extras = [];
  var eSheet = ss.getSheetByName('MOVIMIENTOS_EXTRA');
  if (eSheet) {
    var ed = eSheet.getDataRange().getValues();
    for (var ei = 1; ei < ed.length; ei++) {
      if (String(ed[ei][1]) !== idCaja) continue;
      extras.push({
        tipo:     String(ed[ei][3] || 'EGRESO'),
        monto:    parseFloat(ed[ei][4]) || 0,
        concepto: String(ed[ei][5] || ''),
        hora:     ed[ei][2] instanceof Date ? Utilities.formatDate(ed[ei][2], tz, 'HH:mm') : ''
      });
    }
  }

  // ── 4. Calcular ──────────────────────────────────────────────
  var anulados  = tickets.filter(function(t){ return t.metodo === 'ANULADO'; });
  var cobrados  = tickets.filter(function(t){ return t.metodo !== 'ANULADO' && t.metodo !== 'POR_COBRAR'; });
  var creditos  = tickets.filter(function(t){ return t.metodo === 'CREDITO'; });
  var noAnul    = tickets.filter(function(t){ return t.metodo !== 'ANULADO'; });

  var _parseMetodo = function(metodo, total) {
    var m = String(metodo || '').toUpperCase().trim();
    if (!m || m === 'POR_COBRAR' || m === 'CREDITO') return { efe: 0, vir: 0 };
    if (m === 'EFECTIVO') return { efe: total, vir: 0 };
    if (m === 'VIRTUAL')  return { efe: 0, vir: total };
    if (m.indexOf('MIXTO') === 0) {
      var virM = metodo.match(/VIR:([\d.]+)/i);
      var efeM = metodo.match(/EFE:([\d.]+)/i);
      var vir  = virM ? parseFloat(virM[1]) : 0;
      var efe  = efeM ? parseFloat(efeM[1]) : Math.round((total - vir) * 100) / 100;
      return { efe: efe, vir: vir };
    }
    return { efe: 0, vir: total };
  };
  var tEfectivo = 0, tVirtual = 0;
  cobrados.filter(function(t){ return t.metodo !== 'CREDITO'; }).forEach(function(t) {
    var r = _parseMetodo(t.metodo, t.total);
    tEfectivo += r.efe;
    tVirtual  += r.vir;
  });
  tEfectivo = Math.round(tEfectivo * 100) / 100;
  tVirtual  = Math.round(tVirtual  * 100) / 100;
  var tCredito   = creditos.reduce(function(s,t){return s+t.total;},0);
  var tAnulTotal = anulados.reduce(function(s,t){return s+t.total;},0);
  var tEntradas  = extras.filter(function(x){return x.tipo==='INGRESO';}).reduce(function(s,x){return s+x.monto;},0);
  var tSalidas   = extras.filter(function(x){return x.tipo==='EGRESO'; }).reduce(function(s,x){return s+x.monto;},0);
  var montoFinal = caja.montoInicial + tEfectivo + tEntradas - tSalidas;

  var TLBL = { 'NOTA_DE_VENTA':'Notas V.', 'BOLETA':'Boletas ', 'FACTURA':'Facturas' };
  var corrPorTipo = {};
  noAnul.forEach(function(t) {
    if (!t.tipoDoc || !t.correlativo) return;
    if (!corrPorTipo[t.tipoDoc]) corrPorTipo[t.tipoDoc] = [];
    corrPorTipo[t.tipoDoc].push(t.correlativo);
  });

  var pMap = {};
  noAnul.forEach(function(t) {
    var n = t.vendedor || 'Sin nombre';
    if (!pMap[n]) pMap[n] = { tks:0, total:0 };
    pMap[n].tks++;
    pMap[n].total += t.total;
  });
  var pKeys     = Object.keys(pMap).sort(function(a,b){ return pMap[b].total - pMap[a].total; });
  var pTotal    = pKeys.reduce(function(s,k){return s+pMap[k].total;},0);
  var pTotalTks = pKeys.reduce(function(s,k){return s+pMap[k].tks;},0);

  var vnMap = {}; var vendedoresList = [];
  noAnul.forEach(function(t) {
    if (t.vendedor && t.vendedor !== caja.cajero && !vnMap[t.vendedor]) {
      vnMap[t.vendedor] = true; vendedoresList.push(t.vendedor);
    }
  });

  // ── 5. Helpers ESC/POS ───────────────────────────────────────
  var W = 48;
  function _rep(ch, n) { var r=''; for(var i=0;i<n;i++) r+=ch; return r; }
  function _pEnd(s,w)  { s=String(s||'').substring(0,w); while(s.length<w) s+=' '; return s; }
  function _pSt(s,w)   { s=String(s||''); while(s.length<w) s=' '+s; return s; }
  function _amtP(n,w)  { return _pSt('S/'+(parseFloat(n)||0).toFixed(2),w); }
  function _amtN(n,w)  { var val=parseFloat(n)||0; return _pSt((val<0?'-':' ')+'S/'+Math.abs(val).toFixed(2),w); }
  function _norm(str)  { return String(str||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/[^\x20-\x7E]/g,'?'); }
  function _sHdr(t)    { var s=' '+t+' '; var l=Math.floor((W-s.length)/2); return _rep('=',l)+s+_rep('=',W-s.length-l)+'\n'; }
  function _sRow(lb,e,vi){ return _pEnd(lb,14)+_amtN(e,17)+_amtN(vi,17)+'\n'; }
  function _mkBar(pct) { var f=Math.round(pct*26/100); if(f<0)f=0; if(f>26)f=26; return '  ['+_rep('#',f)+_rep('-',26-f)+'] '+_pSt(String(Math.round(pct)),3)+'%\n'; }

  var SEP  = _rep('=',W)+'\n';
  var SEPd = _rep('-',W)+'\n';

  // ── 6. Construir ticket Z ────────────────────────────────────
  var txt = '\x1b\x40';

  // PARTE 1: CABECERA
  txt += '\x1b\x61\x01';
  txt += '\x1b\x21\x30MOSexpress\x1b\x21\x00\n';
  txt += '\x1b\x45\x01\x1b\x21\x10CIERRE DE TURNO (Z)\x1b\x21\x00\x1b\x45\x00\n';
  txt += SEP;
  txt += '\x1b\x61\x00';
  txt += 'CAJERO  : ' + _norm(caja.cajero) + '\n';
  txt += 'ESTACION: ' + _norm(caja.estacion) + '\n';
  txt += 'APERTURA: ' + caja.fechaApert + '\n';
  txt += 'CIERRE  : ' + caja.fechaCierre + '\n';
  txt += SEPd;
  if (vendedoresList.length > 0) {
    txt += 'VENDEDORES A CARGO:\n';
    vendedoresList.forEach(function(vn){ txt += '  + ' + _norm(vn) + '\n'; });
  }
  txt += 'TICKETS COBRADOS : ' + cobrados.length + '\n';
  txt += 'ANULADOS         : ' + anulados.length + '\n';
  txt += 'CREDITOS(c/p)    : ' + creditos.length + '\n';

  // PARTE 2: MONTO A RECIBIR
  txt += SEP;
  txt += '\x1b\x61\x01';
  txt += '\n\x1b\x45\x01-- SE DEBE RECIBIR --\x1b\x45\x00\n\n';
  txt += '\x1b\x21\x30S/ ' + montoFinal.toFixed(2) + '\x1b\x21\x00\n\n';
  txt += 'EFECTIVO EN CAJON\n';
  txt += '\x1b\x61\x00';
  if (tVirtual > 0) {
    txt += SEPd;
    txt += '\x1b\x61\x01VIRTUAL RECIBIDO:\n';
    txt += '\x1b\x21\x10S/ ' + tVirtual.toFixed(2) + '\x1b\x21\x00\n';
    txt += '\x1b\x61\x00';
  }

  // PARTE 3: RESUMEN
  txt += _sHdr('RESUMEN DEL TURNO');
  txt += _pEnd('CONCEPTO',14) + '  EFECTIVO         VIRTUAL\n';
  txt += SEPd;
  txt += _sRow('Base inicial',    caja.montoInicial, 0);
  txt += _sRow('Ventas cobradas', tEfectivo,         tVirtual);
  if (tEntradas > 0 || tSalidas > 0)
    txt += _sRow('Extras neto',   tEntradas-tSalidas, 0);
  txt += SEPd;
  txt += '\x1b\x45\x01';
  txt += _sRow('EFECTIVO FINAL',  montoFinal,        tVirtual);
  txt += '\x1b\x45\x00';
  if (tCredito > 0) txt += '  +Credito pendiente: ' + _amtP(tCredito,8) + ' (no en caja)\n';

  // PARTE 4: CORRELATIVOS
  txt += _sHdr('CORRELATIVOS DEL TURNO');
  var tiposCorr = Object.keys(corrPorTipo);
  if (tiposCorr.length === 0) {
    txt += '  Sin comprobantes emitidos en este turno\n';
  } else {
    tiposCorr.forEach(function(tipo) {
      var corrs  = corrPorTipo[tipo];
      var sorted = corrs.slice().sort();
      txt += _pEnd(TLBL[tipo]||tipo,9) + ': ' + sorted[0] + '\n';
      if (sorted.length > 1) txt += '           a: ' + sorted[sorted.length-1] + '\n';
      txt += '  Total: ' + corrs.length + ' comprobante' + (corrs.length!==1?'s':'') + '\n';
    });
  }

  // PARTE 5: ANULADOS
  txt += _sHdr('ANULADOS (' + anulados.length + ')');
  if (anulados.length > 0) {
    txt += _pEnd('CORRELATIVO',22) + _pSt('MONTO',10) + '\n' + SEPd;
    anulados.forEach(function(t){ txt += _pEnd(t.correlativo,22) + _amtN(-t.total,10) + '  ANULADO\n'; });
    txt += SEPd;
    txt += _pEnd('TOTAL ANULADO',22) + _amtN(-tAnulTotal,10) + '\n';
  } else {
    txt += '  Sin anulados en este turno\n';
  }

  // PARTE 6: CREDITOS
  txt += _sHdr('CREDITOS PENDIENTES (' + creditos.length + ')');
  if (creditos.length > 0) {
    creditos.forEach(function(t){
      txt += _pEnd(t.correlativo,18) + _amtP(t.total,12) + '\n';
      if (t.obs) txt += '  A: ' + _norm(t.obs).substring(0,43) + '\n';
    });
    txt += SEPd;
    txt += _pEnd('TOTAL CREDITO',18) + _amtP(tCredito,12) + '\n';
    txt += '  ** No incluido en caja -- deuda pendiente\n';
  } else {
    txt += '  Sin creditos otorgados en este turno\n';
  }

  // PARTE 7: EXTRAS
  txt += _sHdr('EXTRAS DEL TURNO (' + extras.length + ')');
  if (extras.length > 0) {
    extras.forEach(function(ex){
      var mEx = ex.tipo==='INGRESO' ? parseFloat(ex.monto) : -parseFloat(ex.monto);
      txt += (ex.tipo==='INGRESO'?'+':'-') + ' ' + _pEnd(_norm(ex.concepto),22) + _amtN(mEx,12) + '\n';
    });
    txt += SEPd;
    if (tEntradas>0) txt += '+ INGRESOS       ' + _amtP(tEntradas,14) + '\n';
    if (tSalidas>0)  txt += '- EGRESOS        ' + _amtN(-tSalidas,14) + '\n';
    txt += '\x1b\x45\x01';
    txt += '  NETO EXTRAS    ' + _amtN(tEntradas-tSalidas,14) + '\n';
    txt += '\x1b\x45\x00';
  } else {
    txt += '  Sin movimientos extra en este turno\n';
  }

  // PARTE 8: DESEMPENO
  txt += _sHdr('DESEMPENO DEL TURNO');
  if (pKeys.length > 0) {
    txt += _pEnd('VENDEDOR',17) + _pSt('TKS',5) + ' ' + _pSt('TOTAL VENDIDO',17) + '\n';
    txt += SEPd;
    pKeys.forEach(function(nombre) {
      var p = pMap[nombre];
      txt += _pEnd(_norm(nombre),17) + _pSt(String(p.tks),5) + ' ' + _amtP(p.total,17) + '\n';
      if (pTotal > 0) txt += _mkBar(Math.round(p.total*100/pTotal));
    });
    txt += SEPd;
    txt += '\x1b\x45\x01';
    txt += _pEnd('TOTAL TURNO',17) + _pSt(String(pTotalTks),5) + ' ' + _amtP(pTotal,17) + '\n';
    txt += '\x1b\x45\x00';
  } else {
    txt += '  Sin datos de vendedores en este turno\n';
  }

  // PIE
  txt += SEP;
  txt += '\x1b\x61\x01';
  txt += '\x1b\x45\x01*** FIN DE TURNO ***\x1b\x45\x00\n';
  txt += '  (Reimpresion desde ProyectoMOS)\n';
  txt += '\n\n\n\n\n\x1d\x56\x00\x1b\x6d\x1b\x69\x1b\x42\x05\x02';

  // ── 7. Modo preview: devolver texto plano ───────────────────
  if (isPreview) {
    var plain = txt
      .replace(/\x1b\x21[\x00-\xff]/g, '')
      .replace(/\x1b\x61[\x00-\xff]/g, '')
      .replace(/\x1b\x45[\x00-\xff]/g, '')
      .replace(/\x1b\x40/g, '')
      .replace(/\x1d[\x00-\xff][\x00-\xff]/g, '')
      .replace(/\x1b[\x00-\xff]/g, '')
      .replace(/[^\x0a\x20-\x7e]/g, '');
    return { ok: true, data: { texto: plain } };
  }

  // ── 8. Enviar a PrintNode ────────────────────────────────────
  var bytes = [];
  for (var ci = 0; ci < txt.length; ci++) bytes.push(txt.charCodeAt(ci) & 0xFF);
  var content = Utilities.base64Encode(bytes);

  try {
    var resp = UrlFetchApp.fetch('https://api.printnode.com/printjobs', {
      method:      'post',
      headers:     { 'Authorization': 'Basic ' + Utilities.base64Encode(pnKey + ':') },
      contentType: 'application/json',
      payload:     JSON.stringify({
        printerId:   parseInt(String(params.printerId), 10),
        title:       'Ticket Z - ' + caja.cajero + ' ' + caja.fechaCierre,
        contentType: 'raw_base64',
        content:     content,
        source:      'ProyectoMOS'
      }),
      muteHttpExceptions: true
    });
    var code = resp.getResponseCode();
    if (code !== 201) {
      return { ok: false, error: 'PrintNode respondio ' + code + ': ' + resp.getContentText().substring(0,200) };
    }
    return { ok: true, printJobId: resp.getContentText() };
  } catch(e) {
    return { ok: false, error: 'Error PrintNode: ' + e.message };
  }
}
