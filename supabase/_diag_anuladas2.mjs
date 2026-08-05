// ¿Qué funciones cuentan ventas ANULADAS por filtrar sólo estado_envio?
// (anular_venta pone forma_pago='ANULADO' pero DEJA estado_envio='COMPLETADO')
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const fns = (await c.query(`select n.nspname||'.'||p.proname f, pg_get_functiondef(p.oid) d
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('me','mos','wh') and p.prokind='f'
   and pg_get_functiondef(p.oid) ~* 'me\\.ventas'`)).rows;

const riesgo = [], ok = [];
for (const { f, d } of fns) {
  const usaEstado = /estado_envio/i.test(d);
  const excluye = /ANULAD/i.test(d);
  if (usaEstado && !excluye) riesgo.push(f); else if (excluye) ok.push(f);
}
console.log(`funciones que tocan me.ventas: ${fns.length}`);
console.log(`\n❌ FILTRAN estado_envio y NO excluyen anuladas (${riesgo.length}):`);
riesgo.forEach(f => console.log('   ', f));
console.log(`\n✅ sí excluyen anuladas (${ok.length}):`);
ok.forEach(f => console.log('   ', f));

console.log('\n── plata en juego (60 días): ventas COMPLETADO+ANULADO');
console.table((await c.query(`
  select to_char(fecha at time zone 'America/Lima','YYYY-MM') mes, count(*) ventas,
         sum(coalesce(total,0))::numeric(12,2) soles_inflados
    from me.ventas
   where upper(coalesce(forma_pago,'')) like 'ANULADO%'
     and upper(coalesce(estado_envio,'')) = 'COMPLETADO'
     and fecha >= now() - interval '120 days'
   group by 1 order by 1 desc`)).rows);
await c.end();
