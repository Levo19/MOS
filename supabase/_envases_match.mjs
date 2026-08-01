// _envases_match.mjs — cruza derivados del catálogo vivo con la tabla primigenia
// (código o nombre) y sugiere el celofán (skuBase) según la columna Empaque.
// Genera _envases_match.json para el HTML de revisión.
import fs from 'fs';

const { celofanes, derivados } = JSON.parse(fs.readFileSync('./_envases_derivados.json', 'utf8'));

// ---------- normalización ----------
const norm = s => (s || '')
  .toUpperCase()
  .replace(/\u00d1/g, '~ENYE~')
  .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
  .replace(/~ENYE~/g, '\u00d1')
  .replace(/\s+/g, ' ')
  .trim();

// dims "4.5*5*2" → clave canónica "4.5x5x2"
const dimKey = s => {
  const m = (s || '').trim().match(/^(\d+(?:\.\d+)?)[*xX](\d+(?:\.\d+)?)[*xX](\d+(?:\.\d+)?)$/);
  return m ? `${+m[1]}x${+m[2]}x${+m[3]}` : null;
};

// ---------- celofanes por dimensión ----------
const celoByDim = {};
for (const c of celofanes) {
  const m = norm(c.descripcion).match(/CELOFAN\s+(.+)$/);
  const k = m ? dimKey(m[1]) : null;
  if (k) celoByDim[k] = c;
}

// ---------- parse primigenia ----------
const rows = [];
for (const line of fs.readFileSync('./_envases_primigenia.txt', 'utf8').split(/\r?\n/)) {
  if (!line.trim()) continue;
  const t = line.split('\t').map(x => x.trim());
  // Codigo, Origen, Factor, NombreCompleto, Presentacion, Size, Empaque?
  rows.push({
    codigo: t[0].replace(/"/g, '').trim(),
    origen: t[1],
    presentacion: norm(t[4]),
    size: t[5] || '',
    empaque: t[6] ? dimKey(t[6]) : null,
    empaqueRaw: t[6] || ''
  });
}

// ---------- excepciones SIN celofán (pedido del usuario) ----------
const SIN_ENVASE = new Set([
  'CASA GRANDE AZUCAR BLANCA 1KG',
  'SAN JACINTO AZUCAR RUBIA 1KG',
  'NAKAMITO GLUTAMATO 1KG',
  'NAKAMITO GLUTAMATO 500GR',
  'NAKAMITO GLUTAMATO 250GR',
].map(norm));

// ---------- índices primigenia ----------
const byCodigo = new Map(rows.map(r => [r.codigo.toUpperCase(), r]));
const byNombre = new Map(rows.map(r => [r.presentacion, r]));

// similitud simple por tokens (para fuzzy)
const sim = (a, b) => {
  const A = new Set(a.split(' ')), B = new Set(b.split(' '));
  let inter = 0; for (const x of A) if (B.has(x)) inter++;
  return inter / Math.max(A.size, B.size);
};

// ---------- match ----------
const out = [];
const usadas = new Set();
for (const d of derivados) {
  const dn = norm(d.descripcion);
  let row = byCodigo.get((d.codigo_barra || '').toUpperCase().trim()) || null;
  let metodo = row ? 'codigo' : null;
  if (!row) { row = byNombre.get(dn) || null; if (row) metodo = 'nombre'; }
  if (!row) {
    // fuzzy: mismo size token final + mejor similitud
    const dsize = (dn.match(/(\d+(?:\.\d+)?(?:GR|KG))$/) || [])[1];
    let best = null, bestS = 0;
    for (const r of rows) {
      if (dsize && !r.presentacion.endsWith(dsize)) continue;
      const s = sim(dn, r.presentacion);
      if (s > bestS) { bestS = s; best = r; }
    }
    if (best && bestS >= 0.75) { row = best; metodo = 'fuzzy(' + bestS.toFixed(2) + ')'; }
  }

  let envase = null, confianza = 'sin_match';
  if (SIN_ENVASE.has(dn)) {
    envase = 'SIN_ENVASE'; confianza = 'excepcion';
  } else if (row) {
    usadas.add(row.codigo);
    if (row.empaque && celoByDim[row.empaque]) {
      const c = celoByDim[row.empaque];
      envase = c.sku_base; confianza = metodo;
    } else if (row.empaque) {
      confianza = 'empaque_sin_celofan:' + row.empaqueRaw;
    } else {
      confianza = 'primigenia_sin_empaque';
    }
  }
  out.push({
    codigo_barra: d.codigo_barra, sku_base: d.sku_base, descripcion: d.descripcion,
    base: d.codigo_producto_base, estado: d.estado,
    prim_codigo: row ? row.codigo : null, prim_empaque: row ? row.empaqueRaw : null,
    metodo: row ? metodo : null, envase_sku: envase, confianza
  });
}

const noUsadas = rows.filter(r => !usadas.has(r.codigo));
const resumen = {};
for (const o of out) resumen[o.confianza] = (resumen[o.confianza] || 0) + 1;

fs.writeFileSync('./_envases_match.json', JSON.stringify({
  celofanes: celofanes.map(c => ({ sku: c.sku_base, desc: c.descripcion })),
  match: out, primigenia_sin_catalogo: noUsadas
}, null, 1));

console.log('derivados catalogo:', out.length);
console.log('resumen confianza:', JSON.stringify(resumen, null, 1));
console.log('primigenia sin match en catalogo:', noUsadas.length);
noUsadas.slice(0, 40).forEach(r => console.log('  -', r.codigo, r.presentacion, r.empaqueRaw));
console.log('--- derivados sin match:');
out.filter(o => o.confianza === 'sin_match').forEach(o => console.log('  *', o.codigo_barra, o.descripcion));
console.log('--- empaque sin celofan:');
out.filter(o => o.confianza.startsWith('empaque_sin')).forEach(o => console.log('  !', o.codigo_barra, o.descripcion, o.confianza));
