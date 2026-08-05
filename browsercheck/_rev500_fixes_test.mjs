// Revisión de TODOS los fixes de la auditoría 500x (618/617/619/620/621).
// Verifica el código Y el efecto real en la BD de producción (solo lectura).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };
const mos = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js', 'utf8');
const wh  = fs.readFileSync('C:/Users/ISO/ecosistema MOS/warehouseMos/js/app.js', 'utf8');
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const def = async (s, f) => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname=$1 and p.proname=$2 and p.prokind='f'`, [s, f])).rows[0]?.d || '';

console.log('══ 618 · fuga de datos fiscales');
const acl = (await c.query(`select p.proname, coalesce(pg_catalog.array_to_string(p.proacl,'|'),'') acl
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='me' and p.proname in ('tributario_cpe_mes','tributario_ventas_mes')`)).rows;
t('ninguna RPC tributaria es pública', acl.every(r => !/(^|\|)=X/.test(r.acl)), JSON.stringify(acl));
t('siguen accesibles para la app (authenticated)', acl.every(r => /authenticated=X/.test(r.acl)));

console.log('══ 617 · los tres agujeros de dinero');
const dCob = await def('me', 'cobrar_credito_directo'), dCon = await def('me', 'confirmar_cobro');
t('cobrar_credito_directo valida el método', dCob.includes('METODO_INVALIDO'));
t('confirmar_cobro valida el método', dCon.includes('METODO_INVALIDO'));
t('la whitelist acepta MIXTO (que es legítimo)', dCob.includes("not like 'MIXTO%'"));
const dMp = await def('mos', 'marcar_pagos');
t('marcar_pagos excluye los cobros ASIGNADOS', dMp.includes('creditos_cobro_asignado ca'));
const dDt = await def('me', 'datos_turno');
t('el arqueo excluye PLANILLA (3 filtros)', (dDt.match(/not in \('CREDITO','PLANILLA'\)/g) || []).length === 3);
t('no quedó ningún filtro viejo', !dDt.includes("t->>'metodo' <> 'CREDITO'"));

console.log('══ 619 · doble descuento de stock (WH)');
t('el baseline se re-siembra del servidor, no del JSON', /despachadoBaseline:\s*desp0,/.test(wh));
t('ya no confía en el baseline que viene en el item', !/despachadoBaseline:\s*\(it\.despachadoBaseline != null/.test(wh));
t('se conservan constancia y horas al normalizar', /\.\.\.it,\s*\n\s*skuBase:/.test(wh));

console.log('══ 620 · zona con la cuenta corriente congelada');
const dCt = await def('wh', 'consolidar_pickups_todas');
t('el cron ya levanta acumuladores EN_PROCESO', dCt.includes("'PENDIENTE','PARCIAL','EN_PROCESO'"));
const atasc = (await c.query(`select count(*) n from wh.pickups
  where id_pickup like 'PCK-ACU-%' and upper(coalesce(estado,''))='EN_PROCESO'
    and coalesce(ultima_actividad, fecha_creado) < now() - interval '3 hours'`)).rows[0];
t('no quedan acumuladores congelados', parseInt(atasc.n) === 0, 'n=' + atasc.n);

console.log('══ 621 · comprobante anulado + escapado');
t('BAJA se evalúa ANTES que "aceptado"', /const esBaja = \(est === 'BAJA'\);\s*\n\s*const chip = esBaja/.test(mos));
t('el anulado avisa que no se envíe al cliente', mos.includes('No se lo envíes al cliente'));
t('se ocultan las acciones de envío si está de baja', mos.includes("acc.classList.toggle('hidden', esBaja)"));
const escs = mos.match(/^  function _esc\(s\) \{[^\n]*/gm) || [];
t('las 2 definiciones de _esc escapan la comilla simple', escs.length === 2 && escs.every(s => /'/.test(s) && s.includes('#39')), escs.length + ' defs');

console.log('══ no se rompió nada de lo anterior');
t('sigue el lock anti doble-cobro', dCob.includes("pg_advisory_xact_lock(hashtext('cobro:'"));
t('sigue el libro de créditos por planilla', dMp.includes('insert into mos.creditos_planilla'));
const dCz = await def('wh', 'consolidar_pickup_zona');
t('la constancia sinSku sigue viva (606)', dCz.includes('SINSKU::'));
t('las horas por evento siguen vivas (607)', dCz.includes('tsSolicitud'));
const dPu = await def('mos', 'prov_stock_ubicaciones');
t('proveedores: comprar vs envasar sigue (615)', dPu.includes('falta_comprar_eq'));
t('proveedores: unidad real sigue (615)', dPu.includes('padre_unidad'));

console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
await c.end();
process.exit(fail === 0 ? 0 : 1);
