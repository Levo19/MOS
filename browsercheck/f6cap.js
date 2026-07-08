// f6cap.js — driver de captura F6 para el Panel PS.
// Navega los 6 módulos en un viewport dado, mockea Supabase con data fake,
// y guarda screenshots f6-<modulo>-<vp>.png en la carpeta browsercheck.
const { chromium } = require('playwright');
const path = require('path');

const OUT = path.resolve(__dirname.includes('browsercheck') ? __dirname : 'C:/Users/ISO/ProyectoMOS/browsercheck');
const URL = 'http://localhost:8147/index.html';

const VPS = {
  mobile:  { width: 375,  height: 812  },
  tablet:  { width: 834,  height: 1112 },
  desktop: { width: 1440, height: 900  },
};

const today = new Date().toISOString().slice(0,10);

// ---- Mock de respuestas Supabase por RPC / REST ----
function rpcMock(fn, body) {
  switch (fn) {
    case 'get_kpis_ops': return { pax_total: 148, ingresos_operador: 4820.5, deuda_comisionados: 320, pendiente_aliados: 150, semaforo: 'verde', ops_total: 12, ingresos_operador_hoy: 4820.5 };
    case 'get_historico': return Array.from({length:14}).map((_,i)=>({ fecha:`2026-06-${String(i+1).padStart(2,'0')}`, ingresos_operador: 3000+i*180, pax_total: 90+i*4, deuda_comisionados: i*30 }));
    case 'get_lanchas_fechas': return [{ fecha: today, pax_total: 148, ingresos_operador: 4820, semaforo:'verde' },{ fecha:'2026-07-04', pax_total: 120, ingresos_operador: 3900, semaforo:'ambar' }];
    case 'get_lanchas_dia': return {
      kpis: { pax_total: 148, ingresos_operador: 4820.5, deuda_comisionados: 320, semaforo:'verde' },
      operaciones: Array.from({length:5}).map((_,i)=>({ id_operacion:'OP-'+i, embarcacion:'Estrella de Paracas '+(i+1), operador:'Juan Pérez Comisionado', hora:'0'+(8+i)+':30', pax_total: 20+i*3, ingresos: 800+i*120, estado:'Cerrada', semaforo:'verde', comisionados:[{nombre:'Carlos', pax:8},{nombre:'Ana', pax:6}] })),
      pases: Array.from({length:3}).map((_,i)=>({ id_mov:'M-'+i, nombre_contacto:'Agencia Turismo Paracas Sur '+(i+1), nombre_contacto_pase:'Aliado Nauticos del Litoral', tipo: i%2?'PaseIn':'PaseOut', cant_pax: 4+i, monto_total: 200+i*50, estado:'Activo' })),
      caja: Array.from({length:4}).map((_,i)=>({ id_mov:'C-'+i, categoria: ['Cobro','Pago Agencia','Cobro','Adelanto'][i], nombre_contacto:'Contacto Comercial '+(i+1), monto: 150+i*40, metodo_pago:'Efectivo', hora:'1'+i+':00', estado: i===3?'Cancelado':'Activo' }))
    };
    case 'get_caja_feed': return Array.from({length:6}).map((_,i)=>({ id_mov:'CF-'+i, fecha: today, categoria:['Cobro','Pago Agencia','Adelanto','Cobro','Cobro','Pago Comisionado'][i], nombre_contacto:'Contacto muy largo para probar truncado '+(i+1), monto: 120+i*35, metodo_pago: i%2?'Yape':'Efectivo', operador:'PS', estado: i===5?'Cancelado':'Activo' }));
    case 'get_balance_agencias': return Array.from({length:4}).map((_,i)=>({ id_contacto:'A-'+i, nombre:'Agencia Internacional de Turismo '+(i+1), me_debe: 800+i*120, le_debo: i*90, saldo: 800+i*120-i*90 }));
    case 'get_balance_aliados': return Array.from({length:3}).map((_,i)=>({ id_contacto:'AL-'+i, nombre:'Aliado Náutico '+(i+1), pase_in: 20+i*4, pase_out: 10+i*2, neto: 10+i*2 }));
    case 'admin_list_saldos_iniciales': return [];
    // Hotel
    case 'listar_comprobantes': return Array.from({length:5}).map((_,i)=>({ id:'CPE-'+i, tipo: i%2?'Factura':'Boleta', serie:'B001', numero: 100+i, cliente_nombre:'Cliente Empresarial S.A.C. sucursal '+(i+1), total: 118+i*50, estado:['ACEPTADO','PENDIENTE','ACEPTADO','ANULADO','ACEPTADO'][i], fecha: today }));
    case 'get_facturacion_muelle': return { on: true };
    case 'get_facturacion_config': return { ruta:'', token:'', modo:'demo', activo:false, serie_boleta:'B001', serie_factura:'F001' };
    case 'listar_servicios': return Array.from({length:4}).map((_,i)=>({ id:'S-'+i, nombre:'Servicio turístico '+(i+1), precio: 50+i*20, unidad:'NIU', activo:true }));
    case 'listar_solicitudes_anulacion': return [];
    case 'balance_tributos': return { igv_ventas: 1200, igv_compras: 400, igv_pagar: 800, renta: 300 };
    case 'proyeccion_renta': return { anio: 2026, meses: [] };
    case 'listar_compras': return [];
    case 'listar_zarpes_pendientes': return [];
    case 'listar_paquete_zarpe': return [];
    default: return null;
  }
}
function restMock(pathq) {
  if (pathq.startsWith('contactos')) return Array.from({length:6}).map((_,i)=>({ id:'C-'+i, nombre:'Contacto Comercial de Paracas número '+(i+1), tipo: ['agencia','aliado','comisionado','cliente','agencia','aliado'][i], precio_defecto: 20+i*5 }));
  if (pathq.startsWith('embarcaciones')) return Array.from({length:4}).map((_,i)=>({ id:'E-'+i, nombre:'Estrella de Paracas '+(i+1), capacidad_pax: 30+i*4, matricula:'PA-'+(1000+i) }));
  if (pathq.startsWith('personal')) return Array.from({length:5}).map((_,i)=>({ id:'P-'+i, nombre:'Trabajador Paracas '+(i+1), rol:['Operador','Comisionado','Cajero','Admin','Operador'][i], tarifa_fija: i*50, estado:'activo' }));
  if (pathq.startsWith('impuestos')) return Array.from({length:2}).map((_,i)=>({ id:'I-'+i, nombre:'Impuesto '+(i+1), monto: 10+i*5 }));
  if (pathq.startsWith('hotel_habitaciones')) return [];
  return [];
}

const NAV_ORDER = ['dashboard','lanchas','hotel','finanzas','catalogos','facturacion'];
const NAV_LABELS = { dashboard:'Inicio', lanchas:'Lanchas', hotel:'Hotel', finanzas:'Finanzas', catalogos:'Catálogo', facturacion:'Facturación' };

(async () => {
  const vpName = process.argv[2] || 'mobile';
  const only = process.argv[3]; // opcional: un solo módulo
  const vp = VPS[vpName];
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: vp, deviceScaleFactor: 2, serviceWorkers: 'block' });
  const page = await ctx.newPage();

  await page.addInitScript(() => {
    const ls = {
      ps_session: JSON.stringify({ id:'P-1', nombre:'Admin', rol:'Administrador', loginAt: 1751000000000 }),
      ps_api_url: 'http://localhost:8147/noapi',
      ps_supa_auth: JSON.stringify({ access_token:'fake.jwt.tok', refresh_token:'fakeref', expires_at: 4102444800, expires_in: 3600, token_type:'bearer', user:{ id:'00000000-0000-0000-0000-000000000001', aud:'authenticated', role:'authenticated', email:'admin@ps.local', app_metadata:{}, user_metadata:{} } })
    };
    for (const k in ls) localStorage.setItem(k, ls[k]);
  });

  // Interceptar Supabase
  await page.route('**/*', route => {
    const url = route.request().url();
    if (url.includes('.supabase.co/rest/v1/rpc/')) {
      const fn = url.split('/rpc/')[1].split('?')[0];
      let body = {}; try { body = JSON.parse(route.request().postData()||'{}'); } catch(_){}
      const data = rpcMock(fn, body);
      return route.fulfill({ status: 200, contentType:'application/json', headers:{'access-control-allow-origin':'*'}, body: JSON.stringify(data) });
    }
    if (url.includes('.supabase.co/rest/v1/')) {
      const pathq = url.split('/rest/v1/')[1];
      const data = restMock(pathq);
      return route.fulfill({ status: 200, contentType:'application/json', headers:{'access-control-allow-origin':'*'}, body: JSON.stringify(data) });
    }
    if (url.includes('.supabase.co/auth/')) {
      return route.fulfill({ status: 200, contentType:'application/json', headers:{'access-control-allow-origin':'*'}, body: JSON.stringify({}) });
    }
    return route.continue();
  });

  await page.goto(URL, { waitUntil:'domcontentloaded' });
  await page.waitForTimeout(4500);

  const isLandscape = vp.width >= 640 && vp.width > vp.height;
  const mods = only ? [only] : NAV_ORDER;

  for (const m of mods) {
    // click nav item / sidebar item by visible label
    const label = NAV_LABELS[m];
    const sel = isLandscape ? '.sidebar-item' : '.nav-item';
    try {
      await page.evaluate(({sel,label}) => {
        const btns = [...document.querySelectorAll(sel)];
        const b = btns.find(x => x.textContent.trim().includes(label));
        if (b) b.click();
      }, {sel,label});
    } catch(e){ console.log('nav err', m, e.message); }
    await page.waitForTimeout(1800);
    const file = path.join(OUT, `f6-${m}-${vpName}.png`);
    await page.screenshot({ path: file, fullPage: false });
    console.log('shot', file);
  }

  await browser.close();
})();
