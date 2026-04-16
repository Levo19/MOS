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
          if (metodo === 'EFECTIVO') vc.efectivo += total; else vc.otros += total;
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
      if (!extrasPorCaja[ec])     extrasPorCaja[ec]     = { entradas:0, salidas:0 };
      if (!extrasListPorCaja[ec]) extrasListPorCaja[ec] = [];
      if (tipo2 === 'INGRESO') extrasPorCaja[ec].entradas += mto;
      else                     extrasPorCaja[ec].salidas  += mto;
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
