// 633 · TOGGLES 100% INDEPENDIENTES (decisión final del dueño, 2026-08-05):
//   · toggle "prendido" (estado)      → gobierna SOLO ME/catálogo
//   · toggle GO (canal_mayoreo)       → gobierna SOLO MosGo
//   Ninguno toca al otro, ni al encender ni al apagar. "Así no combinamos."
// Cambios: (a) catalogo_toggle_mosgo ON ya no enciende estado;
//          (b) ruta_boot lista por canal_mayoreo SIN mirar estado;
//          (c) ruta_pedido_crear valida por canal_mayoreo SIN mirar estado.
// (Se mantiene [631]: encender GO en presentación de granel auto-marca precio_fijo.)
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const rep = (s, from, to, etq) => {
  const n = s.split(from).length - 1;
  if (n !== 1) throw new Error(`[${etq}] esperaba 1, hay ${n}`);
  return s.replace(from, to);
};
const traer = async (fn) => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname=$1 and p.prokind='f' limit 1`, [fn])).rows[0].d;

let tog = await traer('catalogo_toggle_mosgo');
tog = rep(tog,
  `    -- Encender 🛵 enciende también el catálogo (todo lo de MosGo se vende en ME — decisión 1).
    update mos.productos set canal_mayoreo = true, estado = true where codigo_barra = v_cod;`,
  `    -- [633] INDEPENDIENTE: encender GO solo enciende el canal MosGo. El estado (ME)
    -- tiene su propio toggle y no se tocan entre sí ("así no combinamos" — el dueño).
    update mos.productos set canal_mayoreo = true where codigo_barra = v_cod;`,
  'on-independiente');

let boot = await traer('ruta_boot');
boot = rep(boot,
  `    select * from mos.productos
     where coalesce(estado, true) = true and canal_mayoreo = true`,
  `    select * from mos.productos
     where canal_mayoreo = true   -- [633] GO manda solo aquí; estado gobierna ME, no MosGo`,
  'boot-filtro');
boot = rep(boot,
  `           (coalesce(pr.canal_mayoreo,false) and coalesce(pr.estado,true)) as base_mosgo,`,
  `           coalesce(pr.canal_mayoreo, false) as base_mosgo,   -- [633] independiente de estado`,
  'boot-base');

let ped = await traer('ruta_pedido_crear');
ped = rep(ped,
  `     where codigo_barra = v_it->>'codigo_barra'
       and coalesce(estado, true) = true and canal_mayoreo = true`,
  `     where codigo_barra = v_it->>'codigo_barra'
       and canal_mayoreo = true   -- [633] GO manda solo; estado es el toggle de ME`,
  'pedido-filtro');

await c.query('begin');
await c.query(tog); await c.query(boot); await c.query(ped);
const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };
const master = (await c.query(`select nombre from mos.personal where upper(rol)='MASTER' limit 1`)).rows[0].nombre;

// producto APAGADO en ME + encender GO → estado NO cambia y aparece en MosGo igual
await c.query(`update mos.productos set canal_mayoreo=false, estado=false where codigo_barra='WHNAXMTO250GR'`);
const on = (await c.query(`select mos.catalogo_toggle_mosgo($1::jsonb) r`,
  [JSON.stringify({ codigoBarra: 'WHNAXMTO250GR', on: true, usuario: master })])).rows[0].r;
chk('encender GO NO toca el estado (independencia total)', on.ok === true && on.canalMayoreo === true && on.estado === false, JSON.stringify(on));
const boot1 = (await c.query(`select mos.ruta_boot('{}'::jsonb) r`)).rows[0].r;
chk('MosGo lo lista aunque esté apagado en ME (GO manda solo)',
  (boot1.familias || []).some(f => f.baseCod === 'WHNAXMTO250GR' && f.baseMosgo === true));
const ped1 = (await c.query(`select mos.ruta_pedido_crear($1::jsonb) r`, [JSON.stringify({
  local_id: 'T633-1', vendedor: 'TEST', items: [{ codigo_barra: 'WHNAXMTO250GR', cant: 2 }]
})])).rows[0].r;
chk('el pedido lo acepta (solo mira GO)', ped1.ok === true, JSON.stringify(ped1).slice(0, 90));
// y al revés: prendido en ME sin GO → fuera de MosGo
await c.query(`update mos.productos set canal_mayoreo=false, estado=true where codigo_barra='WHNAXMTO250GR'`);
const boot2 = (await c.query(`select mos.ruta_boot('{}'::jsonb) r`)).rows[0].r;
chk('sin GO no aparece en MosGo aunque esté prendido en ME',
  !(boot2.familias || []).some(f => f.baseCod === 'WHNAXMTO250GR'));
chk('apagar GO sigue sin tocar estado [632]', tog.includes('SOLO lo saca del canal MosGo'));
chk('auto precio_fijo de granel sigue [631]', /precio_fijo = true/.test(tog));
chk('guard SOLO_MASTER sigue', /SOLO_MASTER/.test(tog));

t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 110) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }
await c.query(tog); await c.query(boot); await c.query(ped);
console.log(`\n✅ ${t.length}/${t.length} — 633 aplicado: toggles independientes`);
fs.writeFileSync('633_toggles_independientes.sql', tog + '\n\n' + boot + '\n\n' + ped);
await c.end();
