// Siembra el icono 'postre' (cupcake) en mos.adhesivo_iconos, tamaños 48 y 96.
// El dibujo REPLICA EXACTO la factory _postre() de assets/editor-adhesivos/iconos.js
// (misma matriz → preview y impresión pixel-perfect). El 96 es upscale ×2 nearest.
// Hex TSPL: bit 0 = imprime (negro), bit 1 = blanco → se invierte al exportar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;

const T = 48;
function crearMatriz(n) { return Array.from({ length: n }, () => new Array(n).fill(0)); }
function set(m, x, y) { if (x >= 0 && y >= 0 && y < m.length && x < m.length) m[y][x] = 1; }
function lineaH(m, x1, x2, y, g = 1) { for (let dy = 0; dy < g; dy++) for (let x = x1; x <= x2; x++) set(m, x, y + dy); }
function lineaV(m, x, y1, y2, g = 1) { for (let dx = 0; dx < g; dx++) for (let y = y1; y <= y2; y++) set(m, x + dx, y); }

function postre() {
  const m = crearMatriz(T);
  lineaH(m, 22, 25, 2, 4);   // cereza
  lineaH(m, 24, 27, 0, 2);   // tallito
  lineaH(m, 10, 15, 10, 2);  // frosting ondas
  lineaH(m, 20, 27, 8, 4);
  lineaH(m, 32, 37, 10, 2);
  lineaH(m, 12, 35, 12, 4);
  lineaH(m, 8, 39, 16, 4);
  lineaH(m, 6, 41, 20, 4);   // borde copa
  lineaV(m, 10, 24, 41, 4);  // pirotín rayas
  lineaV(m, 18, 24, 41, 4);
  lineaV(m, 26, 24, 41, 4);
  lineaV(m, 34, 24, 41, 4);
  lineaH(m, 12, 35, 42, 4);  // base
  return m;
}

function upscale2(m) {
  const n = m.length, r = crearMatriz(n * 2);
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (m[y][x]) {
    r[y * 2][x * 2] = r[y * 2][x * 2 + 1] = r[y * 2 + 1][x * 2] = r[y * 2 + 1][x * 2 + 1] = 1;
  }
  return r;
}

function toHex(m) {
  const n = m.length, wB = n / 8;
  let hex = '';
  for (let y = 0; y < n; y++) for (let b = 0; b < wB; b++) {
    let byte = 0;
    for (let bit = 0; bit < 8; bit++) if (m[y][b * 8 + bit] !== 1) byte |= (1 << (7 - bit));
    hex += byte.toString(16).toUpperCase().padStart(2, '0');
  }
  return hex;
}

const m48 = postre(), m96 = upscale2(m48);
console.log('── preview 48×48 (█ = tinta):');
console.log(m48.map(f => f.map(b => b ? '█' : ' ').join('')).join('\n'));

const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
for (const [dots, m] of [[48, m48], [96, m96]]) {
  const hex = toHex(m);
  await c.query(`insert into mos.adhesivo_iconos (id_icono, tamano_dots, hex)
    values ('postre', $1, $2)
    on conflict (id_icono, tamano_dots) do update set hex = excluded.hex`, [dots, hex]);
  console.log(`sembrado postre__${dots} · hex ${hex.length} chars`);
}
console.table((await c.query(`select id_icono, tamano_dots, length(hex) len from mos.adhesivo_iconos where id_icono='postre'`)).rows);
await c.end();
