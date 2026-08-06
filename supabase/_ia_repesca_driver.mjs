// Motor de la repesca: llama a la Edge descripcion-ia {repesca:true} en bucle hasta que
// no queden marcados con EAN. La Edge busca por API directa (sin el cupo local agotado).
import fs from 'fs';
const SECRET = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/.cron_secret_descia', 'utf8').trim();
const URL = 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/descripcion-ia';
let total = 0, rondas = 0, vacias = 0, fallosSeguidos = 0;
while (rondas < 140) {   // tope duro de seguridad (288/3 ≈ 96 rondas esperadas)
  rondas++;
  try {
    const r = await fetch(URL, { method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-cron-secret': SECRET },
      body: JSON.stringify({ repesca: true, max: 3 }) });
    const d = await r.json();
    if (!d.ok) { fallosSeguidos++; console.log(`ronda ${rondas}: ERROR ${JSON.stringify(d).slice(0, 120)}`); }
    else {
      fallosSeguidos = 0;
      total += d.procesados || 0;
      const f = (d.fallos || []).length;
      console.log(`ronda ${rondas}: +${d.procesados || 0}${f ? ` (${f} fallos)` : ''} · acumulado ${total}`);
      if ((d.procesados || 0) === 0 && f === 0) { vacias++; if (vacias >= 2) break; } else vacias = 0;
    }
  } catch (e) { fallosSeguidos++; console.log(`ronda ${rondas}: EXCEPCION ${String(e).slice(0, 100)}`); }
  if (fallosSeguidos >= 5) { console.log('5 fallos seguidos — me detengo'); break; }
  await new Promise(res => setTimeout(res, 4000));
}
console.log(`\nFIN: ${total} productos re-buscados en ${rondas} rondas`);
