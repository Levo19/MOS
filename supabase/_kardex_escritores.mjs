// ¿Qué funciones escriben wh.stock SIN registrar el movimiento en el kardex?
// Ése es el origen de los 168 saltos y de los 37 códigos con stock y sin historial.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const fns = (await c.query(`select n.nspname||'.'||p.proname f, pg_get_functiondef(p.oid) d
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.prokind='f' and n.nspname in ('wh','mos','me')
   and pg_get_functiondef(p.oid) ~* '(insert into|update)\\s+wh\\.stock\\b'`)).rows;

const malos = [], buenos = [];
for (const { f, d } of fns) {
  (/stock_movimientos/i.test(d) ? buenos : malos).push(f);
}
console.log(`funciones que escriben wh.stock: ${fns.length}`);
console.log(`\n❌ ESCRIBEN STOCK SIN KARDEX (${malos.length}):`);
malos.forEach(f => console.log('   ', f));
console.log(`\n✅ registran el movimiento (${buenos.length}):`);
buenos.forEach(f => console.log('   ', f));

console.log('\n── ¿hay un trigger que cubra las escrituras sueltas?');
console.table((await c.query(`select tgname, pg_get_triggerdef(t.oid) def
  from pg_trigger t join pg_class cl on cl.oid=t.tgrelid join pg_namespace n on n.oid=cl.relnamespace
 where n.nspname='wh' and cl.relname='stock' and not t.tgisinternal`)).rows);

console.log('\n── de dónde vienen los saltos: origen del movimiento que llega descuadrado');
console.table((await c.query(`
  with s as (
    select cod_producto, fecha, stock_antes, tipo_operacion, origen,
           lag(stock_despues) over (partition by upper(btrim(cod_producto)) order by fecha, id_mov) prev,
           lag((fecha at time zone 'America/Lima')::date) over (partition by upper(btrim(cod_producto)) order by fecha, id_mov) prev_dia
      from wh.stock_movimientos where fecha >= now() - interval '90 days')
  select tipo_operacion, count(*) saltos, round(sum(abs(stock_antes - prev)),2) uds
    from s where prev is not null and prev_dia <> (fecha at time zone 'America/Lima')::date
      and abs(stock_antes - prev) >= 0.0005
   group by 1 order by 2 desc`)).rows);
await c.end();
