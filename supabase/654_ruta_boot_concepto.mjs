// 654 · CONCEPTO en mos.ruta_boot (MosGo agrupa el catálogo por "qué ES el producto").
//   · Fuente ya verificada: mos.productos.categoria_ia->>'subcategoria' del LÍDER de la familia
//     (NAKAMITO GLUTAMATO 1KG · NAKAMITO GLUTAMATO GRANEL · AJINOMOTO → "Glutamato y umami").
//   · Escalera de respaldo: subcategoria → categoria → 'OTROS'. Nunca null.
//   · Además ordena las familias por (concepto, descripción): el orden de aparición de las
//     secciones queda DETERMINISTA, que es lo que ancla el color de cada grupo en la UI.
// Parche sobre la def VIVA (pg_get_functiondef) con regex tolerantes a espacios.
// Test completo en begin/rollback ANTES de aplicar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

async function def(fn, sch) {
  return (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where p.proname=$1 and n.nspname=$2 limit 1`, [fn, sch])).rows[0].d;
}
function patch(d, re, rep, tag) {
  if (!re.test(d)) throw new Error('ancla no encontrada: ' + tag);
  const out = d.replace(re, rep);
  if (out === d) throw new Error('no-op: ' + tag);
  return out;
}
// Los 3 parches, en una sola función reutilizable (test y aplicación usan EXACTAMENTE lo mismo).
function conCepto(d) {
  if (/'concepto'/.test(d)) return null;   // ya aplicado → idempotente
  // 1) el líder trae su concepto (escalera subcategoria → categoria → OTROS)
  d = patch(d, /(pr\.sustitutos_internos,)/,
    `$1\n           coalesce(nullif(btrim(pr.categoria_ia->>'subcategoria'),''),\n                    nullif(btrim(pr.categoria_ia->>'categoria'),''), 'OTROS') as concepto,`,
    'basep col concepto');
  // 2) la familia lo expone
  d = patch(d, /('sustitutos',\s*coalesce\(b\.sustitutos_internos,\s*'\[\]'::jsonb\),)/,
    `$1\n        'concepto', b.concepto,`, 'build key concepto');
  // 3) orden determinista: primero por concepto (= orden de las secciones en MosGo)
  d = patch(d, /(\)\s*order by\s+)b\.descripcion(\s*\)\s*,\s*'\[\]'::jsonb\))/,
    `$1b.concepto, b.descripcion$2`, 'order by concepto');
  return d;
}
// LENTE DE MARCA: dentro de una sección, las marcas con 3+ familias se agrupan; y buscar
// una marca arma un corte transversal. Ambas cosas necesitan la marca del LÍDER.
// El orden pasa a (concepto, MARCA, nombre) ⇒ cada marca llega en un bloque contiguo y la
// UI puede sub-agrupar de una pasada, sin reordenar nada en el cliente.
function conMarca(d) {
  if (/'marca'/.test(d)) return null;   // idempotente
  d = patch(d, /( as concepto,)/, `$1\n           nullif(btrim(pr.marca),'') as marca,`, 'basep col marca');
  d = patch(d, /('concepto',\s*b\.concepto,)/, `$1\n        'marca', coalesce(b.marca,''),`, 'build key marca');
  // "Sibarita" y "SIBARITA" son la misma marca: se ordena por la forma normalizada
  d = patch(d, /(\)\s*order by\s+b\.concepto,\s*)b\.descripcion(\s*\)\s*,\s*'\[\]'::jsonb\))/,
    `$1upper(coalesce(b.marca,'')), b.descripcion$2`, 'order by marca');
  return d;
}

const T = []; const chk = (n, cond, x) => { T.push([cond ? '✅' : '❌', n, x]); return cond; };

// ────────────────────────── TEST en tx (begin/rollback) ──────────────────────────
await c.query('begin');
{
  const d1 = conCepto(await def('ruta_boot', 'mos'));
  if (d1) await c.query(d1); else console.log('   (ruta_boot ya traía concepto)');
  const d2 = conMarca(await def('ruta_boot', 'mos'));
  if (d2) await c.query(d2); else console.log('   (ruta_boot ya traía marca)');
}
{
  const go = (await c.query(`select mos.ruta_boot('{}'::jsonb) r`)).rows[0].r;
  const fams = go.familias || [];
  chk('ruta_boot devuelve familias', fams.length > 0, `familias=${fams.length}`);
  const sinC = fams.filter(f => f.concepto == null || String(f.concepto).trim() === '');
  chk('todas las familias GO traen concepto no-nulo', sinC.length === 0,
    sinC.length ? 'sin concepto: ' + sinC.map(f => f.baseNombre).join(' | ') : `conceptos distintos=${new Set(fams.map(f => f.concepto)).size}`);

  // glutamatos: comparten EXACTAMENTE el mismo string de concepto
  const glu = fams.filter(f => /GLUTAMATO|AJINOMOTO/i.test(f.baseNombre || ''));
  const gset = new Set(glu.map(f => f.concepto));
  chk('los glutamatos comparten el mismo concepto', glu.length >= 2 && gset.size === 1,
    `n=${glu.length} → ${[...gset].join(' / ') || '(ninguno en GO)'}`);

  // el agrupador de la UI: familias ordenadas por concepto ⇒ cada concepto es UN bloque contiguo
  const seq = fams.map(f => f.concepto);
  const vistos = new Set(); let contiguo = true;
  for (let i = 0; i < seq.length; i++) { if (seq[i] !== seq[i - 1]) { if (vistos.has(seq[i])) contiguo = false; vistos.add(seq[i]); } }
  chk('conceptos llegan en bloques contiguos (orden determinista)', contiguo, `secciones=${vistos.size}`);

  const otros = fams.filter(f => f.concepto === 'OTROS');
  chk('familias que caen en OTROS', true, otros.length ? otros.map(f => f.baseNombre).join(' | ') : 'ninguna');

  console.log('\n  · Secciones que verá MosGo hoy:');
  const g = {}; fams.forEach(f => { (g[f.concepto] = g[f.concepto] || []).push(f.baseNombre); });
  Object.entries(g).forEach(([k, v]) => console.log(`     ${k} (${v.length}) → ${v.join(' · ')}`));

  // no rompimos nada de lo existente
  const ok = fams.every(f => 'fsku' in f && 'baseCod' in f && 'stockBase' in f && 'escalones' in f && 'sustitutos' in f && 'raiz' in f);
  chk('claves existentes intactas (fsku/baseCod/stockBase/escalones/sustitutos/raiz)', ok, '');
  chk('cada familia trae marca (string, "" si el líder no la tiene)', fams.every(f => typeof f.marca === 'string'),
    fams.map(f => f.marca || '—').join(' · '));
  chk('clientes y comision_pct siguen viniendo', Array.isArray(go.clientes) && go.comision_pct != null, `clientes=${(go.clientes || []).length} · pct=${go.comision_pct}`);
}
// LENTE DE MARCA — "what-if" dentro de la MISMA tx que se revierte: se enciende GO para
// ZUKO/UMSHA/SIBARITA (hoy apagadas) y se comprueba que la RPC entrega lo que la UI
// necesita: bloques de marca contiguos dentro del concepto, y la marca en todos lados.
{
  await c.query(`update mos.productos set canal_mayoreo = true
                  where upper(coalesce(marca,'')) in ('ZUKO','UMSHA','SIBARITA')`);
  await c.query(`set local session_replication_role = origin`);
  const fams = ((await c.query(`select mos.ruta_boot('{}'::jsonb) r`)).rows[0].r.familias) || [];
  const norm = f => String(f.marca || '').trim().toUpperCase();

  // ¿cada (concepto, marca) llega en UN solo tramo contiguo? (si no, la UI tendría que reordenar)
  const vistos = new Set(); let contiguo = true; let prev = null;
  for (const f of fams) { const k = (f.concepto || '') + '¦' + norm(f);
    if (k !== prev) { if (vistos.has(k)) contiguo = false; vistos.add(k); prev = k; } }
  chk('bloques (concepto,marca) contiguos — la UI sub-agrupa de una pasada', contiguo, `bloques=${vistos.size}`);

  const cuenta = {};
  for (const f of fams) { const k = (f.concepto || 'OTROS') + ' ¦ ' + (norm(f) || '—'); cuenta[k] = (cuenta[k] || 0) + 1; }
  const gordos = Object.entries(cuenta).filter(([k, n]) => n >= 3 && !k.endsWith('—'));
  chk('hay sub-grupos de marca reales (3+ familias en la misma sección)', gordos.length >= 2,
    gordos.map(([k, n]) => k + '=' + n).join(' · ').slice(0, 260));

  const sib = fams.filter(f => norm(f) === 'SIBARITA');
  const sibC = [...new Set(sib.map(f => f.concepto))];
  chk('marca transversal: SIBARITA cruza varios conceptos (sección virtual)', sib.length >= 4 && sibC.length >= 2,
    `${sib.length} familias en ${sibC.length} conceptos → ${sibC.join(' / ')}`);
  chk('la marca llega normalizable ("Sibarita"/"SIBARITA" = misma)', new Set(sib.map(f => f.marca)).size >= 1,
    [...new Set(sib.map(f => f.marca))].join(' | '));
}

// cobertura del universo (no solo GO): cuántos líderes tendrían que caer a OTROS
{
  const r = (await c.query(`select count(*)::int tot,
      count(nullif(btrim(categoria_ia->>'subcategoria'),''))::int sub,
      count(coalesce(nullif(btrim(categoria_ia->>'subcategoria'),''), nullif(btrim(categoria_ia->>'categoria'),'')))::int algo
      from mos.productos where tipo_producto::text <> 'PRESENTACION'`)).rows[0];
  chk('cobertura de concepto en el universo de líderes', r.algo / r.tot > 0.95,
    `sub=${r.sub}/${r.tot} · con algo=${r.algo}/${r.tot} · a OTROS=${r.tot - r.algo}`);
}
T.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined && x !== '' ? '· ' + String(x).slice(0, 200) : ''));
const fallos = T.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallo(s) — NO se aplica`); await c.end(); process.exit(1); }

// ────────────────────────── APLICAR de verdad ──────────────────────────
await c.query('begin');
{
  const d1 = conCepto(await def('ruta_boot', 'mos'));
  if (d1) await c.query(d1); else console.log('   (idempotente: concepto ya estaba)');
  const d2 = conMarca(await def('ruta_boot', 'mos'));
  if (d2) await c.query(d2); else console.log('   (idempotente: marca ya estaba)');
}
await c.query('commit');
// que MosGo re-jale solo (pollea catalogo_version cada 20 s)
await c.query(`update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1`);
const v = (await c.query(`select version from mos.catalogo_meta where id=1`)).rows[0].version;
console.log(`\n✅ 654 aplicado · ruta_boot expone 'concepto' · catalogo_version → ${v}`);
await c.end();
