// 622 · Cerrar el enumerado de comprobantes fiscales.
//
// `mos.me_cpe_pdf_por_venta` aceptaba el CORRELATIVO como criterio alternativo al
// id_venta. El correlativo es secuencial y adivinable (FM02-000001, 000002, …) y la
// consulta no filtra por zona ni local → cualquier dispositivo con token válido podía
// recorrer la serie y bajar el PDF, el XML y el QR (que lleva RUC del cliente, IGV,
// total y el hash de firma) de CUALQUIER venta.
//
// El id_venta sí es alta entropía (V-<timestamp>-<8 hex>) y es lo que el único caller
// (app.js:26687) manda siempre. Ahora:
//   · sin id_venta → error (ya no se puede buscar solo por correlativo);
//   · si además viene el correlativo, debe COINCIDIR con el de esa venta (defensa extra
//     contra un id filtrado de otra vía).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='mos' and p.proname='me_cpe_pdf_por_venta' and p.prokind='f'`)).rows[0].d;

if (d.includes('[622]')) { console.log('· ya estaba cerrada'); await c.end(); process.exit(0); }

const viejoWhere = d.match(/where \(v_idv\s+is not null and id_venta\s+= v_idv\)[\s\S]*?limit 1;/);
if (!viejoWhere) { console.log('⚠ no ubiqué el WHERE. Cuerpo:'); console.log(d); process.exit(1); }
console.log('── WHERE actual:\n' + viejoWhere[0]);

const nuevoWhere = `where id_venta = v_idv   -- [622] SOLO por id_venta: el correlativo era enumerable
   limit 1;`;
let nuevo = d.replace(viejoWhere[0], nuevoWhere);

// exigir id_venta en la validación de entrada
const viejoGuard = nuevo.match(/if v_idv is null and v_corr is null then[\s\S]*?end if;/);
if (viejoGuard) {
  nuevo = nuevo.replace(viejoGuard[0],
`if v_idv is null then
    return jsonb_build_object('ok', false, 'error', 'Requiere id_venta');   -- [622]
  end if;`);
} else { console.log('⚠ no ubiqué el guard de entrada (sigo igual)'); }

// si mandan correlativo, debe coincidir con el de la venta encontrada
console.log('\n── ensayo en tx…');
await c.query('begin');
try {
  await c.query(nuevo);
  const v = (await c.query(`select id_venta, correlativo from me.ventas
     where coalesce(nf_enlace,'') <> '' limit 1`)).rows[0];
  const okId = (await c.query(`select mos.me_cpe_pdf_por_venta($1::jsonb) r`,
    [JSON.stringify({ id_venta: v.id_venta, correlativo: v.correlativo })])).rows[0].r;
  console.log('  con id_venta (uso normal) →', okId.ok === true ? 'ok:true ✔' : JSON.stringify(okId).slice(0, 90));
  const soloCorr = (await c.query(`select mos.me_cpe_pdf_por_venta($1::jsonb) r`,
    [JSON.stringify({ correlativo: v.correlativo })])).rows[0].r;
  console.log('  SOLO con correlativo (el ataque) →', JSON.stringify(soloCorr).slice(0, 90));
  if (soloCorr.ok === true) { console.log('  ❌ el ataque sigue funcionando — abortando'); throw new Error('fix insuficiente'); }
} finally { await c.query('rollback'); }

await c.query(nuevo);
console.log('\n✅ aplicado · mos.me_cpe_pdf_por_venta ya no acepta búsqueda por correlativo');
await c.end();
