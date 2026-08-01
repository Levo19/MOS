// Barrido WH 2.13.524: sellos tsDespacho en cada marca + spec createdAt de guia_detalle.
import fs from 'fs';
const APP = 'C:/Users/ISO/ecosistema MOS/warehouseMos/js/app.js';
const API = 'C:/Users/ISO/ecosistema MOS/warehouseMos/js/api.js';
const STAMP = " item.tsDespacho = new Date().toISOString();   // [607] hora de salida del producto";
let t = fs.readFileSync(APP, 'utf8');
const reps = [
  ["item.despachado = prevDesp + 1;", "item.despachado = prevDesp + 1;" + STAMP],
  ["item.despachado = Math.max(base, prevDesp - 1);", "item.despachado = Math.max(base, prevDesp - 1);" + STAMP],
  ["item.despachado = nuevoTotal;", "item.despachado = nuevoTotal;" + STAMP],
  ["item.despachado = (parseFloat(item.despachado) || 0) + 1;", "item.despachado = (parseFloat(item.despachado) || 0) + 1;" + STAMP],
  ["      .reduce((s, k) => s + (parseFloat(item.despachadoPorCodigo[k]) || 0), 0);",
   "      .reduce((s, k) => s + (parseFloat(item.despachadoPorCodigo[k]) || 0), 0);" + STAMP],
];
for (const [a, b] of reps) {
  const nvo = t.split(a).length - 1;
  t = t.split(a).join(b);
  console.log(nvo + 'x', a.trim().slice(0, 60));
}
fs.writeFileSync(APP, t);
let u = fs.readFileSync(API, 'utf8');
const specOld = "['id_detalle','idDetalle','text'],['fecha_vencimiento','fechaVencimiento','date']],";
const specNew = "['id_detalle','idDetalle','text'],['fecha_vencimiento','fechaVencimiento','date'],['created_at','createdAt','date']],";
console.log('spec guia_detalle:', u.includes(specOld) ? 'OK' : 'NO ENCONTRADO');
u = u.split(specOld).join(specNew);
fs.writeFileSync(API, u);
console.log('listo');
