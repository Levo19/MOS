import { chromium } from 'playwright';
import fs from 'fs';

const SB='https://rzbzdeipbtqkzjqdchqk.supabase.co';
const ANON='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k';
const b64u=(o)=>Buffer.from(JSON.stringify(o)).toString('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
const JWT=b64u({alg:'HS256',typ:'JWT'})+'.'+b64u({app:'warehouseMos',role:'authenticated'})+'.x';

const system=[
 'Eres un asistente experto en leer listas/tablas de PEDIDOS de almacén y extraer SOLO los productos con la cantidad SOLICITADA (lo que hay que despachar).',
 'La lista puede venir como texto pegado, foto, captura de Excel, tabla o PDF (WhatsApp, email, ticket impreso).','',
 'REGLA DE ORO — COLUMNAS DE CANTIDAD:',
 'Muchas listas traen VARIAS columnas numéricas por producto. Ejemplo:',
 '  Producto            Solicitado   Cant.Min   Cant.Max   Stock   Precio',
 '  AJINOMOTO 1KG          15           10         40       120    12.50',
 'Debes usar SIEMPRE la cantidad SOLICITADA/PEDIDA (aquí 15) y NUNCA el mínimo, máximo, stock, precio ni el código.',
 '- Identifica la columna correcta por su encabezado: "solicitado","pedido","cantidad","cant","pedir","despachar","requerido","req","a despachar".',
 '- "min/minimo/mín" y "max/maximo/máx" son límites de reposición, NO el pedido: IGNÓRALOS.',
 '- "stock/saldo/existencia" y "precio/costo/P.U./importe" (suelen llevar decimales o S/) NO son el pedido: IGNÓRALOS.',
 '- Si NO hay encabezados claros y hay varios números, elige el que representa lo pedido; ante duda, el más plausible como pedido, NUNCA el precio ni el stock.',
 '- Si solo hay UNA cantidad por producto, úsala.','',
 'IGNORA: cabeceras de tabla, totales/subtotales, separadores (---, ===), notas y columnas de código/stock/precio/mín/máx.','',
 'POR CADA PRODUCTO devuelve:',
 '- nombre: descripción del producto en MAYÚSCULAS, limpia, sin códigos pegados',
 '- cantidad: número decimal con 1 decimal (ej: 15.0, 80.0, 0.5)',
 '- codigoVisto: opcional — si trae un código/sku al lado, ponlo (string), si no, omite el campo','',
 'RESPONDE EXCLUSIVAMENTE con JSON válido en este formato (sin markdown, sin comentarios):',
 '{"items":[{"nombre":"...","cantidad":N.N,"codigoVisto":"..."}]}'
].join('\n');

const html=`<html><body style="font-family:Arial;padding:24px;background:#fff">
<h2>PEDIDO ZONA 1 — Bodega Central</h2>
<table border="1" cellpadding="8" cellspacing="0" style="border-collapse:collapse;font-size:16px">
<tr style="background:#dbe5f1"><th>Código</th><th>Producto</th><th>Solicitado</th><th>Cant. Mín</th><th>Cant. Máx</th><th>Stock</th><th>Precio S/</th></tr>
<tr><td>7501</td><td>AJINOMOTO GLUTAMATO 1KG</td><td>15</td><td>10</td><td>40</td><td>120</td><td>12.50</td></tr>
<tr><td>3402</td><td>AJI PANCA DESVENADO KG</td><td>80</td><td>20</td><td>90</td><td>200</td><td>8.00</td></tr>
<tr><td>9910</td><td>SILLAO KIKKOMAN 1L</td><td>6</td><td>5</td><td>24</td><td>48</td><td>18.90</td></tr>
<tr><td>1205</td><td>PALILLO ENTERO 500G</td><td>25</td><td>10</td><td>50</td><td>90</td><td>4.50</td></tr>
<tr style="background:#eee"><td colspan="2"><b>TOTAL</b></td><td><b>126</b></td><td></td><td></td><td></td><td></td></tr>
</table></body></html>`;

const ESP={ 'AJINOMOTO':15, 'AJI PANCA':80, 'SILLAO':6, 'PALILLO':25 };

const browser=await chromium.launch();
const page=await browser.newPage({viewport:{width:900,height:500}});
await page.setContent(html);
const el=await page.$('table');
await el.screenshot({path:'test_lista.png'});
await page.pdf({path:'test_lista.pdf',format:'A4',printBackground:true});
await browser.close();
console.log('generados: test_lista.png ('+fs.statSync('test_lista.png').size+'b) + test_lista.pdf ('+fs.statSync('test_lista.pdf').size+'b)');

async function llamar(tipo, bloque){
  const body={ model:'claude-sonnet-5', max_tokens:8192, system,
    messages:[{role:'user',content:[bloque,{type:'text',text:'Lee esta lista/tabla y extrae cada producto con su cantidad SOLICITADA (no el mín/máx/stock/precio). Devuelve solo el JSON indicado.'}]}] };
  const r=await fetch(SB+'/functions/v1/ia',{method:'POST',headers:{'apikey':ANON,'Authorization':'Bearer '+JWT,'Content-Type':'application/json'},body:JSON.stringify(body)});
  const j=await r.json();
  const text=(j&&j.content&&j.content[0]&&j.content[0].text)||JSON.stringify(j);
  const f=text.indexOf('{'),l=text.lastIndexOf('}');
  let parsed; try{parsed=JSON.parse(text.slice(f,l+1));}catch(e){console.log(tipo+' PARSE FAIL:',text.slice(0,300));return;}
  const items=parsed.items||[];
  console.log('\n===== '+tipo+' → '+items.length+' items =====');
  let ok=true;
  items.forEach(it=>{
    const nom=String(it.nombre||'').toUpperCase();
    const key=Object.keys(ESP).find(k=>nom.includes(k));
    const esp=key?ESP[key]:null;
    const cant=parseFloat(it.cantidad);
    const mark=esp!=null?(cant===esp?'✅':'❌ (esperaba '+esp+')'):'?';
    if(esp!=null&&cant!==esp)ok=false;
    console.log('  '+cant+'  '+nom+'  '+mark);
  });
  console.log(tipo+': '+(ok?'✅ TODAS las cantidades = SOLICITADO (no min/max/stock/precio)':'❌ alguna cantidad mal'));
}
const imgB64=fs.readFileSync('test_lista.png').toString('base64');
const pdfB64=fs.readFileSync('test_lista.pdf').toString('base64');
await llamar('IMAGEN', {type:'image',source:{type:'base64',media_type:'image/png',data:imgB64}});
await llamar('PDF', {type:'document',source:{type:'base64',media_type:'application/pdf',data:pdfB64}});
