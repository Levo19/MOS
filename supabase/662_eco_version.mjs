// 662 · mos.eco_version(): una sola RPC con TODAS las versiones del ecosistema.
//
//   Problema real detectado en la auditoria: MosGo vende contra STOCK DE ALMACEN
//   (fam.stockBase, que viaja dentro de ruta_boot) pero su unico disparador de recarga
//   es el poller de 20s sobre mos.catalogo_version... y el stock NO bumpea catalogo_version.
//   Consecuencia: el vendedor de ruta podia estar mirando stock de almacen RANCIO por horas
//   y prometer mercaderia que ya no esta. Es el peor caso de la matriz.
//
//   eco_version devuelve catalogo + wh.stock + me.stock_zonas en UNA llamada, para que un
//   solo poller barato cubra las tres senales. Se otorga a anon porque MosGo llama con la
//   anon key (no mintea JWT de dispositivo como ME/WH).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const SQL = `
create or replace function mos.eco_version(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select jsonb_build_object(
    'ok', true,
    'catalogo',    (select version from mos.catalogo_meta where id = 1),
    'wh_stock',    (select version from wh.ops_meta where dominio = 'stock'),
    'wh_guias',    (select version from wh.ops_meta where dominio = 'guias'),
    'me_zonas',    (select version from me.ops_meta where dominio = 'stock_zonas'),
    'ts', now());
$fn$;
grant execute on function mos.eco_version(jsonb) to anon, authenticated;
`;

// grants de referencia (los mismos que catalogo_version)
const ref = await c.query(`select proacl::text a from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='catalogo_version'`);
console.log('grants de catalogo_version (referencia):', ref.rows[0].a);

console.log('\n== TEST en begin/rollback ==');
await c.query('begin');
await c.query(SQL);
const t = await c.query(`select mos.eco_version('{}'::jsonb) v`);
console.log('respuesta:', JSON.stringify(t.rows[0].v));
await c.query('rollback');
console.log('rollback ok');

console.log('\n== APLICANDO ==');
await c.query(SQL);
const f = await c.query(`select mos.eco_version('{}'::jsonb) v`);
console.log('en prod:', JSON.stringify(f.rows[0].v));
await c.end();
process.exit(0);
