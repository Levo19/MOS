// [Tributario] La alerta de comprobantes que NO llegaron a SUNAT.
//
// La franja de alerta nunca se encendió con 56 comprobantes trabados: contaba como error solo
// los estados 'RECHAZADO_SUNAT' y 'ERROR', que no existen en los datos — cuando NubeFact
// rechaza, la venta se queda en PENDIENTE. Así que cpeErrores daba 0 siempre.
//
// Esta prueba comprueba las dos mitades:
//   · el clasificador del front reconoce el comprobante trabado y lo separa de los que están
//     en camino (una factura se acepta en segundos; una boleta viaja en el resumen diario)
//   · el criterio del front y el del backend son EL MISMO. Si la pantalla y el push cuentan
//     distinto, uno de los dos miente y no se sabe cuál.
import fs from 'fs';

const APP = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js';
const HTML = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/index.html';
const src = fs.readFileSync(APP, 'utf8');
const html = fs.readFileSync(HTML, 'utf8');

const ok = [], bad = [];
const T = (n, c, x) => { (c ? ok : bad).push(n); console.log((c ? '  OK  ' : '  --  ') + n + (x != null && x !== '' ? '  ·  ' + x : '')); };

// ── el clasificador, extraído y ejecutado de verdad ──
const ini = src.indexOf('function _tribClasifCPE(c) {');
const fin = src.indexOf('\n  }', ini) + 4;
const clasif = new Function('return (' + src.slice(ini, fin).replace('function _tribClasifCPE', 'function') + ')')();

const hace = (min) => new Date(Date.now() - min * 60000).toISOString();
const casos = [
  ['factura trabada hace 2 h',        { tipo: 'FACTURA', fecha: hace(120), nfEstado: 'PENDIENTE', aceptadoNubefact: false, aceptadoSunat: false }, 'TRABADO'],
  ['factura recién emitida (5 min)',  { tipo: 'FACTURA', fecha: hace(5),   nfEstado: 'PENDIENTE', aceptadoNubefact: false, aceptadoSunat: false }, 'PENDIENTE'],
  ['boleta de hoy, en el resumen',    { tipo: 'BOLETA',  fecha: hace(120), nfEstado: 'PENDIENTE', aceptadoNubefact: true,  aceptadoSunat: false }, 'PENDIENTE'],
  ['boleta de hace 3 días sin llegar',{ tipo: 'BOLETA',  fecha: hace(4320),nfEstado: 'PENDIENTE', aceptadoNubefact: false, aceptadoSunat: false }, 'TRABADO'],
  ['boleta de hace 3 h sin llegar',   { tipo: 'BOLETA',  fecha: hace(180), nfEstado: 'PENDIENTE', aceptadoNubefact: false, aceptadoSunat: false }, 'PENDIENTE'],
  ['aceptada por SUNAT',              { tipo: 'FACTURA', fecha: hace(4320),nfEstado: 'EMITIDO',   aceptadoNubefact: true,  aceptadoSunat: true  }, 'ACEPTADO'],
  ['rechazada por SUNAT',             { tipo: 'FACTURA', fecha: hace(60),  nfEstado: 'RECHAZADO', aceptadoNubefact: true,  aceptadoSunat: false }, 'RECHAZADO'],
  ['dada de baja',                    { tipo: 'FACTURA', fecha: hace(60),  nfEstado: 'BAJA_ACEPTADA', aceptadoNubefact: true, aceptadoSunat: false }, 'BAJA'],
];
casos.forEach(([n, c, esperado]) => {
  const da = clasif(c);
  T(n + ' → ' + esperado, da === esperado, da === esperado ? '' : 'dio ' + da);
});

// ── el mismo criterio a los dos lados ──
const sql = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/867_tributario_cuenta_los_errores_reales.sql', 'utf8');
T('backend y front usan la misma ventana de factura (20 min)',
  /then 20 else/.test(sql) && /20 \* 60000/.test(src));
T('backend y front usan la misma ventana de boleta (25 h)',
  /else 1500 end/.test(sql) && /25 \* 3600000/.test(src));
// Contra la función VIVA, no contra el archivo: el .sql contiene el texto viejo adentro del
// replace() — es el patrón de búsqueda, tiene que estar ahí. Mirar el archivo daba un falso
// negativo. Lo que decide es qué hay corriendo en la base.
const pg = (await import('pg')).default;
const cli = new pg.Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim() });
await cli.connect();
const viva = (await cli.query("select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='me' and p.proname='tributario_ventas_mes'")).rows[0].d;
T('la función VIVA ya no cuenta estados que no existen',
  !/in \('RECHAZADO_SUNAT','ERROR'\)\)\s+as cpe_errores/.test(viva));
T('la función VIVA marca error lo que no llegó a NubeFact',
  /coalesce\(v\.nf_hash,''\) = ''/.test(viva) && /then 20 else 1500 end/.test(viva));
const cnt = (await cli.query('select me.tributario_ventas_mes(8,2026) r')).rows[0].r;
console.log('     en vivo: errores=' + cnt.cpeErrores + ' pendientes=' + cnt.cpePendientes + ' emitidos=' + cnt.cpeEmitidos);
await cli.end();

// ── que se vea y que lleve a algún lado ──
T('la tarjeta de IGV en contra se marca en alerta',
  /_cardIGV\.classList\.toggle\('trib-stat-alerta'/.test(src) && /\.trib-stat-alerta \{/.test(html));
T('la franja lleva a los comprobantes trabados, no a las guías',
  /tribAbrirIGVEmitido\('TRABADO'\)/.test(src));
T('el filtro inicial llega hasta la lista',
  /async function tribAbrirIGVEmitido\(filtroInicial\)/.test(src)
  && /_tribCPEFiltro\.estado = filtroInicial \|\| 'TODOS'/.test(src));
T('hay un chip para filtrarlos', /mk\('TRABADO',/.test(src));
T('el estado se pinta en rojo, no en gris', /TRABADO:\s*\['error'/.test(src));
T('la animación respeta prefers-reduced-motion',
  /prefers-reduced-motion: reduce\) \{ \.trib-stat-alerta \{ animation: none/.test(html));

console.log('\n  ' + ok.length + ' OK   ' + bad.length + ' fallos');
process.exit(bad.length ? 1 : 0);
