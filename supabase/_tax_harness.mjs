// Arnés visual: extrae el CSS [640] del index + el renderer de app.js y los monta con
// datos REALES de mos.taxonomia_config para screenshotear sin login.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const data = (await c.query(`select mos.taxonomia_config('{}'::jsonb) r`)).rows[0].r;
await c.end();
const idx = fs.readFileSync('../index.html', 'utf8');
const css = idx.match(/\/\* ── \[640\] Taxonomía IA[\s\S]*?prefers-reduced-motion:reduce\)\{\.cfgpanel \.taxsubs\{animation:none\}\.cfgpanel \.taxbar i\{transition:none\}\}/)[0];
const app = fs.readFileSync('../js/app.js', 'utf8');
const fn = app.match(/function _taxSubHit[\s\S]*?\n  function _renderCategoriasCards[\s\S]*?\n  }\n/)[0];
const emoji = app.match(/const _TAX_EMOJI = \{[^}]*\};/)[0];
const html = `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>
body{background:#070d18;font:13px system-ui;margin:0;padding:14px}
.grid2{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:12px}
.cfgpanel .catcard{background:#0b1526;border:1px solid #1c2b45;border-radius:12px;padding:13px;cursor:pointer;transition:.15s}
.cfgpanel .catcard .ct{font-size:13.5px;font-weight:800;color:#eaf1fb}
.cfgpanel .catcard .cdesc{font-size:11px;color:#9fb2ce;margin-top:4px}
.tnum{font-variant-numeric:tabular-nums}
${css}</style>
<div class="cfgpanel"><div id="catCmdBar"></div><div id="catGridContainer" class="grid2"></div></div>
<script>
const DATA=${JSON.stringify(data)};
const _escapeHtml=s=>String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/"/g,'&quot;');
const _escAttrJs=s=>encodeURIComponent(String(s));  // stub del arnés: solo evita romper el atributo
const $=id=>document.getElementById(id);
const MOS={catToggle:(c)=>{_catAbierta=(_catAbierta===c)?null:c;_renderCategoriasCards($('catGridContainer'),DATA);},catBuscar:()=>{}};
let _catQ='';let _catAbierta='ESPECIAS';
${emoji}
${fn}
_renderCategoriasCards($('catGridContainer'),DATA);
</script>`;
fs.writeFileSync('C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/tax_harness.html', html);
console.log('harness ok · cats:', data.length);
