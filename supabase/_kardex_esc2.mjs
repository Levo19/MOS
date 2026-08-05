import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const fns = (await c.query(`select n.nspname||'.'||p.proname f, pg_get_functiondef(p.oid) d
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.prokind='f' and pg_get_functiondef(p.oid) ilike '%wh.stock%'`)).rows;
const escriben = fns.filter(x => /(insert\s+into|update)\s+wh\.stock\s/is.test(x.d));
const malos = escriben.filter(x => !/stock_movimientos/i.test(x.d));
console.log(`funciones que mencionan wh.stock: ${fns.length} · que ESCRIBEN: ${escriben.length}`);
console.log(`\n❌ escriben stock SIN registrar kardex (${malos.length}):`);
malos.forEach(x => console.log('   ', x.f));
console.log(`\n✅ con kardex (${escriben.length - malos.length}):`);
escriben.filter(x=>/stock_movimientos/i.test(x.d)).forEach(x => console.log('   ', x.f));

console.log('\n── historial del peor salto (7756984000026, 28/07)');
console.table((await c.query(`
  select to_char(fecha at time zone 'America/Lima','DD/MM HH24:MI:SS') cuando, tipo_operacion,
         left(coalesce(origen,''),24) origen, round(stock_antes,1) antes, round(delta,1) delta,
         round(stock_despues,1) despues, left(coalesce(usuario,''),12) usuario
    from wh.stock_movimientos where upper(btrim(cod_producto))='7756984000026'
     and fecha between '2026-07-27' and '2026-07-31' order by fecha, id_mov`)).rows);
await c.end();
