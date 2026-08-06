import fs from 'fs';
const cand = JSON.parse(fs.readFileSync('_limpieza_candidatos.json','utf8'));
const esc = s => String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/"/g,'&quot;');
cand.sort((a,b)=> (a.sku_base+a.codigo_barra).localeCompare(b.sku_base+b.codigo_barra));
let rows='';
for(const x of cand){
  rows += `<tr data-cod="${esc(x.codigo_barra)}">
<td class="cb"><input type="checkbox" checked aria-label="eliminar ${esc(x.codigo_barra)}"></td>
<td class="mono">${esc(x.codigo_barra)}</td>
<td class="nm">«${esc(x.descripcion)}»${x.estado?'':' <span class="chip off">inactivo</span>'}${x.con_ficha?' <span class="chip fic">tiene ficha IA</span>':''}</td>
<td class="mono sk">${esc(x.sku_base)}</td>
<td class="ld">${esc(x.lider_desc||'')} <span class="mono dim">${esc(x.lider_cod||'')}</span></td>
</tr>\n`;
}
const html = `<title>Limpieza: 77 canónicos mal tipados</title>
<style>
:root{--bg:#F7F6F2;--panel:#fff;--ink:#20242B;--mut:#6B7280;--line:#E3E1DA;--acc:#B4530A;--acc-soft:#FBEADC;--ok:#1A7A4A;--ok-soft:#E3F2E9;--del:#B3261E;--del-soft:#FBE4E2;--chip:#EFEDE7}
@media (prefers-color-scheme:dark){:root{--bg:#15171C;--panel:#1E2128;--ink:#E8E6E1;--mut:#9AA0AB;--line:#31353E;--acc:#E8833A;--acc-soft:#3A2A1C;--ok:#4CC38A;--ok-soft:#1B3327;--del:#F2B8B5;--del-soft:#3A2222;--chip:#2A2D35}}
:root[data-theme="dark"]{--bg:#15171C;--panel:#1E2128;--ink:#E8E6E1;--mut:#9AA0AB;--line:#31353E;--acc:#E8833A;--acc-soft:#3A2A1C;--ok:#4CC38A;--ok-soft:#1B3327;--del:#F2B8B5;--del-soft:#3A2222;--chip:#2A2D35}
:root[data-theme="light"]{--bg:#F7F6F2;--panel:#fff;--ink:#20242B;--mut:#6B7280;--line:#E3E1DA;--acc:#B4530A;--acc-soft:#FBEADC;--ok:#1A7A4A;--ok-soft:#E3F2E9;--del:#B3261E;--del-soft:#FBE4E2;--chip:#EFEDE7}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--ink);font:15px/1.5 "Segoe UI",system-ui,sans-serif;margin:0;padding:24px 14px 130px}
.wrap{max-width:1000px;margin:0 auto}
h1{font-size:1.35rem;margin:0 0 6px}
.sub{color:var(--mut);margin:0 0 14px}
.safe{background:var(--ok-soft);border-left:4px solid var(--ok);border-radius:8px;padding:10px 14px;margin:0 0 16px;font-size:.92rem}
.tools{display:flex;gap:8px;margin:0 0 10px;flex-wrap:wrap}
button{font:inherit;border:1px solid var(--line);background:var(--panel);color:var(--ink);border-radius:8px;padding:7px 14px;cursor:pointer}
button.primary{background:var(--acc);border-color:var(--acc);color:#fff;font-weight:600}
.tblwrap{overflow-x:auto;background:var(--panel);border:1px solid var(--line);border-radius:12px}
table{border-collapse:collapse;width:100%;min-width:680px}
th{font-size:.72rem;text-transform:uppercase;letter-spacing:.05em;color:var(--mut);text-align:left;padding:9px 10px;border-bottom:1.5px solid var(--line)}
td{padding:7px 10px;border-bottom:1px dashed var(--line);vertical-align:top}
tr:last-child td{border-bottom:0}
tr.keep{background:var(--ok-soft)}
tr.keep .nm::after{content:" ← SE CONSERVA";color:var(--ok);font-weight:700;font-size:.75rem}
.cb input{width:18px;height:18px;accent-color:var(--del);cursor:pointer}
.mono{font-family:Consolas,monospace;font-size:.85rem;white-space:nowrap}
.dim{color:var(--mut)}
.nm{font-weight:600}
.sk{color:var(--mut)}
.ld{font-size:.88rem}
.chip{font-size:.7rem;font-weight:700;border-radius:999px;padding:1px 8px;vertical-align:1px}
.chip.off{background:var(--chip);color:var(--mut)}
.chip.fic{background:var(--acc-soft);color:var(--acc)}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--panel);border-top:2px solid var(--line);padding:10px 14px}
.barin{max-width:1000px;margin:0 auto;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.cnt{font-weight:700}.cnt .d{color:var(--del)}.cnt .k{color:var(--ok)}
textarea{width:100%;min-height:64px;font:.82rem Consolas,monospace;background:var(--chip);color:var(--ink);border:1px solid var(--line);border-radius:8px;padding:8px;margin-top:8px;display:none}
textarea.show{display:block}
</style>
<div class="wrap">
<h1>🗑 Limpieza: 77 "canónicos" mal tipados</h1>
<p class="sub">Filas legacy PRE### con nombre basura que en realidad eran presentaciones — comparten sku con su producto real (columna "pertenece a"). <b>Todos marcados = se eliminan.</b> Desmarca lo que quieras conservar y tócame el botón de abajo para generar el JSON que me pasas a Claude.</p>
<div class="safe">✅ Seguridad verificada en BD: los 77 tienen <b>0 stock</b>, <b>0 movimientos de kardex</b>, <b>0 ventas</b> y <b>0 equivalencias</b>. Sus presentaciones y derivados hermanos NO se tocan (el líder real conserva el sku).</div>
<div class="tools">
  <button id="all">Marcar todos (eliminar)</button>
  <button id="none">Desmarcar todos (conservar)</button>
</div>
<div class="tblwrap"><table>
<thead><tr><th>🗑</th><th>Código</th><th>Nombre (basura)</th><th>SKU</th><th>Pertenece a (líder real)</th></tr></thead>
<tbody>
${rows}
</tbody></table></div>
</div>
<div class="bar"><div class="barin">
  <span class="cnt">Eliminar: <span class="d" id="nd">77</span> · Conservar: <span class="k" id="nk">0</span></span>
  <button class="primary" id="gen">Generar JSON para Claude</button>
  <button id="copy" style="display:none">Copiar</button>
  <textarea id="out" readonly aria-label="JSON de conservados"></textarea>
</div></div>
<script>
const $=s=>document.querySelector(s),$$=s=>[...document.querySelectorAll(s)];
function refresh(){let d=0,k=0;$$('tbody tr').forEach(tr=>{const c=tr.querySelector('input').checked;tr.classList.toggle('keep',!c);c?d++:k++});$('#nd').textContent=d;$('#nk').textContent=k;}
document.addEventListener('change',e=>{if(e.target.matches('input[type=checkbox]'))refresh()});
$('#all').onclick=()=>{$$('tbody input').forEach(i=>i.checked=true);refresh()};
$('#none').onclick=()=>{$$('tbody input').forEach(i=>i.checked=false);refresh()};
$('#gen').onclick=()=>{
  const conservar=$$('tbody tr').filter(tr=>!tr.querySelector('input').checked).map(tr=>tr.dataset.cod);
  const eliminar=$$('tbody tr').filter(tr=>tr.querySelector('input').checked).length;
  $('#out').value=JSON.stringify({conservar, eliminar_total:eliminar},null,1);
  $('#out').classList.add('show');$('#copy').style.display='';
};
$('#copy').onclick=async()=>{const t=$('#out');t.select();try{await navigator.clipboard.writeText(t.value);$('#copy').textContent='Copiado ✓'}catch(e){document.execCommand('copy');$('#copy').textContent='Copiado ✓'}setTimeout(()=>$('#copy').textContent='Copiar',1500)};
refresh();
</script>`;
fs.writeFileSync('C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/limpieza-canonicos.html', html);
console.log('ok', cand.length, 'filas');
