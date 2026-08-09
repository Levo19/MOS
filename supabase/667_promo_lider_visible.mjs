// 667 · el radar debe DECIR quién es el líder del ancla, no solo la subcategoría.
//   Parche CRLF-safe sobre la definición VIVA (pg_get_functiondef): anclas de UNA
//   línea + split/join. Agrega al item del líder sus datos (ventas30/precioVenta),
//   expone lider/liderSku/liderVentas/liderPrecio en el JSON de cada sugerencia y
//   reescribe el "porque" del ancla para que nombre al producto líder.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;

const A_OLD = `                jsonb_build_object('skuBase', x.l_sku,   'cantidad', 1, 'descripcion', x.l_desc))`;
const A_NEW = `                jsonb_build_object('skuBase', x.l_sku,   'cantidad', 1, 'descripcion', x.l_desc, 'esLider', true, 'ventas30', round(x.l_q30,0), 'precioVenta', round(x.l_pv,2)))`;

const B_OLD = `            case when x.l_sku is not null then ' · lo anclamos al líder de "' || x.subcat || '"' else '' end)::text,`;
const B_NEW = `            case when x.l_sku is not null then ' · lo anclamos a ' || x.l_desc || ' (' || to_char(x.l_q30,'FM999990') || ' salidas/30d, líder de "' || x.subcat || '")' else '' end)::text,`;

const C_OLD = `      'items',         e.items_j,`;
const C_NEW = [
  `      'items',         e.items_j,`,
  `      'lider',         (e.items_j->1->>'descripcion'),`,
  `      'liderSku',      (e.items_j->1->>'skuBase'),`,
  `      'liderVentas',   case when e.items_j is not null then (e.items_j->1->>'ventas30')::numeric end,`,
  `      'liderPrecio',   case when e.items_j is not null then (e.items_j->1->>'precioVenta')::numeric end,`
].join('\r\n');

const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
await c.query('begin');
try {
  const { rows: [{ d }] } = await c.query(
    `select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='mos' and p.proname='promo_sugerencias'`);
  if (d.includes(`'liderVentas',   case`)) throw new Error('ya parchada (667 idempotente: nada que hacer)');

  const L = d.split('\r\n');
  const rep = (viejo, nuevo, tag) => {
    const i = L.indexOf(viejo);
    if (i < 0) throw new Error('ancla NO encontrada: ' + tag);
    if (L.indexOf(viejo, i + 1) >= 0) throw new Error('ancla DUPLICADA: ' + tag);
    L[i] = nuevo;
  };
  rep(A_OLD, A_NEW, 'items del líder');
  rep(B_OLD, B_NEW, 'porque del ancla');
  rep(C_OLD, C_NEW, 'claves lider en el JSON');

  await c.query(L.join('\r\n'));

  // el radar sigue vivo y el ancla ya nombra al líder
  const { rows: [{ r }] } = await c.query(`select mos.promo_sugerencias('{"n":30}'::jsonb) r`);
  if (!r.ok) throw new Error(r.error);
  const anclas = (r.data || []).filter(x => x.tipo === 'COMBO');
  for (const a of anclas) {
    if (!a.lider) throw new Error('COMBO sin lider: ' + a.skuBase);
    if (a.liderVentas == null) throw new Error('COMBO sin liderVentas: ' + a.skuBase);
    if (String(a.porque).includes('al líder de')) throw new Error('porque viejo (no nombra): ' + a.skuBase);
  }
  console.log('· radar OK ·', r.data.length, 'ideas ·', anclas.length, 'anclas con líder nombrado');
  if (anclas[0]) console.log('  ej:', anclas[0].lider, '·', anclas[0].liderVentas, 'salidas/30d ·', anclas[0].porque);
  await c.query('commit');
  console.log('APLICADO ✓');
} catch (e) {
  await c.query('rollback');
  console.error('FALLÓ:', e.message);
  process.exitCode = 1;
}
await c.end();
