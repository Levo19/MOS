// Anexa a 608 la versión v608 de cerrar_pickup_con_despacho (base 603 + ts en la derivación).
import fs from 'fs';
let t = fs.readFileSync('./603_wh_acumulador_cuenta_corriente.sql', 'utf8');
const ini = t.indexOf('CREATE OR REPLACE FUNCTION wh.cerrar_pickup_con_despacho');
let fn = t.slice(ini);
const cut = fn.indexOf('-- ── DATA FIX');
if (cut > 0) fn = fn.slice(0, cut);
const viejo = "      v_det := v_det || jsonb_build_array(jsonb_build_object('codigo_barra', v_cod, 'cantidad', v_qty));";
const nuevo = "      v_det := v_det || jsonb_build_array(jsonb_build_object('codigo_barra', v_cod, 'cantidad', v_qty, 'ts', v_it->>'tsDespacho'));   -- [608] hora del escaneo";
if (!fn.includes(viejo)) { console.log('NO ENCONTRADO el punto de patch'); process.exit(1); }
fn = fn.replace(viejo, nuevo);
fs.appendFileSync('./608_hora_escaneo_por_linea.sql', '\n' + fn.trim() + '\n');
console.log('cerrar_pickup v608 anexado OK');
