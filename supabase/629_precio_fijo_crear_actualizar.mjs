// 629 · crear_producto / actualizar_producto aceptan `precioFijo`.
// Es la pieza server del SACO: la presentación creada sobre un granel se guarda con
// precio_fijo=true y ME (2.8.249) la cobra a etiqueta en vez de por kg.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const rep = (s, from, to, etq) => {
  const n = s.split(from).length - 1;
  if (n !== 1) throw new Error(`[${etq}] esperaba 1 coincidencia, hay ${n}`);
  return s.replace(from, to);
};
const traer = async (fn) => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname=$1 and p.prokind='f' limit 1`, [fn])).rows[0].d;

let crear = await traer('crear_producto');
crear = rep(crear,
  `    envase_sku, es_insumo
  ) values (`,
  `    envase_sku, es_insumo, precio_fijo
  ) values (`, 'crear-cols');
// el VALUES termina con es_insumo; añadimos el tercero antes del cierre
crear = rep(crear,
  `    coalesce((p->>'esInsumo') in ('1','true','t'), false)
  )
  on conflict (id_producto) do nothing;`,
  `    coalesce((p->>'esInsumo') in ('1','true','t'), false),
    coalesce((p->>'precioFijo') in ('1','true','t'), false)   -- [629] etiqueta del saco
  )
  on conflict (id_producto) do nothing;`, 'crear-values');

let act = await traer('actualizar_producto');
act = rep(act,
  `    es_insumo              = case when p ? 'esInsumo'    then ((p->>'esInsumo') in ('1','true','t')) else t.es_insumo end,`,
  `    es_insumo              = case when p ? 'esInsumo'    then ((p->>'esInsumo') in ('1','true','t')) else t.es_insumo end,
    -- [629] precio de ETIQUETA en presentación de granel (regla del saco 25kg)
    precio_fijo            = case when p ? 'precioFijo'  then ((p->>'precioFijo') in ('1','true','t')) else t.precio_fijo end,`,
  'act-precio-fijo');

await c.query('begin');
await c.query(crear); await c.query(act);
const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };

// crear una presentación FIJO de prueba sobre el granel nakamito
const r1 = (await c.query(`select mos.crear_producto($1::jsonb) r`, [JSON.stringify({
  descripcion: 'NAKAMITO GLUTAMATO · Saco 25 kg TEST629', codigoBarra: 'P-TEST629-X25',
  precioVenta: 200, skuBase: 'LEV015', factorConversion: 25, esEnvasable: '0', precioFijo: '1',
  unidad: 'NIU', Unidad_Medida: 'NIU', usuario: 'test'
})])).rows[0].r;
chk('crear_producto acepta precioFijo', r1?.ok !== false, JSON.stringify(r1).slice(0, 90));
const row = (await c.query(`select precio_fijo, factor_conversion, precio_venta, tipo_producto::text tipo
  from mos.productos where codigo_barra='P-TEST629-X25'`)).rows[0];
chk('quedó guardada con precio_fijo=true, factor 25, tipo PRESENTACION',
    row?.precio_fijo === true && Number(row?.factor_conversion) === 25 && row?.tipo === 'PRESENTACION', JSON.stringify(row));

// _venta_canonico de la nueva → 25 kg del granel
const vc = (await c.query(`select * from mos._venta_canonico('P-TEST629-X25', 1, 'NIU')`)).rows[0];
chk('vender 1 saco descuenta 25 kg del canónico WHNAXMTO', vc?.canon_cod === 'WHNAXMTO' && Number(vc?.cant) === 25, JSON.stringify(vc));

// actualizar: apagar el flag
const r2 = (await c.query(`select mos.actualizar_producto($1::jsonb) r`, [JSON.stringify({
  idProducto: r1?.idProducto || r1?.data?.idProducto, precioFijo: '0', usuario: 'test'
})])).rows[0].r;
const row2 = (await c.query(`select precio_fijo from mos.productos where codigo_barra='P-TEST629-X25'`)).rows[0];
chk('actualizar_producto puede apagarlo', row2?.precio_fijo === false, JSON.stringify({ r2: r2?.ok, row2 }));
// y un patch SIN la clave no lo toca
await c.query(`update mos.productos set precio_fijo=true where codigo_barra='P-TEST629-X25'`);
await c.query(`select mos.actualizar_producto($1::jsonb) r`, [JSON.stringify({ idProducto: r1?.idProducto || r1?.data?.idProducto, precioVenta: 199, usuario: 'test' })]);
const row3 = (await c.query(`select precio_fijo, precio_venta from mos.productos where codigo_barra='P-TEST629-X25'`)).rows[0];
chk('un patch sin la clave NO pisa el flag (patch parcial intacto)', row3?.precio_fijo === true && Number(row3?.precio_venta) === 199, JSON.stringify(row3));

// crear sin la clave → false por defecto (todo lo demás del catálogo intacto)
const r3 = (await c.query(`select mos.crear_producto($1::jsonb) r`, [JSON.stringify({
  descripcion: 'PRUEBA NORMAL 629', codigoBarra: 'T629-NORMAL', precioVenta: 5, usuario: 'test'
})])).rows[0].r;
const rowN = (await c.query(`select precio_fijo from mos.productos where codigo_barra='T629-NORMAL'`)).rows[0];
chk('un producto normal nace con precio_fijo=false', rowN?.precio_fijo === false);

t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 110) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }
await c.query(crear); await c.query(act);
console.log(`\n✅ ${t.length}/${t.length} — 629 aplicado`);
fs.writeFileSync('629_precio_fijo_crear_actualizar.sql', crear + '\n\n' + act);
await c.end();
