// [print-adhesivo] membrete andamio: nombres largos en hasta 3 líneas, nunca encimado ni fuera del adhesivo.
// Funciones REALES del Edge (TS → JS con esbuild); el escalón se decide igual que en buildTSPLMembreteWh.
import fs from 'fs'; import { execSync } from 'child_process';
const src = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/functions/print-adhesivo/index.ts','utf8');
const grab = (name) => { const i = src.indexOf('function ' + name + '('); let d=0, j=src.indexOf('{', i); for (let k=j;k<src.length;k++){ if(src[k]==='{')d++; else if(src[k]==='}'){d--; if(!d) return src.slice(i,k+1);} } };
fs.writeFileSync('_adh_tmp.ts', ['normalizeEtq','detectHighlightsEtq','fontWidthEtq','wrapTokensEtq','wrapPlanoEtq'].map(grab).join('\n') + '\ntype Tok = { tok: string; hl: boolean; w: number };\nexport { normalizeEtq, detectHighlightsEtq, wrapTokensEtq, wrapPlanoEtq };');
execSync('npx -y esbuild _adh_tmp.ts --format=esm --outfile=_adh_tmp.mjs --log-level=error');
const m = await import('./_adh_tmp.mjs?x=' + Date.now());
// el mismo bloque de decisión que el Edge (copiado a mano; si cambia allá, cambiar acá)
const bloque = src.slice(src.indexOf("let modo: 'f3' | 'f2x2' | 'f2x3' = 'f3';"), src.indexOf("const header = ['SIZE 50 mm,25 mm'", src.indexOf("let modo: 'f3'")));
const plan = (desc, allEnv) => {
  const tokens = m.normalizeEtq(desc).split(/\s+/); const highlights = m.detectHighlightsEtq(tokens, allEnv || []);
  let lines = m.wrapTokensEtq(tokens, highlights); const _SP=8,_MAXW=370; const _anchoLinea=(l)=>l.reduce((a,o,i)=>a+o.w+(i?_SP:0),0);
  let modo='f3';
  if (lines.length>2 || lines.some((l)=>_anchoLinea(l)>_MAXW)) { const l2=m.wrapPlanoEtq(tokens,12,2); if(l2){lines=l2;modo='f2x2';} else { lines=m.wrapPlanoEtq(tokens,12,3)||m.wrapPlanoEtq(tokens,12,3,true); modo='f2x3'; } }
  const LINE_H = modo==='f3'?38:(modo==='f2x2'?30:21); const startY = modo==='f2x2'?56:(modo==='f2x3'?44:46);
  const ys = lines.map((_,i)=>startY+i*LINE_H); const alto = modo==='f3' ? (lines[lines.length-1].some(o=>o.hl)?32:28) : 20; const fin = ys[ys.length-1]+alto;
  return { modo, lineas: lines.map(l=>l.map(o=>o.tok).join(' ')), anchos: lines.map(_anchoLinea), fin };
};
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  OK  ':'  --  ')+n+(x?'  ·  '+x:''));};
T('el bloque de escalones existe en el Edge tal cual', /wrapPlanoEtq\(tokens, 12, 2\)/.test(bloque) && /wrapPlanoEtq\(tokens, 12, 3, true\)/.test(bloque));
// catálogo hermano: otros "CLAVO DE OLOR ..." hacen que INDONESIO y PREMIUM sean tokens distintivos (highlight, fuente 4)
const hermanos = ['CLAVO DE OLOR ENTERO 100GR', 'CLAVO DE OLOR INDONESIO 100GR', 'CLAVO DE OLOR MOLIDO 50GR'].map(s=>m.normalizeEtq(s).split(/\s+/));
const casos = [['CLAVO DE OLOR INDONESIO PREMIUM GRANEL', hermanos], ['AJINOMOTO SAZONADOR GLUTAMATO 9GR SOBRE', []], ['OREGANO ENTERO GRANEL EXO', []], ['SAL', []],
               ['MCCOLINS FILTRANTE TE CANELA Y CLAVO 100UN CAJA', []], ['PIMIENTA NEGRA ENTERA IMPORTADA PREMIUM SELECCIONADA ESPECIAL GOURMET GRANEL 1KG BOLSA DOYPACK EDICION LIMITADA COSECHA 2026', []]];
for (const [c, env] of casos) {
  const r = plan(c, env); console.log('     ' + c + ' → ' + r.modo + ' ' + JSON.stringify(r.lineas) + ' anchos ' + JSON.stringify(r.anchos) + ' fin y=' + r.fin);
  T('«' + c.slice(0,28) + '…» ≤3 líneas, ninguna > 370 dots, sin pisar el barcode', r.lineas.length<=3 && r.anchos.every(a=>a<=370) && (r.modo==='f3' ? r.fin<=116 /* layout histórico de 2 líneas */ : r.fin<=108));
}
const clavo = plan('CLAVO DE OLOR INDONESIO PREMIUM GRANEL', hermanos);
T('el clavo indonesio con sus hermanos (caso del dueño) baja de escalón y ya no desborda', clavo.modo!=='f3' && clavo.anchos.every(a=>a<=370));
const largo = plan('PIMIENTA NEGRA ENTERA IMPORTADA PREMIUM SELECCIONADA ESPECIAL GOURMET GRANEL 1KG BOLSA DOYPACK EDICION LIMITADA COSECHA 2026', []);
T('un nombre absurdo se recorta con "..." en la 3ª línea en vez de desbordar', largo.lineas.length===3 && /\.\.\.$/.test(largo.lineas[2]));
fs.unlinkSync('_adh_tmp.ts'); fs.unlinkSync('_adh_tmp.mjs');
console.log('\n  '+ok.length+' OK   '+bad.length+' fallos'); process.exit(bad.length?1:0);
