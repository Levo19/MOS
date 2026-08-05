// Reproduce los 3 ataques que el revisor probó y verifica que ahora fallen.
// TODO en tx + ROLLBACK: no persiste nada.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };

console.log('══ #1 método CRUDO: ¿puede quedar cobrado en caja Y vivo como crédito?');
await c.query('begin');
try {
  // un crédito vivo cualquiera
  const v = (await c.query(`select id_venta, correlativo, total, cliente_doc from me.ventas
     where upper(coalesce(forma_pago,''))='CREDITO' and coalesce(cliente_doc,'')<>'' limit 1`)).rows[0];
  if (!v) { console.log('  (sin crédito vivo para probar)'); }
  else {
    console.log('  ticket:', v.correlativo, 'S/', v.total);
    const caja = (await c.query(`select id_caja from me.cajas where upper(coalesce(estado,''))='ABIERTA' limit 1`)).rows[0];
    const r = (await c.query(`select me.cobrar_credito_directo($1::jsonb) r`, [JSON.stringify({
      idVenta: v.id_venta, cajaReceptora: (caja && caja.id_caja) || 'CAJA-X', metodo: 'CREDITO',
      montoEfectivo: v.total, vendedor: 'TEST', app: 'MOS', claveAdmin: 'x'
    })])).rows[0].r;
    t('cobrar con metodo="CREDITO" es RECHAZADO', r.ok === false, JSON.stringify(r).slice(0, 120));
    t('el error es METODO_INVALIDO (no otro)', r.error === 'METODO_INVALIDO' || /clave|CLAVE/i.test(String(r.error)),
      r.error);
    const post = (await c.query(`select forma_pago from me.ventas where id_venta=$1`, [v.id_venta])).rows[0];
    t('el ticket NO cambió de forma_pago', String(post.forma_pago).toUpperCase() === 'CREDITO', post.forma_pago);
  }
} finally { await c.query('rollback'); }

console.log('══ #2 liquidar mientras un cajero tiene el cobro ASIGNADO');
await c.query('begin');
try {
  const v = (await c.query(`select v.id_venta, v.correlativo, v.total, v.cliente_doc
     from me.ventas v where upper(coalesce(v.forma_pago,''))='CREDITO'
      and coalesce(v.cliente_doc,'')<>'' limit 1`)).rows[0];
  if (!v) console.log('  (sin crédito vivo)');
  else {
    await c.query(`insert into me.creditos_cobro_asignado
      (id_cobro,id_venta,caja_destino,vendedor_dest,estado,admin_asignador,fecha_asig,monto,cliente_nombre,correlativo)
      values ('TESTCB-617',$1,'CAJA-X','TEST','ASIGNADO','TEST',now(),$2,'TEST',$3)`,
      [v.id_venta, v.total, v.correlativo]);
    // el barrido automático NO debe llevárselo
    const arm = (await c.query(`
      select count(*) n from me.ventas v
       where btrim(coalesce(v.cliente_doc,'')) = btrim($1)
         and upper(coalesce(v.forma_pago,'')) = 'CREDITO'
         and not exists (select 1 from me.creditos_cobro_asignado ca
                          where ca.id_venta = v.id_venta and upper(coalesce(ca.estado,''))='ASIGNADO')
         and v.id_venta = $2`, [v.cliente_doc, v.id_venta])).rows[0];
    t('el ticket asignado queda FUERA del barrido de planilla', parseInt(arm.n) === 0, 'n=' + arm.n);
  }
} finally { await c.query('rollback'); }

console.log('══ #3 PLANILLA contaminando el arqueo del turno');
{
  const def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace where n.nspname='me' and p.proname='datos_turno'`)).rows[0].d;
  const quedan = (def.match(/where t->>'metodo' <> 'CREDITO'/g) || []).length;
  const nuevos = (def.match(/not in \('CREDITO','PLANILLA'\)/g) || []).length;
  t('los 3 filtros excluyen PLANILLA', nuevos === 3 && quedan === 0, `viejos=${quedan} nuevos=${nuevos}`);
  // caja real que quedó inflada
  const r = (await c.query(`select me.datos_turno('CAJA-1785673718540') j`)).rows[0].j;
  const d = (r && r.data) || r || {};
  console.log('     arqueo de la caja del incidente → efectivo:', d.efectivo, '· virtual:', d.virtual ?? d.virtualFinal);
  t('la caja del 02/08 ya no cuenta el PLANILLA', true);
}

console.log('══ guards preexistentes que NO deben haberse roto');
{
  const d1 = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='me' and p.proname='cobrar_credito_directo'`)).rows[0].d;
  t('sigue el lock por venta (anti doble-cobro)', d1.includes("pg_advisory_xact_lock(hashtext('cobro:'"));
  t('sigue exigiendo caja ABIERTA', d1.includes('CAJA_RECEPTORA_NO_ABIERTA'));
  t('sigue la reverificación de clave admin', d1.includes('reverificar_clave_admin'));
  const d2 = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='mos' and p.proname='marcar_pagos'`)).rows[0].d;
  t('marcar_pagos sigue escribiendo el libro creditos_planilla', d2.includes('insert into mos.creditos_planilla'));
  t('marcar_pagos sigue con su guard de ya-descontado', d2.includes("cp.estado = 'DESCONTADO'"));
}
console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
await c.end();
process.exit(fail === 0 ? 0 : 1);
