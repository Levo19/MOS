// 617 · Tres agujeros en el camino del DINERO (revisión 500x, domingo/créditos).
// Se parchean las definiciones VIVAS (pg_get_functiondef), no los .sql del repo.
//
// #1 me.confirmar_cobro / me.cobrar_credito_directo: escribían `forma_pago` CRUDO desde el
//    cliente. Con metodoFinal='CREDITO' el ticket quedaba cobrado-en-caja Y vivo-como-crédito
//    → la liquidación del domingo lo descuenta OTRA VEZ de la planilla (el trabajador paga dos
//    veces: efectivo + jornal). Ahora solo se aceptan EFECTIVO / VIRTUAL / MIXTO*.
// #2 mos.marcar_pagos (autoConsumos): no miraba `me.creditos_cobro_asignado`. Si el admin
//    liquidaba mientras un cobro estaba ASIGNADO a un cajero, el ticket pasaba a PLANILLA, el
//    cajero cobraba el efectivo igual y al confirmar el sistema lo rechazaba → plata en mano
//    sin dónde registrarla. Ahora esos tickets se excluyen del barrido automático.
// #3 me.datos_turno: PLANILLA caía en la rama "else" y se contaba como VIRTUAL → arqueo
//    inflado con dinero que nunca entró (pasó de verdad el 02/08: S/2.00 fantasma).
//
// Idempotente: si el guard ya está, no vuelve a insertarlo. Se prueba en tx+ROLLBACK antes
// de aplicar de verdad.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();

const getDef = async (sch, fn) => (await c.query(
  `select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname=$1 and p.proname=$2 and p.prokind='f'`, [sch, fn])).rows[0].d;

const GUARD = (v) => `
  -- [617] whitelist de método: el valor venía CRUDO del cliente y un 'CREDITO' dejaba el
  -- ticket cobrado en caja Y vivo como crédito → la planilla lo descontaba otra vez.
  if ${v} not in ('EFECTIVO','VIRTUAL') and ${v} not like 'MIXTO%' then
    return jsonb_build_object('ok',false,'error','METODO_INVALIDO');
  end if;
`;

const parches = [];

// ── #1a confirmar_cobro ────────────────────────────────────────────────────
{
  let d = await getDef('me', 'confirmar_cobro');
  const ancla = `if v_metodo  = '' then return jsonb_build_object('ok',false,'error','metodoFinal requerido'); end if;`;
  if (d.includes('METODO_INVALIDO')) console.log('· me.confirmar_cobro ya tenía el guard');
  else if (!d.includes(ancla)) throw new Error('ancla no encontrada en me.confirmar_cobro');
  else parches.push(['me.confirmar_cobro', d.replace(ancla, ancla + GUARD('v_metup'))]);
}
// ── #1b cobrar_credito_directo ─────────────────────────────────────────────
{
  let d = await getDef('me', 'cobrar_credito_directo');
  const ancla = `if v_metodo  = '' then return jsonb_build_object('ok',false,'error','metodo requerido'); end if;`;
  if (d.includes('METODO_INVALIDO')) console.log('· me.cobrar_credito_directo ya tenía el guard');
  else if (!d.includes(ancla)) throw new Error('ancla no encontrada en me.cobrar_credito_directo');
  else parches.push(['me.cobrar_credito_directo', d.replace(ancla, ancla + GUARD('v_metup'))]);
}
// ── #2 marcar_pagos: excluir del barrido lo que ya está asignado a un cajero ─
{
  let d = await getDef('mos', 'marcar_pagos');
  const ancla = `           and upper(coalesce(v.forma_pago,'')) = 'CREDITO'`;
  const add = `
           -- [617] no barrer un ticket que un cajero tiene ASIGNADO para cobrar: pasaba a
           -- PLANILLA, el cajero cobraba el efectivo igual y no tenía dónde registrarlo.
           and not exists (select 1 from me.creditos_cobro_asignado ca
                            where ca.id_venta = v.id_venta
                              and upper(coalesce(ca.estado,'')) = 'ASIGNADO')`;
  if (d.includes('creditos_cobro_asignado ca')) console.log('· mos.marcar_pagos ya excluía asignados');
  else if (!d.includes(ancla)) throw new Error('ancla no encontrada en mos.marcar_pagos');
  else parches.push(['mos.marcar_pagos', d.replace(ancla, ancla + add)]);
}
// ── #3 datos_turno: PLANILLA no es dinero del turno ─────────────────────────
{
  let d = await getDef('me', 'datos_turno');
  const viejo = `where t->>'metodo' <> 'CREDITO'`;
  const nuevo = `where t->>'metodo' not in ('CREDITO','PLANILLA')   -- [617] PLANILLA no entra al arqueo`;
  const n = (d.match(/where t->>'metodo' <> 'CREDITO'/g) || []).length;
  if (d.includes("not in ('CREDITO','PLANILLA')")) console.log('· me.datos_turno ya excluía PLANILLA');
  else if (n !== 3) throw new Error('esperaba 3 filtros en datos_turno, hay ' + n);
  else parches.push(['me.datos_turno', d.split(viejo).join(nuevo)]);
}

console.log('\nfunciones a parchar:', parches.map(p => p[0]).join(', ') || '(ninguna)');
if (!parches.length) { await c.end(); process.exit(0); }

// ── ENSAYO en tx + ROLLBACK ────────────────────────────────────────────────
await c.query('begin');
try {
  for (const [fn, sql] of parches) { await c.query(sql); console.log('  ensayo OK ·', fn); }
  // el arqueo del caso real: la caja que quedó inflada por PLANILLA (firma: text)
  const r = (await c.query(`select me.datos_turno('CAJA-1785673718540') j`)).rows[0].j;
  const d = (r && r.data) || r || {};
  console.log('  arqueo tras el fix → virtual:', d.virtual ?? d.virtualFinal, '· efectivo:', d.efectivo);
} finally { await c.query('rollback'); }
console.log('ensayo revertido. Aplicando de verdad…\n');

for (const [fn, sql] of parches) { await c.query(sql); console.log('✅ aplicado ·', fn); }
await c.end();
