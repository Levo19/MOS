import fs from 'fs'; import { execSync } from 'child_process';
const src = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/functions/print-adhesivo/index.ts','utf8');
const grab = (name) => { const i = src.indexOf('function ' + name + '('); let d=0, j=src.indexOf('{', i); for (let k=j;k<src.length;k++){ if(src[k]==='{')d++; else if(src[k]==='}'){d--; if(!d) return src.slice(i,k+1);} } };
fs.writeFileSync('_adh_tmp.ts', grab('wrapPlanoEtq') + '\ntype Tok = { tok: string; hl: boolean; w: number };\nexport { wrapPlanoEtq };');
execSync('npx -y esbuild _adh_tmp.ts --format=esm --outfile=_adh_tmp.mjs --log-level=error');
console.log(fs.readFileSync('_adh_tmp.mjs','utf8'));
const { wrapPlanoEtq } = await import('./_adh_tmp.mjs?x=' + Date.now());
console.log(JSON.stringify(wrapPlanoEtq('CLAVO DE OLOR INDONESIO PREMIUM GRANEL'.split(' '), 12, 2)));
