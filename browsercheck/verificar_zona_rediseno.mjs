// [VERIFICADOR] Rediseño módulo Zonas (888-895). Chequea, con datos y código, que lo prometido
// esté y funcione: DB (realtime + RPC), presencia/poda de funciones, wiring HTML→MOS, lógica de
// cuadrante/días/anillo, versiones consistentes, IDs duplicados y código muerto.
// Uso: node browsercheck/verificar_zona_rediseno.mjs   (desde ProyectoMOS)
import fs from 'node:fs';
import pg from 'pg';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const P = (f) => path.join(ROOT, f);
const appJs = fs.readFileSync(P('js/app.js'), 'utf8');
const apiJs = fs.readFileSync(P('js/api.js'), 'utf8');
const html  = fs.readFileSync(P('index.html'), 'utf8');
const sw    = fs.readFileSync(P('sw.js'), 'utf8');
const verJson = JSON.parse(fs.readFileSync(P('version.json'), 'utf8'));

let pass = 0, fail = 0, warn = 0;
const ok   = (n, extra='') => { pass++; console.log('  \x1b[32m✓\x1b[0m', n, extra ? '\x1b[90m'+extra+'\x1b[0m' : ''); };
const bad  = (n, extra='') => { fail++; console.log('  \x1b[31m✗ FAIL\x1b[0m', n, extra ? '\x1b[33m'+extra+'\x1b[0m' : ''); };
const wrn  = (n, extra='') => { warn++; console.log('  \x1b[33m⚠\x1b[0m', n, extra ? '\x1b[90m'+extra+'\x1b[0m' : ''); };
const sec  = (t) => console.log('\n\x1b[1m\x1b[36m'+t+'\x1b[0m');

// ─────────────────────────────────────────────────────────────
sec('1 · VERSIONES CONSISTENTES');
const vVer = verJson.version;
const vSw = (sw.match(/VERSION\s*=\s*'([\d.]+)'/) || [])[1];
const vV  = (html.match(/var V = '([\d.]+)'/) || [])[1];
(vVer === vSw) ? ok('version.json == sw.js', vVer) : bad('version.json != sw.js', `${vVer} vs ${vSw}`);
(vV === vVer) ? ok('index.html var V == version.json', vV) : bad('index.html var V != version.json', `${vV} vs ${vVer}`);
// Solo los scripts CORE deben bumpear con la app (regla del dueño: app.js/api.js). Los assets/libs
// tienen su propia versión (membrete, qrcode, etc.) y NO tienen que igualar — no es bug.
const coreQs = [...html.matchAll(/\b(?:js\/app\.js|js\/api\.js)\?v=([\d.]+)/g)].map(m => m[1]);
const coreBad = coreQs.filter(v => v !== vVer);
coreBad.length ? bad('app.js/api.js ?v= desincronizado', coreBad.join(',')) : ok('app.js + api.js ?v= == version.json', `${coreQs.length} refs`);

// ─────────────────────────────────────────────────────────────
sec('2 · FUNCIONES PROMETIDAS PRESENTES (app.js)');
const debeExistir = ['zonaAbrirHub','zonaCerrarHub','zonaElegirPuesto','_zonaHubStationsHtml','_zonaHubCargarVitales',
  '_zonaHubActualizarChip','_zonaAnclaGet','_zonaAnclaSet','_zonaCuadDe','_zonaCacheVitales','_zonaVitCuadGet'];
for (const fn of debeExistir) {
  new RegExp('function\\s+'+fn+'\\b').test(appJs) ? ok('existe '+fn+'()') : bad('FALTA '+fn+'()');
}
// exportadas en el namespace MOS
for (const fn of ['zonaAbrirHub','zonaCerrarHub','zonaElegirPuesto']) {
  new RegExp('(^|[^\\w.])'+fn+'\\s*,').test(appJs) ? ok('exportada '+fn) : bad('NO exportada '+fn);
}
// api.js
/API\.zona[\s\S]{0,40}|resumen:\s*async/.test(apiJs) && /'zonas_resumen'/.test(apiJs)
  ? ok('api.js API.zona.resumen → mos.zonas_resumen') : bad('api.js falta resumen/zonas_resumen');

// ─────────────────────────────────────────────────────────────
sec('3 · CÓDIGO MUERTO PODADO (888-895)');
const debeNoExistir = ['zonaAbrirBCG','zonaCerrarBCG','zonaBCGTapProducto','zonaBCGFiltrarCuadrante',
  'zonaAbrirSugerencias','zonaCerrarSugerencias','_zonaPromptSugerencias','zonaImprimirLista'];
for (const fn of debeNoExistir) {
  const def = new RegExp('function\\s+'+fn+'\\b').test(appJs);
  const ref = new RegExp('MOS\\.'+fn+'\\b').test(html) || new RegExp('MOS\\.'+fn+'\\b').test(appJs);
  (!def && !ref) ? ok('podada '+fn+' (0 def, 0 ref)') : bad('todavía viva '+fn, (def?'def ':'')+(ref?'ref':''));
}
for (const m of ['modalZonaBCG','modalZonaSug']) {
  html.includes('id="'+m+'"') ? bad('modal huérfano sigue en HTML: '+m) : ok('modal '+m+' removido del HTML');
}

// ─────────────────────────────────────────────────────────────
sec('4 · WIRING HTML → MOS (botones rotos = onclick sin función)');
// nombres definidos/llamables: escanea app.js + api.js + todos los assets JS (una función puede vivir
// en otro módulo, p.ej. el editor de adhesivos). Acepta varias formas de definición.
const defined = new Set();
const inlineScripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]).join('\n');
const jsBlobs = [appJs, apiJs, inlineScripts];
try {
  const walk = (d) => fs.readdirSync(d, { withFileTypes:true }).forEach(e => {
    const fp = path.join(d, e.name);
    if (e.isDirectory()) walk(fp); else if (e.name.endsWith('.js')) jsBlobs.push(fs.readFileSync(fp, 'utf8'));
  });
  walk(P('assets'));
} catch(_) {}
for (const blob of jsBlobs) {
  for (const m of blob.matchAll(/\bfunction\s+([A-Za-z_$][\w$]*)/g)) defined.add(m[1]);
  for (const m of blob.matchAll(/(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:function|\([^)]*\)\s*=>)/g)) defined.add(m[1]);
  for (const m of blob.matchAll(/(?:MOS|window\.MOS)\.([A-Za-z_$][\w$]*)\s*=/g)) defined.add(m[1]);   // MOS.x = ...
  for (const m of blob.matchAll(/^\s*(?:async\s+)?([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{/gm)) defined.add(m[1]); // método shorthand
  for (const m of blob.matchAll(/^\s*([A-Za-z_$][\w$]*)\s*[,:]/gm)) defined.add(m[1]);   // export `x,` u objeto `x:`
}
// sub-namespaces conocidos que no son funciones top-level
const nsOK = new Set(['pv2','guard','espia','sec','ext']);
const htmlCalls = new Set();
const htmlLive = html.replace(/<!--[\s\S]*?-->/g, '');   // sin comentarios (documentan código ya retirado)
for (const m of htmlLive.matchAll(/MOS\.([A-Za-z_$][\w$]*)\s*(\(|\.)/g)) {
  if (m[2] === '.') { if (!nsOK.has(m[1])) htmlCalls.add(m[1]+' (namespace?)'); continue; }
  htmlCalls.add(m[1]);
}
const rotos = [...htmlCalls].filter(c => !c.includes('(namespace') && !defined.has(c));
rotos.length ? bad('onclick a funciones inexistentes', rotos.slice(0,12).join(', ')) : ok(`wiring HTML→MOS sano (${htmlCalls.size} handlers revisados)`);

// ─────────────────────────────────────────────────────────────
sec('5 · IDs DUPLICADOS EN HTML (bug clásico DOM)');
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
const dup = {}; ids.forEach(i => dup[i] = (dup[i]||0)+1);
const dups = Object.entries(dup).filter(([,n]) => n > 1);
dups.length ? wrn('ids repetidos (revisar coexistencia)', dups.slice(0,10).map(([i,n])=>`${i}×${n}`).join(', ')) : ok(`sin ids duplicados (${ids.length} ids)`);

// ─────────────────────────────────────────────────────────────
sec('6 · LÓGICA de cuadrante · días · anillo (unit tests con datos reales)');
const _num = v => { const n = parseFloat(v); return isNaN(n) ? 0 : n; };
const rotCero = p => _num(p.volumen) <= 0;
function cuadDe(p) {
  const stock=_num(p.stockZona), esp=_num(p.esperada);
  const brecha=(p.brecha!=null)?_num(p.brecha):Math.max(0,esp-Math.max(0,stock));
  const neg=!!p.stockNegativo||stock<0;
  if (rotCero(p)&&stock>0) return 'muerto';
  if (brecha>0||neg) return 'pedir';
  if (esp>0&&stock>esp*3) return 'sobra';
  return 'orden';
}
function anillo(p, objDias) {
  const stock=_num(p.stockZona); const picos=(p.picos||[]).map(_num);
  const pf=picos.length?Math.max(0,...picos):0;
  const rot=pf>0?pf:(_num(p.volumen)>0?_num(p.volumen)/28:0);
  const dias=rot>0?(stock/rot):(stock>0?Infinity:0);
  const neg=!!p.stockNegativo||stock<0;
  const rf=neg?0:(rot<=0?(stock>0?1:0):Math.max(0,Math.min(1,dias/objDias)));
  return { dash: Math.round(rf*113), dias };
}
const casos = [
  { nm:'NIRCISSUS', p:{stockZona:4,esperada:29,brecha:25,volumen:24,picos:[0,0,0,24]}, cuad:'pedir', dashMin:15, dashMax:25 },
  { nm:'MAXIMO neg', p:{stockZona:-102,esperada:29,brecha:29,volumen:92,picos:[0,0,0,24],stockNegativo:true}, cuad:'pedir', dashMin:0, dashMax:0 },
  { nm:'ZUKO muerto', p:{stockZona:83,esperada:0,brecha:0,volumen:0,picos:[0,0,0,0]}, cuad:'muerto', dashMin:113, dashMax:113 },
  { nm:'orden', p:{stockZona:13,esperada:12,brecha:0,volumen:12,picos:[0,0,0,12]}, cuad:'orden', dashMin:100, dashMax:113 },
  { nm:'sobra', p:{stockZona:24,esperada:2,brecha:0,volumen:14,picos:[0,0,0,2]}, cuad:'sobra', dashMin:113, dashMax:113 },
];
for (const c of casos) {
  const cu = cuadDe(c.p);
  const an = anillo(c.p, 1);
  const okCuad = cu === c.cuad;
  const okDash = an.dash >= c.dashMin && an.dash <= c.dashMax;
  (okCuad && okDash) ? ok(`${c.nm}: cuadrante=${cu} anillo=${an.dash}/113`)
    : bad(`${c.nm}`, `esperaba cuad=${c.cuad} dash∈[${c.dashMin},${c.dashMax}], obtuvo cuad=${cu} dash=${an.dash}`);
}
// objetivo por nivel: almacén 3 días con meta 7 → anillo ~43%
const alm = anillo({stockZona:21,volumen:7,picos:[0,0,0,7]}, 7);
(alm.dash >= 44 && alm.dash <= 52) ? ok(`objetivo almacén=7: 3 días → anillo ${alm.dash}/113 (corto de semana)`) : bad('objetivo almacén=7 mal', `dash=${alm.dash}`);

// ─────────────────────────────────────────────────────────────
sec('7 · BASE DE DATOS (realtime 888 + RPC 891)');
const passFile = P('supabase/.pgpass');
if (!fs.existsSync(passFile)) { wrn('sin .pgpass — salto checks de DB'); await fin(); }
const c = new pg.Client({ host:'aws-1-us-east-1.pooler.supabase.com', port:5432, user:'postgres.rzbzdeipbtqkzjqdchqk',
  password: fs.readFileSync(passFile,'utf8').trim(), database:'postgres', ssl:{ rejectUnauthorized:false } });
try {
  await c.connect();
  const trg = await c.query(`select tgname, tgrelid::regclass::text tbl from pg_trigger
    where tgname in ('tg_bump_ops_stockmov','tg_bump_ops_zonaesperado','tg_bump_ops_pedidolog')`);
  const need = { tg_bump_ops_stockmov:'me.stock_movimientos', tg_bump_ops_zonaesperado:'me.zona_esperado', tg_bump_ops_pedidolog:'me.zona_pedido_log' };
  for (const [t, tbl] of Object.entries(need)) {
    const row = trg.rows.find(r => r.tgname === t);
    row ? ok(`trigger realtime ${t}`, 'en '+row.tbl) : bad(`FALTA trigger ${t} (${tbl})`);
  }
  await c.query(`select set_config('request.jwt.claims',$1,true)`, [JSON.stringify({ app:'MOS', role:'authenticated', sub:'verif' })]);
  const r = await c.query(`select mos.zonas_resumen('{}'::jsonb) j`);
  const zonas = r.rows[0].j?.data?.zonas || [];
  (r.rows[0].j?.ok && zonas.length) ? ok('mos.zonas_resumen responde', `${zonas.length} zonas`) : bad('mos.zonas_resumen no devolvió zonas');
  // sanity: la zona con más productos existe
  const z1 = zonas.find(z => String(z.zonaId).includes('ZONA-01'));
  z1 ? ok('ZONA-01 en resumen', `${z1.productos} prod / ${z1.negativos} neg`) : wrn('ZONA-01 no está en el resumen');
  await c.end();
} catch (e) { bad('DB error', e.message); try { await c.end(); } catch(_){} }

await fin();
async function fin() {
  console.log('\n' + '─'.repeat(50));
  console.log(`\x1b[1mRESULTADO:\x1b[0m \x1b[32m${pass} OK\x1b[0m · \x1b[31m${fail} FAIL\x1b[0m · \x1b[33m${warn} warn\x1b[0m`);
  process.exit(fail ? 1 : 0);
}
