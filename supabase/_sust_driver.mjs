// Driver del BACKFILL de sustitutos (~1,732 líderes): llama la Edge en rondas de 3,
// reporta avance real contra la BD cada 15 rondas, y se detiene cuando no queda nada
// o si 6 rondas seguidas no procesan (los fallidos se hunden solos por sust_intentos).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const SECRET = fs.readFileSync('../.cron_secret_descia', 'utf8').trim();
const URL = 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/sustitutos-ia';
const db = () => new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
async function restantes() {
  const c = db(); await c.connect();
  const n = (await c.query(`select count(*) n from mos.productos
    where tipo_producto::text in ('CANONICO','DERIVADO') and coalesce(estado,true)
      and coalesce(es_insumo,false)=false and descripcion_ia is not null and categoria_ia is not null
      and (sust_stale or sustitutos_internos is null)`)).rows[0].n;
  await c.end(); return Number(n);
}
let acumulado = 0, fallosTot = 0, vacias = 0;
for (let ronda = 1; ronda <= 900; ronda++) {
  let r;
  try {
    const resp = await fetch(URL, { method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-cron-secret': SECRET },
      body: JSON.stringify({ max: 3 }) });
    r = await resp.json();
  } catch (e) { console.log(`ronda ${ronda}: ERROR red ${e.message}`); vacias++; if (vacias >= 6) break; continue; }
  if (!r.ok) { console.log(`ronda ${ronda}: ERROR ${JSON.stringify(r).slice(0, 120)}`); vacias++; if (vacias >= 6) break; continue; }
  if (r.nota === 'sin pendientes') { console.log(`ronda ${ronda}: sin pendientes — FIN`); break; }
  acumulado += r.procesados; fallosTot += (r.fallos || []).length;
  if (r.procesados === 0) { vacias++; if (vacias >= 6) { console.log('6 rondas sin procesar — FIN (quedan solo fallidos)'); break; } }
  else vacias = 0;
  if (ronda % 15 === 0) {
    const rest = await restantes();
    console.log(`ronda ${ronda}: acumulado ${acumulado} (fallos ${fallosTot}) · restantes en BD: ${rest}`);
    if (rest === 0) break;
  } else {
    console.log(`ronda ${ronda}: +${r.procesados}${(r.fallos||[]).length ? ` (${r.fallos.length} fallos)` : ''} · acum ${acumulado}`);
  }
  await new Promise(s => setTimeout(s, 1500));
}
const fin = await restantes();
console.log(`\nFIN DRIVER · procesados ${acumulado} · fallos ${fallosTot} · restantes: ${fin}`);
