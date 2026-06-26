// ============================================================
// _verify_datos_turno.mjs
// Verificación 40x del port me.datos_turno vs el GAS datosTurno.
// (a) Replica la lógica JS de GAS leyendo Supabase con pg.
// (b) Llama la RPC me.datos_turno.
// (c) Deep-compara, con foco en los campos de DINERO.
// Uso: node _verify_datos_turno.mjs
// ============================================================
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();

const TZ = 'America/Lima';
// Formateadores que imitan Utilities.formatDate(date, 'America/Lima', fmt)
function fmtLima(d, kind) {
  if (!d) return '';
  const dt = (d instanceof Date) ? d : new Date(d);
  if (isNaN(dt)) return '';
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: TZ, year:'numeric', month:'2-digit', day:'2-digit',
    hour:'2-digit', minute:'2-digit', hour12:false
  }).formatToParts(dt).reduce((o,p)=>(o[p.type]=p.value,o),{});
  const hh = parts.hour === '24' ? '00' : parts.hour;
  if (kind === 'hhmm')   return `${hh}:${parts.minute}`;
  if (kind === 'ymd')    return `${parts.year}-${parts.month}-${parts.day}`;
  if (kind === 'dmyhm')  return `${parts.day}/${parts.month}/${parts.year} ${hh}:${parts.minute}`;
  return '';
}
const r2 = x => Math.round((Number(x)||0) * 100) / 100;
const pf = x => parseFloat(x) || 0;

// ── Port FIEL de datosTurno (la parte que importa: data) ──
async function gasDatosTurno(c, idCaja) {
  const kr = await c.query('select * from me.cajas where id_caja=$1 limit 1', [idCaja]);
  if (!kr.rows.length) return { ok:false, error:'Caja no encontrada: '+idCaja };
  const k = kr.rows[0];
  const caja = {
    idCaja,
    cajero: String(k.vendedor||''),
    estacion: String(k.estacion||''),
    zona: String(k.zona_id||''),
    fechaApert: fmtLima(k.fecha_apertura,'dmyhm'),
    fechaDia: fmtLima(k.fecha_apertura,'ymd'),
    montoInicial: pf(k.monto_inicial),
    estado: String(k.estado||''),
    montoFinal: pf(k.monto_final),
    fechaCierre: fmtLima(k.fecha_cierre,'dmyhm')
  };

  const vr = await c.query(
    'select * from me.ventas where id_caja=$1 order by created_at nulls last, id_venta', [idCaja]);
  const dr = await c.query(
    `select d.* from me.ventas_detalle d join me.ventas v on v.id_venta=d.id_venta
     where v.id_caja=$1 order by d.id_venta, d.linea`, [idCaja]);
  const itemsMap = {};
  dr.rows.forEach(d => {
    const id = String(d.id_venta||'');
    (itemsMap[id] = itemsMap[id] || []).push({
      sku:String(d.sku||''), nombre:String(d.nombre||''),
      cantidad:pf(d.cantidad), precio:pf(d.precio), subtotal:pf(d.subtotal)
    });
  });
  const tickets = vr.rows.map(v => ({
    idVenta: String(v.id_venta||''),
    hora: fmtLima(v.fecha,'hhmm'),
    vendedor: String(v.vendedor||''),
    clienteDoc: String(v.cliente_doc||''),
    clienteNom: String(v.cliente_nombre||''),
    total: pf(v.total),
    tipoDoc: String(v.tipo_doc||'NOTA_DE_VENTA'),
    metodo: String(v.forma_pago||'EFECTIVO'),
    correlativo: String(v.correlativo||''),
    estado: String(v.estado_envio||'COMPLETADO'),
    obs: String(v.obs||''),
    items: itemsMap[String(v.id_venta||'')] || []
  }));

  const er = await c.query('select * from me.movimientos_extra where id_caja=$1 order by ts nulls last, id_extra',[idCaja]);
  const extras = er.rows.map(e => ({
    tipo:String(e.tipo||'EGRESO'), monto:pf(e.monto),
    concepto:String(e.concepto||''), obs:String(e.obs||''),
    hora: fmtLima(e.ts,'hhmm')
  }));

  const _parseMetodo = (metodo, total) => {
    const m = String(metodo||'').toUpperCase().trim();
    if (!m || m==='POR_COBRAR' || m==='CREDITO' || m==='ANULADO') return {efe:0,vir:0};
    if (m==='EFECTIVO') return {efe:total,vir:0};
    if (m==='VIRTUAL')  return {efe:0,vir:total};
    if (m.indexOf('MIXTO')===0) {
      const virM = metodo.match(/VIR:([\d.]+)/i);
      const efeM = metodo.match(/EFE:([\d.]+)/i);
      const vir = virM ? parseFloat(virM[1]) : 0;
      const efe = efeM ? parseFloat(efeM[1]) : Math.round((total-vir)*100)/100;
      return {efe,vir};
    }
    return {efe:0,vir:total};
  };

  const anulados  = tickets.filter(t=>t.metodo==='ANULADO');
  const sinCobrar = tickets.filter(t=>t.metodo==='POR_COBRAR');
  const creditos  = tickets.filter(t=>t.metodo==='CREDITO');
  const cobrados  = tickets.filter(t=>t.metodo!=='ANULADO' && t.metodo!=='POR_COBRAR');
  const noAnul    = tickets.filter(t=>t.metodo!=='ANULADO');

  let tEfectivo=0, tVirtual=0;
  cobrados.filter(t=>t.metodo!=='CREDITO').forEach(t=>{
    const r=_parseMetodo(t.metodo,t.total); tEfectivo+=r.efe; tVirtual+=r.vir;
  });
  tEfectivo=r2(tEfectivo); tVirtual=r2(tVirtual);

  const tExtrasIngreso        = extras.filter(x=>x.tipo==='INGRESO').reduce((s,x)=>s+x.monto,0);
  const tExtrasEgreso         = extras.filter(x=>x.tipo==='EGRESO').reduce((s,x)=>s+x.monto,0);
  const tExtrasIngresoVirtual = extras.filter(x=>x.tipo==='INGRESO_VIRTUAL').reduce((s,x)=>s+x.monto,0);
  const tExtrasEgresoVirtual  = extras.filter(x=>x.tipo==='EGRESO_VIRTUAL').reduce((s,x)=>s+x.monto,0);

  const montoFinalEfe = r2(caja.montoInicial + tEfectivo + tExtrasIngreso - tExtrasEgreso);
  const virtualFinal  = r2(tVirtual + tExtrasIngresoVirtual - tExtrasEgresoVirtual);
  const tCredito = creditos.reduce((s,t)=>s+t.total,0);
  const tAnulTotal = anulados.reduce((s,t)=>s+t.total,0);
  const tSinCobrarTotal = sinCobrar.reduce((s,t)=>s+t.total,0);

  const corrPorTipo={};
  noAnul.forEach(t=>{ if(!t.tipoDoc||!t.correlativo)return;
    (corrPorTipo[t.tipoDoc]=corrPorTipo[t.tipoDoc]||[]).push(t.correlativo); });

  const pMap={};
  noAnul.forEach(t=>{ const n=t.vendedor||'Sin nombre';
    if(!pMap[n])pMap[n]={tks:0,total:0}; pMap[n].tks++; pMap[n].total+=t.total; });
  const pTotal = Object.keys(pMap).reduce((s,kk)=>s+pMap[kk].total,0);

  const vendedoresList=[]; const vnSeen={};
  noAnul.forEach(t=>{ if(t.vendedor && t.vendedor!==caja.cajero && !vnSeen[t.vendedor]){
    vnSeen[t.vendedor]=true; vendedoresList.push(t.vendedor); } });

  // impresoras
  const estR = await c.query('select id_estacion,nombre from mos.estaciones');
  const estNomMap={}; estR.rows.forEach(e=>{ const id=String(e.id_estacion||'').trim(); if(id) estNomMap[id]=String(e.nombre||''); });
  const impR = await c.query('select * from mos.impresoras order by id_impresora');
  const impresoras=[];
  impR.rows.forEach(ir=>{
    const activo = String(ir.activo==null?'':ir.activo).toLowerCase();
    if(activo!=='1'&&activo!=='true') return;
    if(String(ir.tipo||'').toUpperCase()!=='TICKET') return;
    const pnId=String(ir.printnode_id||'').trim(); if(!pnId)return;
    const idEst=String(ir.id_estacion||'').trim();
    impresoras.push({ id:String(ir.id_impresora||''), nombre:String(ir.nombre||''),
      printNodeId:pnId, zona:String(ir.id_zona||''), estacion: estNomMap[idEst]||idEst });
  });

  // auditorias filtradas por zona+fecha
  const auditorias={}, auditoriasLower={};
  if (caja.fechaDia) {
    const ar = await c.query('select * from me.auditorias');
    const cajaZonaNorm = String(caja.zona||'').trim().toUpperCase();
    ar.rows.forEach(a=>{
      const aFechaStr = fmtLima(a.fecha,'ymd');
      if (aFechaStr!==caja.fechaDia) return;
      if (cajaZonaNorm) {
        const az=String(a.zona_id||'').trim().toUpperCase();
        if (az && az!==cajaZonaNorm) return;
      }
      const av=String(a.vendedor||'').trim();
      if(!av)return;
      auditorias[av]=(auditorias[av]||0)+1;
      auditoriasLower[av.toLowerCase()]=(auditoriasLower[av.toLowerCase()]||0)+1;
    });
  }

  // actores zona
  const actoresSet={};
  const add=n=>{ const s=String(n||'').trim(); if(!s)return; actoresSet[s.toLowerCase()]=s; };
  Object.keys(pMap).forEach(add); add(caja.cajero); Object.keys(auditorias).forEach(add);
  const jr = await c.query('select * from mos.jornadas');
  const cajaZonaUp=String(caja.zona||'').trim().toUpperCase();
  jr.rows.forEach(j=>{
    const jf=fmtLima(j.fecha,'ymd');
    if(jf!==caja.fechaDia) return;
    const jApp=String(j.app_origen||'').toUpperCase(); if(jApp && jApp!=='ME') return;
    const jZ=String(j.zona||'').trim().toUpperCase(); if(jZ && cajaZonaUp && jZ!==cajaZonaUp) return;
    add(j.nombre);
  });
  const actoresZona = Object.keys(actoresSet).map(kk=>actoresSet[kk]).sort();

  // policy
  const zr = await c.query('select politica_json from mos.zonas where id_zona=$1 limit 1',[caja.zona||'']);
  let metaDiaria=0, comisionPct=0, metaAud=0, configurada=false;
  if (caja.zona && zr.rows.length && zr.rows[0].politica_json) {
    const pol = zr.rows[0].politica_json;
    if (pf(pol.metaDiaria)>0) metaDiaria=pf(pol.metaDiaria);
    if (pf(pol.comisionExcedentePct)>=0) comisionPct=pf(pol.comisionExcedentePct);
    if (pf(pol.metaAuditorias)>0) metaAud=pf(pol.metaAuditorias);
    if (metaDiaria>0) configurada=true;
  }
  const totalCobrado=r2(tEfectivo+tVirtual);
  const metaLograda=totalCobrado>=metaDiaria;
  const excedente=Math.max(0, r2(totalCobrado-metaDiaria));
  const comisionTotal=Math.round(excedente*comisionPct)/100;
  const pMapCobrado={};
  cobrados.filter(t=>t.metodo!=='CREDITO').forEach(t=>{ const n=t.vendedor||'Sin nombre';
    if(!pMapCobrado[n])pMapCobrado[n]={tks:0,total:0}; pMapCobrado[n].tks++; pMapCobrado[n].total+=t.total; });
  const totalCobradoPMap=Object.keys(pMapCobrado).reduce((s,kk)=>s+pMapCobrado[kk].total,0);
  const comisionPorVendedor=Object.keys(pMapCobrado).map(n=>{
    const venta=pMapCobrado[n].total;
    const pctVend=totalCobradoPMap>0?(venta/totalCobradoPMap):0;
    return { nombre:n, venta:r2(venta), pct:Math.round(pctVend*1000)/10,
      comision: comisionTotal>0?Math.round(comisionTotal*pctVend*100)/100:0 };
  }).sort((a,b)=>b.venta-a.venta);
  const meta={ configurada, metaDiaria, comisionPct, totalCobrado, metaLograda, excedente,
    faltante: metaLograda?0:r2(metaDiaria-totalCobrado),
    progresoPct: metaDiaria>0?Math.round(totalCobrado/metaDiaria*1000)/10:0,
    comisionTotal, comisionPorVendedor };

  return { ok:true, data:{
    caja, tickets, anulados, sinCobrar, creditos, cobrados, extras, corrPorTipo,
    vendedores:vendedoresList, pMap, pTotal, impresoras, auditorias, auditoriasLower,
    actoresZona, metaAudit:metaAud, meta,
    totales:{ efectivo:tEfectivo, virtual:tVirtual, credito:tCredito, anulados:tAnulTotal,
      sinCobrar:tSinCobrarTotal, extrasIngreso:tExtrasIngreso, extrasEgreso:tExtrasEgreso,
      extrasIngresoVirtual:tExtrasIngresoVirtual, extrasEgresoVirtual:tExtrasEgresoVirtual,
      montoFinalEfe, virtualFinal } } };
}

// ── Comparación ──
const MONEY_FIELDS = ['efectivo','virtual','credito','anulados','sinCobrar','extrasIngreso',
  'extrasEgreso','extrasIngresoVirtual','extrasEgresoVirtual','montoFinalEfe','virtualFinal'];

function approx(a,b){ return Math.abs((Number(a)||0)-(Number(b)||0)) < 0.005; }

// normaliza números en jsonb (vienen como string desde pg a veces)
function num(x){ return Number(x); }

function compareData(exp, got) {
  const diffs=[];
  // money totales
  for (const f of MONEY_FIELDS) {
    const e=exp.totales[f], g=num(got.totales[f]);
    if (!approx(e,g)) diffs.push({field:`totales.${f}`, expected:e, got:g, MONEY:true});
  }
  // counts
  for (const arr of ['tickets','anulados','sinCobrar','creditos','cobrados','extras']) {
    if ((exp[arr]||[]).length !== (got[arr]||[]).length)
      diffs.push({field:`${arr}.length`, expected:exp[arr].length, got:(got[arr]||[]).length});
  }
  // per-ticket totals (money) — compara como multiset por idVenta
  const byId = arr => Object.fromEntries((arr||[]).map(t=>[t.idVenta, t]));
  const gById = byId(got.tickets);
  (exp.tickets||[]).forEach(et=>{
    const gt=gById[et.idVenta];
    if (!gt){ diffs.push({field:`ticket ${et.idVenta} MISSING`}); return; }
    if (!approx(et.total, gt.total)) diffs.push({field:`ticket ${et.idVenta}.total`, expected:et.total, got:num(gt.total), MONEY:true});
    if (et.metodo !== gt.metodo) diffs.push({field:`ticket ${et.idVenta}.metodo`, expected:et.metodo, got:gt.metodo});
    if (String(et.correlativo)!==String(gt.correlativo)) diffs.push({field:`ticket ${et.idVenta}.correlativo`, expected:et.correlativo, got:gt.correlativo});
    // items subtotal sum
    const es=(et.items||[]).reduce((s,i)=>s+i.subtotal,0);
    const gs=(gt.items||[]).reduce((s,i)=>s+num(i.subtotal),0);
    if (!approx(es,gs)) diffs.push({field:`ticket ${et.idVenta}.itemsSubtotal`, expected:es, got:gs, MONEY:true});
  });
  // pTotal
  if (!approx(exp.pTotal, num(got.pTotal))) diffs.push({field:'pTotal', expected:exp.pTotal, got:num(got.pTotal), MONEY:true});
  // pMap money
  for (const n of Object.keys(exp.pMap)) {
    const g=got.pMap[n];
    if (!g){ diffs.push({field:`pMap.${n} MISSING`}); continue; }
    if (!approx(exp.pMap[n].total, num(g.total))) diffs.push({field:`pMap.${n}.total`, expected:exp.pMap[n].total, got:num(g.total), MONEY:true});
    if (exp.pMap[n].tks !== num(g.tks)) diffs.push({field:`pMap.${n}.tks`, expected:exp.pMap[n].tks, got:num(g.tks)});
  }
  // meta money
  for (const f of ['metaDiaria','comisionPct','totalCobrado','excedente','faltante','progresoPct','comisionTotal']) {
    if (!approx(exp.meta[f], num(got.meta[f]))) diffs.push({field:`meta.${f}`, expected:exp.meta[f], got:num(got.meta[f]), MONEY:true});
  }
  if (exp.meta.configurada !== got.meta.configurada) diffs.push({field:'meta.configurada', expected:exp.meta.configurada, got:got.meta.configurada});
  if (exp.meta.metaLograda !== got.meta.metaLograda) diffs.push({field:'meta.metaLograda', expected:exp.meta.metaLograda, got:got.meta.metaLograda});
  // comisionPorVendedor (money, por nombre)
  const cv = Object.fromEntries((got.meta.comisionPorVendedor||[]).map(v=>[v.nombre,v]));
  (exp.meta.comisionPorVendedor||[]).forEach(v=>{
    const g=cv[v.nombre];
    if(!g){ diffs.push({field:`comisionVend.${v.nombre} MISSING`}); return; }
    if(!approx(v.comision,num(g.comision))) diffs.push({field:`comisionVend.${v.nombre}.comision`, expected:v.comision, got:num(g.comision), MONEY:true});
    if(!approx(v.venta,num(g.venta))) diffs.push({field:`comisionVend.${v.nombre}.venta`, expected:v.venta, got:num(g.venta), MONEY:true});
    if(!approx(v.pct,num(g.pct))) diffs.push({field:`comisionVend.${v.nombre}.pct`, expected:v.pct, got:num(g.pct)});
  });
  // corrPorTipo (set per tipo)
  for (const tipo of Object.keys(exp.corrPorTipo)) {
    const e=[...exp.corrPorTipo[tipo]].sort();
    const g=[...(got.corrPorTipo[tipo]||[])].sort();
    if (JSON.stringify(e)!==JSON.stringify(g)) diffs.push({field:`corrPorTipo.${tipo}`, expected:e, got:g});
  }
  // actoresZona / vendedores (as sets)
  const setEq=(a,b)=>JSON.stringify([...(a||[])].sort())===JSON.stringify([...(b||[])].sort());
  if(!setEq(exp.actoresZona,got.actoresZona)) diffs.push({field:'actoresZona', expected:exp.actoresZona, got:got.actoresZona});
  if(!setEq(exp.vendedores,got.vendedores)) diffs.push({field:'vendedores', expected:exp.vendedores, got:got.vendedores});
  // auditorias
  for(const n of Object.keys(exp.auditorias)){
    if(num(got.auditorias[n])!==exp.auditorias[n]) diffs.push({field:`auditorias.${n}`, expected:exp.auditorias[n], got:got.auditorias[n]});
  }
  if(num(exp.metaAudit)!==num(got.metaAudit)) diffs.push({field:'metaAudit', expected:exp.metaAudit, got:got.metaAudit});
  // caja string fields
  for(const f of ['cajero','estacion','zona','fechaApert','fechaDia','estado','fechaCierre']){
    if(String(exp.caja[f])!==String(got.caja[f])) diffs.push({field:`caja.${f}`, expected:exp.caja[f], got:got.caja[f]});
  }
  if(!approx(exp.caja.montoInicial,num(got.caja.montoInicial))) diffs.push({field:'caja.montoInicial', expected:exp.caja.montoInicial, got:num(got.caja.montoInicial), MONEY:true});
  return diffs;
}

(async () => {
  const c = new Client({ connectionString:url, ssl:{rejectUnauthorized:false} });
  await c.connect();
  // Selección de cajas de prueba: mezcla CERRADA/CERRADA_AUTO, con mixto/credito/extras
  const TEST = [
    'CAJA-1780316630462', // 33 ventas, mixto+credito+anulado, ZONA-02
    'CAJA-1781958203130', // 56 ventas, mixto+credito+extras
    'CAJA-1781007981727', // extras EGRESO+INGRESO_VIRTUAL
    'CAJA-1778848407996', // CERRADA_AUTO
    'CAJA-1775665213748', // CERRADA_AUTO ZONA-01
    'CAJA-1776687103396', // META LOGRADA, comision>0, reparto multi-vendedor
  ];
  let allOk=true;
  for (const idCaja of TEST) {
    const exp = await gasDatosTurno(c, idCaja);
    const rpcR = await c.query('select me.datos_turno($1) as r', [idCaja]);
    const got = rpcR.rows[0].r;
    console.log('\n══════════════════════════════════════════════');
    console.log('CAJA:', idCaja, '| estado:', exp.data?.caja?.estado, '| zona:', exp.data?.caja?.zona);
    if (!exp.ok || !got.ok) { console.log('  ok mismatch exp=',exp.ok,'got=',got.ok); allOk=false; continue; }
    const t = got.data.totales;
    console.log('  MONEY (RPC):',
      `efe=${t.efectivo} vir=${t.virtual} cred=${t.credito} anul=${t.anulados} sinCob=${t.sinCobrar}`);
    console.log('              ',
      `montoFinalEfe=${t.montoFinalEfe} virtualFinal=${t.virtualFinal} extIng=${t.extrasIngreso} extEgr=${t.extrasEgreso} extIngV=${t.extrasIngresoVirtual} extEgrV=${t.extrasEgresoVirtual}`);
    console.log('  MONEY (GAS):',
      `efe=${exp.data.totales.efectivo} vir=${exp.data.totales.virtual} cred=${exp.data.totales.credito} anul=${exp.data.totales.anulados} sinCob=${exp.data.totales.sinCobrar}`);
    console.log('              ',
      `montoFinalEfe=${exp.data.totales.montoFinalEfe} virtualFinal=${exp.data.totales.virtualFinal}`);
    console.log('  meta:', `metaLograda=${got.data.meta.metaLograda} totalCobrado=${got.data.meta.totalCobrado} comisionTotal=${got.data.meta.comisionTotal}`);
    const diffs = compareData(exp.data, got.data);
    if (diffs.length === 0) {
      console.log('  ✅ EXACT MATCH (todos los campos, incluido dinero)');
    } else {
      const money = diffs.filter(d=>d.MONEY);
      allOk=false;
      console.log(`  ❌ ${diffs.length} diffs (${money.length} de DINERO):`);
      diffs.forEach(d=>console.log('     ', JSON.stringify(d)));
    }
  }
  await c.end();
  console.log('\n══════════════════════════════════════════════');
  console.log(allOk ? '✅✅✅ TODAS LAS CAJAS: MONEY-EXACT MATCH' : '❌ HUBO DIFERENCIAS — revisar arriba');
  process.exit(allOk?0:1);
})().catch(e=>{ console.error('FATAL', e); process.exit(2); });
