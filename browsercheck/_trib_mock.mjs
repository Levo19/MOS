// Datos de prueba para verificar la PIEL del módulo tributario en navegador.
// El entorno local no tiene token de Supabase (la app pide PIN), así que se
// intercepta API.post/API.cpeTrazabilidad con datos realistas. NO toca la app:
// se inyecta desde Playwright justo antes de navegar al módulo.
export const MOCK = `(() => {
  const foto = (titulo, serie, total, igv, borrosa) =>
    'data:image/svg+xml;base64,' + btoa(unescape(encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" width="620" height="880">' +
      '<rect width="620" height="880" fill="' + (borrosa ? '#d8d4cb' : '#f6f3ec') + '"/>' +
      '<text x="36" y="72" font-family="monospace" font-size="27" fill="#111">' + titulo + '</text>' +
      '<text x="36" y="118" font-family="monospace" font-size="20" fill="#333">RUC 20100085063</text>' +
      '<text x="36" y="154" font-family="monospace" font-size="20" fill="#333">' + serie + '</text>' +
      '<line x1="36" y1="180" x2="584" y2="180" stroke="#999" stroke-width="2"/>' +
      '<text x="36" y="700" font-family="monospace" font-size="23" fill="#111">OP. GRAVADA  S/ ' + (total - igv).toFixed(2) + '</text>' +
      '<text x="36" y="742" font-family="monospace" font-size="23" fill="#111">IGV 18%      S/ ' + igv.toFixed(2) + '</text>' +
      '<text x="36" y="792" font-family="monospace" font-size="27" fill="#000">TOTAL        S/ ' + total.toFixed(2) + '</text>' +
      (borrosa ? '<rect width="620" height="880" fill="#9a9488" opacity=".55"/>' : '') +
      '</svg>')));

  const guias = [
    { idGuia:'GI-SANTIS-2608-01', prov:'DISTRIBUIDORA SANTIS', serie:'F001', numero:'0012487', total:98.35, igv:15.00, est:'PROCESADO', conf:96, foto:1 },
    { idGuia:'GI-ALICORP-2608-02', prov:'ALICORP',            serie:'F002', numero:'0004411', total:1553.76, igv:237.01, est:'PROCESADO', conf:95, foto:1 },
    { idGuia:'GI-BACKUS-2608-03',  prov:'BACKUS',             serie:'F310', numero:'0091002', total:842.10, igv:128.46, est:'PROCESADO', conf:92, foto:1 },
    { idGuia:'GI-GLORIA-2608-04',  prov:'GLORIA',             serie:'F015', numero:'0007733', total:610.00, igv:93.05,  est:'PROCESADO', conf:89, foto:1 },
    { idGuia:'GI-SANTIS-2608-05',  prov:'DISTRIBUIDORA SANTIS',serie:'F001',numero:'0012533', total:415.50, igv:63.38,  est:'PROCESADO', conf:94, foto:1 },
    { idGuia:'GI-LAIVE-2608-06',   prov:'LAIVE',              serie:'B002', numero:'0000918', total:288.00, igv:43.93,  est:'PROCESADO', conf:88, foto:1 },
    { idGuia:'GI-MERCADO-2608-07', prov:'MERCADO MAYORISTA',  serie:'',     numero:'',        total:0,      igv:0,      est:'SIN_IGV',   conf:0,  foto:1 },
    { idGuia:'GI-MERCADO-2608-08', prov:'MERCADO MAYORISTA',  serie:'',     numero:'',        total:0,      igv:0,      est:'SIN_IGV',   conf:0,  foto:1 },
    { idGuia:'GI-PROV-2608-09',    prov:'PROVEEDOR LOCAL',    serie:'',     numero:'',        total:0,      igv:0,      est:'ILEGIBLE',  conf:0,  foto:2 },
    { idGuia:'GI-PROV-2608-10',    prov:'PROVEEDOR LOCAL',    serie:'',     numero:'',        total:0,      igv:0,      est:'ILEGIBLE',  conf:0,  foto:2 },
    { idGuia:'GI-SINFOTO-2608-11', prov:'',                   serie:'',     numero:'',        total:0,      igv:0,      est:'',          conf:0,  foto:0 },
    { idGuia:'GI-SINFOTO-2608-12', prov:'',                   serie:'',     numero:'',        total:0,      igv:0,      est:'',          conf:0,  foto:0 },
    { idGuia:'GI-SINFOTO-2608-13', prov:'',                   serie:'',     numero:'',        total:0,      igv:0,      est:'',          conf:0,  foto:0 },
    { idGuia:'GI-COLA-2608-14',    prov:'ABARROTES DEL SUR',  serie:'',     numero:'',        total:0,      igv:0,      est:'PENDIENTE', conf:0,  foto:1 }
  ].map((g, i) => ({
    idGuia: g.idGuia,
    urlFoto: g.foto ? foto(g.foto === 2 ? 'BOLETA (foto movida)' : 'FACTURA ELECTRONICA', g.serie + '-' + g.numero, g.total || 120, g.igv || 18.3, g.foto === 2) : '',
    tieneFoto: !!g.foto,
    fecha: '2026-08-' + String(26 - i).padStart(2, '0') + 'T10:00:00Z',
    fechaComprobante: String(26 - i).padStart(2, '0') + '/08/2026',
    serie: g.serie, numero: g.numero, total: g.total,
    igvRecuperable: g.igv, ocrEstado: g.est, confidence: g.conf
  }));
  const totalFavor = guias.reduce((s, g) => s + g.igvRecuperable, 0);

  const cpe = [
    { idVenta:'V-9001', refLocal:'RL9001', correlativo:'B001-0004512', tipo:'BOLETA',  fecha:'2026-08-12T18:22:00Z', total:186.50, cliente:'MARIA QUISPE ROJAS',  clienteDoc:'44120987', nfEstado:'EMITIDO',   aceptadoNubefact:true,  aceptadoSunat:true,  enlacePdf:'https://ejemplo.test/b1.pdf' },
    { idVenta:'V-9002', refLocal:'RL9002', correlativo:'F001-0000318', tipo:'FACTURA', fecha:'2026-08-12T16:05:00Z', total:2480.00, cliente:'COMERCIAL ANDINA SAC', clienteDoc:'20512345678', nfEstado:'EMITIDO', aceptadoNubefact:true, aceptadoSunat:true, enlacePdf:'https://ejemplo.test/f1.pdf' },
    { idVenta:'V-9003', refLocal:'RL9003', correlativo:'B001-0004513', tipo:'BOLETA',  fecha:'2026-08-11T11:40:00Z', total:74.00,  cliente:'JOSE LUIS FLORES',   clienteDoc:'09887766', nfEstado:'EMITIDO',   aceptadoNubefact:true,  aceptadoSunat:true,  enlacePdf:'https://ejemplo.test/b2.pdf' },
    { idVenta:'V-9004', refLocal:'RL9004', correlativo:'B001-0004514', tipo:'BOLETA',  fecha:'2026-08-11T09:15:00Z', total:312.90, cliente:'ROSA HUAMAN',        clienteDoc:'41236547', nfEstado:'PENDIENTE', aceptadoNubefact:true,  aceptadoSunat:false, enlacePdf:'' },
    { idVenta:'V-9005', refLocal:'RL9005', correlativo:'F001-0000319', tipo:'FACTURA', fecha:'2026-08-10T15:00:00Z', total:1120.00, cliente:'INVERSIONES DEL SUR EIRL', clienteDoc:'20600011122', nfEstado:'RECHAZADO', aceptadoNubefact:true, aceptadoSunat:false, sunatDesc:'El dato ingresado en el campo tipo de documento del receptor no cumple con el formato establecido', enlacePdf:'' },
    { idVenta:'V-9006', refLocal:'RL9006', correlativo:'B001-0004515', tipo:'BOLETA',  fecha:'2026-08-09T19:31:00Z', total:58.40,  cliente:'',                   clienteDoc:'', nfEstado:'(sin emitir)', aceptadoNubefact:false, aceptadoSunat:false, enlacePdf:'' },
    { idVenta:'V-9007', refLocal:'RL9007', correlativo:'B001-0004516', tipo:'BOLETA',  fecha:'2026-08-08T12:12:00Z', total:940.25, cliente:'BODEGA EL PROGRESO',  clienteDoc:'10456789012', nfEstado:'EMITIDO', aceptadoNubefact:true, aceptadoSunat:true, enlacePdf:'https://ejemplo.test/b3.pdf' },
    { idVenta:'V-9008', refLocal:'RL9008', correlativo:'F001-0000320', tipo:'FACTURA', fecha:'2026-08-06T10:44:00Z', total:3650.00, cliente:'GRUPO LOGISTICO PERU SAC', clienteDoc:'20477788899', nfEstado:'EMITIDO', aceptadoNubefact:true, aceptadoSunat:true, enlacePdf:'https://ejemplo.test/f2.pdf' },
    { idVenta:'V-9009', refLocal:'RL9009', correlativo:'B001-0004517', tipo:'BOLETA',  fecha:'2026-08-04T08:20:00Z', total:129.00, cliente:'CARLOS MENDOZA',      clienteDoc:'46778899', nfEstado:'EMITIDO',   aceptadoNubefact:true,  aceptadoSunat:true,  enlacePdf:'https://ejemplo.test/b4.pdf' },
    { idVenta:'V-9010', refLocal:'RL9010', correlativo:'B001-0004518', tipo:'BOLETA',  fecha:'2026-08-02T17:55:00Z', total:207.80, cliente:'ANA TORRES',          clienteDoc:'70123456', nfEstado:'BAJA',      aceptadoNubefact:true,  aceptadoSunat:false, enlacePdf:'' }
  ];

  // Serie mensual determinista: agosto cierra A FAVOR, julio EN CONTRA.
  const serieMes = (mes, anio) => {
    const k = (anio * 12 + mes) % 7;
    const favor  = [3120, 980, 2450, 1760, 4010, 2280, 1390][k];
    const emitido= [2380, 1640, 2610, 990, 3320, 3010, 1720][k];
    const ventas = [15600, 10740, 17100, 6480, 21800, 19720, 11260][k];
    return { favor, emitido, ventas };
  };

  const resumen = (mes, anio) => {
    const s = serieMes(mes, anio);
    const hoy = new Date();
    const esActual = (mes === hoy.getMonth() + 1 && anio === hoy.getFullYear());
    const ultimoDia = new Date(anio, mes, 0).getDate();
    const diaActual = esActual ? Math.min(hoy.getDate(), ultimoDia) : ultimoDia;
    const favor = (mes === 8 && anio === 2026) ? 580.83 : s.favor;
    const emitido = (mes === 8 && anio === 2026) ? 412.44 : s.emitido;
    const ventas = (mes === 8 && anio === 2026) ? 9198.85 : s.ventas;
    return {
      mes, anio, igvFavor: favor, igvEmitido: emitido,
      balanceNetoIGV: +(emitido - favor).toFixed(2),
      totalVentas: ventas, rentaMensual: +(ventas * 0.015).toFixed(2),
      diaActual, ultimoDia, pctMes: Math.round(diaActual / ultimoDia * 100),
      guiasMes: 14, guiasConIGV: 6, guiasSinFoto: 3, guiasSinIGV: 2, guiasIlegibles: 2,
      cpeEmitidos: 6, cpePendientes: 1, cpeErrores: 1, cpeAnulados: 1, cpeTotal: 10,
      fechaVencimiento: '2026-09-18', diasParaVencer: 37
    };
  };

  const _post = API.post.bind(API);
  API.post = async (accion, p) => {
    p = p || {};
    if (accion === 'tribResumenMes') {
      const hoy = new Date();
      return resumen(p.mes || hoy.getMonth() + 1, p.anio || hoy.getFullYear());
    }
    if (accion === 'tribHistorico12meses') {
      const labels = ['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'];
      const hoy = new Date(); const out = [];
      for (let i = 11; i >= 0; i--) {
        const d = new Date(hoy.getFullYear(), hoy.getMonth() - i, 1);
        const r = resumen(d.getMonth() + 1, d.getFullYear());
        out.push({ mes: r.mes, anio: r.anio, label: labels[d.getMonth()], igvFavor: r.igvFavor,
                   igvEmitido: r.igvEmitido, balance: r.balanceNetoIGV, ventas: r.totalVentas, renta: r.rentaMensual });
      }
      return out;
    }
    if (accion === 'tribIGVFavorMes') return { guias, totalIGVFavor: totalFavor, totalGuias: guias.length };
    if (accion === 'tribIGVEmitidoMes') return { cpe };
    return _post(accion, p);
  };
  API.cpeTrazabilidad = async () => ({ ok: true, cpe });
  return 'mock instalado';
})()`;
