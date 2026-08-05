// 618 · URGENTE — cerrar la fuga de datos fiscales y el enumerado de comprobantes.
//
// R1 (🔴): me.tributario_cpe_mes / me.tributario_ventas_mes son SECURITY DEFINER con
//   EXECUTE para PUBLIC (incluye `anon`). Con la anon key —que es pública, va en api.js—
//   cualquiera en internet lista los 668 CPE con RUC/DNI del cliente, totales, hash y el
//   enlace al PDF (que NubeFact sirve sin autenticación). Verificado: HTTP 200, 165 KB.
// R2 (🔴): mos.fac_pdf_por_venta acepta `correlativo` como fallback. El correlativo es
//   secuencial y adivinable → cualquier dispositivo válido enumera FM02-000001..N y baja
//   el PDF/XML/QR de cualquier cliente y de cualquier zona.
//
// Se verifica ANTES y DESPUÉS. Nada de esto rompe a la app: MOS llama estas RPC con JWT
// de app (rol authenticated + claim app), no como anon.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();

const acl = async () => (await c.query(`
  select p.proname, pg_catalog.array_to_string(p.proacl,' | ') acl
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='me' and p.proname in ('tributario_cpe_mes','tributario_ventas_mes')
   order by 1`)).rows;

console.log('── ACL ANTES:');
console.table(await acl());

// 1) quitar el acceso público/anónimo a las RPC tributarias
for (const fn of ['tributario_cpe_mes', 'tributario_ventas_mes']) {
  const sigs = (await c.query(`
    select pg_get_function_identity_arguments(p.oid) args
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='me' and p.proname=$1`, [fn])).rows;
  for (const s of sigs) {
    await c.query(`revoke all on function me.${fn}(${s.args}) from public`);
    await c.query(`revoke all on function me.${fn}(${s.args}) from anon`);
    await c.query(`grant execute on function me.${fn}(${s.args}) to service_role, authenticated`);
    console.log(`  ✔ me.${fn}(${s.args}) → solo service_role + authenticated`);
  }
}
console.log('── ACL DESPUÉS:');
console.table(await acl());

// 2) fac_pdf_por_venta: matar el fallback por correlativo (enumerable)
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='mos' and p.proname='fac_pdf_por_venta' and p.prokind='f'`)).rows[0];
if (!d) { console.log('  (mos.fac_pdf_por_venta no existe)'); }
else if (d.d.includes('[618]')) { console.log('  · fac_pdf_por_venta ya estaba cerrada'); }
else {
  const viejo = `where (v_idv is not null and id_venta = v_idv)
      or (v_corr is not null and correlativo = v_corr)`;
  const alt = d.d.match(/where \(v_idv is not null and id_venta\s*=\s*v_idv\)[\s\S]{0,120}?correlativo\s*=\s*v_corr\)/);
  if (!alt) { console.log('  ⚠ no ubiqué el where; reviso manualmente'); console.log(d.d.split('\n').filter(l=>/v_corr|v_idv/.test(l)).join('\n')); }
  else {
    const nuevo = `where id_venta = v_idv   -- [618] sin fallback por correlativo: era enumerable
      and v_idv is not null`;
    await c.query(d.d.replace(alt[0], nuevo));
    console.log('  ✔ mos.fac_pdf_por_venta: fallback por correlativo eliminado');
  }
}
await c.end();
