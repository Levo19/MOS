// 647 · FONTANERÍA de sustitutos hacia las apps (fase UI del backlog):
//   · ME catalogo_pos_rls: cada vendible lleva 'Sustitutos' (internos del producto).
//   · MosGo ruta_boot: cada familia lleva 'sustitutos' (internos del líder).
//   · WH ya los recibe (to_jsonb fila completa) — solo necesitaba updated_at.
//   · sust_guardar v4: toca updated_at (delta WH) — SIN bump (el bump va throttled).
//   · sust_validar: bump manual al final de cada corrida (2/h) → ME/GO refrescan con lag ≤30min.
//   · One-time: touch de todo lo que ya tiene sustitutos + 1 bump.
// Parches sobre defs VIVAS (pg_get_functiondef) con regex tolerantes a espacios.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

async function def(fn) {
  return (await c.query(`select pg_get_functiondef(p.oid) d, n.nspname sch from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.proname=$1 limit 1`, [fn])).rows[0];
}
function patch(d, re, rep, tag) {
  const m = d.match(re);
  if (!m) throw new Error('ancla no encontrada: ' + tag);
  if (d.replace(re, rep) === d) throw new Error('no-op: ' + tag);
  return d.replace(re, rep);
}

const T = []; const chk = (n, cond, x) => { T.push([cond ? '✅' : '❌', n, x]); return cond; };
await c.query('begin');

// ── ME · catalogo_pos_rls ──
{
  let d = (await def('catalogo_pos_rls')).d;
  if (!/sustitutos_internos/.test(d)) {
    d = patch(d, /(coalesce\(precio_fijo, false\) as precio_fijo,)/, `$1\n         sustitutos_internos,`, 'ME act col');
    d = patch(d, /('Precio_Fijo', coalesce\(\(m->>'precio_fijo'\)::boolean,)/, `'Sustitutos', coalesce(m->'sustitutos_internos','[]'::jsonb),\n            $1`, 'ME build key');
    await c.query(d);
  }
}
// ── GO · ruta_boot ──
{
  let d = (await def('ruta_boot')).d;
  if (!/sustitutos_internos/.test(d)) {
    d = patch(d, /(pr\.descripcion,)/, `$1\n           pr.sustitutos_internos,`, 'GO basep col');
    d = patch(d, /('stockBase',\s+b\.stock,)/, `$1\n        'sustitutos', coalesce(b.sustitutos_internos, '[]'::jsonb),`, 'GO build key');
    await c.query(d);
  }
}
// ── sust_guardar v4: updated_at en holder + presentaciones ──
{
  let d = (await def('sust_guardar')).d;
  if (!/set sustitutos_internos = v_int, sustitutos_externos = v_ext, sust_stale = false, updated_at/.test(d)) {
    d = patch(d, /(set sustitutos_internos = v_int, sustitutos_externos = v_ext, sust_stale = false)/,
      `$1, updated_at = now()`, 'guardar holder');
    d = patch(d, /(set sustitutos_internos = v_int, sustitutos_externos = v_ext)(\s*\n\s*where pr\.tipo_producto)/,
      `$1, updated_at = now()$2`, 'guardar presentaciones');
    await c.query(d);
  }
}
// ── sust_validar: bump throttled al final ──
{
  let d = (await def('sust_validar')).d;
  if (!/catalogo_meta/.test(d)) {
    d = patch(d, /(return jsonb_build_object\('ok', true, 'limpiados', v_n\);)/,
      `-- [647] anuncio throttled (2/h): ME/GO re-jalan y ven sustitutos frescos (replica ⇒ bump manual)
  update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1;
  $1`, 'validar bump');
    await c.query(d);
  }
}

// ── tests ──
{
  const me = (await c.query(`select mos.catalogo_pos_rls() r`).catch(e => ({ rows: [{ r: { err: e.message } }] }))).rows[0].r;
  const prods = (me && me.data && me.data.PRESENTACIONES) || [];
  const conS = Array.isArray(prods) ? prods.filter(x => Array.isArray(x.Sustitutos) && x.Sustitutos.length) : [];
  chk('ME pos_rls expone Sustitutos', conS.length > 100, `vendibles con sustitutos=${conS.length}` + (me.err ? ' ERR:' + me.err : ''));
  if (conS.length) console.log('   ej ME:', conS[0].Empaque, '→', conS[0].Sustitutos[0].nombre);
}
{
  const go = (await c.query(`select mos.ruta_boot('{}'::jsonb) r`).catch(e => ({ rows: [{ r: { err: e.message } }] }))).rows[0].r;
  const fams = (go && (go.familias || (go.data && go.data.familias))) || [];
  const conS = Array.isArray(fams) ? fams.filter(f => Array.isArray(f.sustitutos) && f.sustitutos.length) : [];
  chk('GO ruta_boot expone sustitutos', conS.length > 0, `familias con sustitutos=${conS.length}` + (go.err ? ' ERR:' + go.err : ''));
}
{
  const h = (await c.query(`select codigo_barra, categoria_ia->>'categoria' cat from mos.productos
    where tipo_producto::text='CANONICO' and sustitutos_internos is not null and jsonb_array_length(sustitutos_internos)>0 limit 1`)).rows[0];
  const cand = (await c.query(`select codigo_barra from mos.productos where tipo_producto::text='CANONICO'
    and coalesce(estado,true) and categoria_ia->>'categoria'=$2 and codigo_barra<>$1 limit 1`, [h.codigo_barra, h.cat])).rows[0].codigo_barra;
  await c.query(`update mos.productos set updated_at = now() - interval '2 days' where codigo_barra=$1`, [h.codigo_barra]);
  await c.query(`select mos.sust_guardar($1::jsonb)`, [JSON.stringify({ codigoBarra: h.codigo_barra, internos: [{ cod: cand, motivo: 't' }], externos: [] })]);
  await c.query(`set local session_replication_role = origin`);
  const r = (await c.query(`select updated_at > now() - interval '1 minute' fresco from mos.productos where codigo_barra=$1`, [h.codigo_barra])).rows[0];
  chk('sust_guardar toca updated_at (delta WH)', r.fresco === true, '');
}
{
  const v0 = (await c.query(`select version from mos.catalogo_meta where id=1`)).rows[0].version;
  await c.query(`select mos.sust_validar('{}'::jsonb)`);
  await c.query(`set local session_replication_role = origin`);
  const v1 = (await c.query(`select version from mos.catalogo_meta where id=1`)).rows[0].version;
  chk('sust_validar bumpea versión (throttled)', Number(v1) > Number(v0), `${v0}→${v1}`);
}
T.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 120) : ''));
const fallos = T.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} — NO se aplica`); await c.end(); process.exit(1); }

// aplicar de verdad (mismos parches, fuera de tx de test)
await c.query('begin');
for (const fn of ['catalogo_pos_rls', 'ruta_boot', 'sust_guardar', 'sust_validar']) {
  let d = (await def(fn)).d;
  if (fn === 'catalogo_pos_rls' && !/sustitutos_internos/.test(d)) {
    d = patch(d, /(coalesce\(precio_fijo, false\) as precio_fijo,)/, `$1\n         sustitutos_internos,`, 'a');
    d = patch(d, /('Precio_Fijo', coalesce\(\(m->>'precio_fijo'\)::boolean,)/, `'Sustitutos', coalesce(m->'sustitutos_internos','[]'::jsonb),\n            $1`, 'b');
    await c.query(d);
  }
  if (fn === 'ruta_boot' && !/sustitutos_internos/.test(d)) {
    d = patch(d, /(pr\.descripcion,)/, `$1\n           pr.sustitutos_internos,`, 'c');
    d = patch(d, /('stockBase',\s+b\.stock,)/, `$1\n        'sustitutos', coalesce(b.sustitutos_internos, '[]'::jsonb),`, 'd');
    await c.query(d);
  }
  if (fn === 'sust_guardar' && !/sust_stale = false, updated_at/.test(d)) {
    d = patch(d, /(set sustitutos_internos = v_int, sustitutos_externos = v_ext, sust_stale = false)/, `$1, updated_at = now()`, 'e');
    d = patch(d, /(set sustitutos_internos = v_int, sustitutos_externos = v_ext)(\s*\n\s*where pr\.tipo_producto)/, `$1, updated_at = now()$2`, 'f');
    await c.query(d);
  }
  if (fn === 'sust_validar' && !/catalogo_meta/.test(d)) {
    d = patch(d, /(return jsonb_build_object\('ok', true, 'limpiados', v_n\);)/,
      `update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1;\n  $1`, 'g');
    await c.query(d);
  }
}
await c.query('commit');
// one-time: lo ya calculado se vuelve visible para las 3 apps (touch + 1 bump del trigger)
const tb = await c.query(`update mos.productos set updated_at = now() where sustitutos_internos is not null`);
console.log(`\n✅ ${T.length}/${T.length} — 647 aplicado · touch one-time: ${tb.rowCount} filas (1 bump)`);
await c.end();
