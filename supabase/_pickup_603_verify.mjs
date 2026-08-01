// Verifica 603: zona02 visible ya + smoke tx-rollback del cierre parcial de un acumulador.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const q = async (sql, args) => (await c.query(sql, args)).rows;
let fallos = 0;
const ok = (n, cond, x) => { console.log((cond ? '✓' : '✗ FALLO'), n, x ?? ''); if (!cond) fallos++; };

console.log('— estado actual de acumuladores del bucket vigente:');
console.table(await q(`
  select id_pickup, id_zona, estado, jsonb_array_length(coalesce(items,'[]'::jsonb)) n_items
    from wh.pickups
   where fuente='ACUMULADO_SEMANAL'
     and right(id_pickup,10) ~ '^\\d{4}-\\d{2}-\\d{2}$'
     and to_date(right(id_pickup,10),'YYYY-MM-DD') = wh._bucket_dom((now() at time zone 'America/Lima')::date)
   order by id_zona`));

// SMOKE tx-rollback: cerrar parcial el acumulador zona02 → debe quedar PENDIENTE (no PARCIAL)
await c.query('begin');
try {
  const before = (await q(`select items from wh.pickups where id_pickup='PCK-ACU-ZONA-02-2026-07-26'`))[0];
  const items = before.items;
  // simular: despachar 1 unidad del primer item con deuda
  const idx = items.findIndex(it => Number(it.solicitado || 0) > Number(it.despachado || 0));
  ok('hay item con deuda para simular', idx >= 0, 'idx=' + idx);
  items[idx].despachado = Number(items[idx].despachado || 0) + 1;
  const r = (await q(`select wh.cerrar_pickup_con_despacho(jsonb_build_object(
      'id_pickup','PCK-ACU-ZONA-02-2026-07-26','usuario','PRUEBA CLAUDE',
      'items', $1::jsonb,
      'despacho_detalle', jsonb_build_array(jsonb_build_object('codigo_barra', coalesce($2::text,'X'), 'cantidad', 1))
    )) r`, [JSON.stringify(items), (items[idx].codigosOriginales || [])[0] || 'X']))[0].r;
  ok('cierre parcial ok', r.ok === true, JSON.stringify(r).slice(0, 140));
  ok('estado devuelto = PENDIENTE (cuenta corriente)', r.data && r.data.estado === 'PENDIENTE', r.data && r.data.estado);
  const est = (await q(`select estado from wh.pickups where id_pickup='PCK-ACU-ZONA-02-2026-07-26'`))[0].estado;
  ok('en BD quedó PENDIENTE (sigue visible en WH)', est === 'PENDIENTE', est);
} finally {
  await c.query('rollback');
  console.log('ROLLBACK OK — smoke no persistió · FALLOS:', fallos);
}
await c.end();
process.exit(fallos ? 1 : 0);
