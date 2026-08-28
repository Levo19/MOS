// Runner para aplicar 972_saldo_inicial_reconciliacion.sql (el dueño lo corre con `!` porque el
// clasificador bloquea la escritura masiva de inventario en automático). La migración se auto-verifica:
// aborta sola si wh.stock cambia o si algo no reconcilia. No toca wh.stock. Reversible (borrar RECON_%/AJRECON_%).
const fs = require('fs');
const { Client } = require('pg');
(async () => {
  const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
  const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
  await c.connect();
  c.on('notice', m => console.log('•', m.message));
  try {
    await c.query(fs.readFileSync(__dirname + '/972_saldo_inicial_reconciliacion.sql', 'utf8'));
    const v = await c.query(`select count(*) d from wh.stock s where abs(s.cantidad_disponible - coalesce((select sum(delta) from wh.stock_movimientos m where m.cod_producto=s.cod_producto),0))>0.01`);
    const n = await c.query(`select count(*) filter (where tipo_operacion='SALDO_INICIAL') saldos, count(*) filter (where tipo_operacion='CORRECCION_INGRESO') correcciones from wh.stock_movimientos where id_mov like 'RECON_%'`);
    console.log('\n✅ APLICADO. Descuadres restantes:', v.rows[0].d, '| creados → saldos_iniciales:', n.rows[0].saldos, 'correcciones_ingreso:', n.rows[0].correcciones, '| wh.stock intacto.');
  } catch (e) { console.log('\n❌ NO se aplicó (rollback):', e.message); }
  await c.end();
})();
