// 664 · aplica el SQL + parcha la definición VIVA de mos.catalogo_pos_rls para que el POS
//        reciba también Hora_Desde / Hora_Hasta / Estrategia de cada promoción.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const DRY = process.argv.includes('--dry');
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const sql = fs.readFileSync('664_promos_horario_estrategia.sql', 'utf8');
const defPos = async () => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='catalogo_pos_rls'`)).rows[0].d;

await c.query('begin');
try {
  await c.query(sql);

  let d = await defPos();
  if (d.includes('[664]')) {
    console.log('· catalogo_pos_rls ya tiene [664]');
  } else {
    const ancla = `          'Activa', coalesce(pm.activa, true)\n`;
    const i = d.indexOf(ancla);
    if (i < 0) throw new Error('ancla Activa no encontrada en catalogo_pos_rls');
    if (d.indexOf(ancla, i + 1) >= 0) throw new Error('ancla duplicada');
    const nuevo = `          'Activa', coalesce(pm.activa, true),\n`
      + `          /* [664] ventana horaria (null = todo el día) + jugada del playbook */\n`
      + `          'Hora_Desde', case when pm.hora_desde is null then null else to_char(pm.hora_desde,'HH24:MI') end,\n`
      + `          'Hora_Hasta', case when pm.hora_hasta is null then null else to_char(pm.hora_hasta,'HH24:MI') end,\n`
      + `          'Estrategia', pm.estrategia\n`;
    d = d.slice(0, i) + nuevo + d.slice(i + ancla.length);
    await c.query(d);
    console.log('· catalogo_pos_rls parchado con Hora_Desde/Hora_Hasta/Estrategia');
  }

  // ── smoke: crear promo con horario + estrategia, listarla y verla en el POS ──
  const { rows: [{ sku }] } = await c.query(`select sku_base as sku from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,false) limit 1`);
  const r1 = (await c.query(`select mos.crear_promocion($1::jsonb) r`, [JSON.stringify({
    tipo: 'PORCENTAJE', skuBase: sku, cantMin: 2, valorPromo: 20, descripcion: 'smoke 664',
    horaDesde: '14:00', horaHasta: '18:00', estrategia: 'valle', activa: true
  })])).rows[0].r;
  if (!r1.ok) throw new Error('crear_promocion: ' + r1.error);
  const lst = (await c.query(`select mos.promociones_lista('{}'::jsonb) r`)).rows[0].r;
  const it = (lst.data || []).find(x => x.idPromo === r1.data.idPromo);
  if (!it || it.horaDesde !== '14:00' || it.horaHasta !== '18:00' || it.estrategia !== 'valle')
    throw new Error('lista no devuelve horario/estrategia: ' + JSON.stringify(it));
  const pos = (await c.query(`select mos.catalogo_pos_rls() r`)).rows[0].r;
  const pp = (pos.data.PROMOCIONES || []).find(x => x.ID_Promo === r1.data.idPromo);
  if (!pp || pp.Hora_Desde !== '14:00' || pp.Hora_Hasta !== '18:00')
    throw new Error('POS no recibe horario: ' + JSON.stringify(pp));
  // horario incompleto debe fallar
  const bad = (await c.query(`select mos.crear_promocion($1::jsonb) r`, [JSON.stringify({ tipo: 'PORCENTAJE', skuBase: sku, cantMin: 2, valorPromo: 10, horaDesde: '14:00' })])).rows[0].r;
  if (bad.ok) throw new Error('horario incompleto debió fallar');
  // descartes
  const rd = (await c.query(`select mos.promo_descartar($1::jsonb) r`, [JSON.stringify({ skuBase: sku, regla: 'REMATE', por: 'test' })])).rows[0].r;
  if (!rd.ok) throw new Error('promo_descartar: ' + rd.error);

  console.log('· smoke OK →', JSON.stringify(pp));
  if (DRY) { await c.query('rollback'); console.log('DRY: rollback'); }
  else { await c.query(`delete from mos.promociones where descripcion='smoke 664'`); await c.query(`delete from mos.promo_descartes where por='test'`); await c.query('commit'); console.log('APLICADO ✓'); }
} catch (e) {
  await c.query('rollback');
  console.error('FALLÓ:', e.message);
  process.exitCode = 1;
}
await c.end();
