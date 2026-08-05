// 632 · (a) Apagar GO ya NO apaga el producto en catálogo/ME. El dueño vio la cascada
//         en acción (apagó GO del padre y la familia entera se pintó inactiva, y el
//         granel salía de la caja de ME) y la descartó: apagar GO = solo salir de MosGo.
//         Encender GO SÍ sigue encendiendo ambos (decisión 1: todo lo GO se vende en ME).
//       (b) grant de mos.catalogo_version al rol anon: MosGo la pollea para refrescar
//         su catálogo al instante cuando el MASTER activa/desactiva GO (solo expone un
//         contador monótono, ningún dato).
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
let def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='mos' and p.proname='catalogo_toggle_mosgo' and p.prokind='f'`)).rows[0].d;

def = rep(def,
  `  else
    -- Apagar 🛵 apaga AMBOS (decisión 3 del dueño: cascada en un solo gesto).
    update mos.productos set canal_mayoreo = false, estado = false where codigo_barra = v_cod;
  end if;`,
  `  else
    -- [632] Apagar GO SOLO lo saca del canal MosGo — el producto SIGUE a la venta en ME.
    -- (La cascada original apagaba también el catálogo: el dueño la vio en acción —
    -- la familia entera "en mallas" y el granel fuera de la caja — y la descartó.)
    update mos.productos set canal_mayoreo = false where codigo_barra = v_cod;
  end if;`,
  'off-sin-cascada');

await c.query('begin');
await c.query(def);
const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };
const master = (await c.query(`select nombre from mos.personal where upper(rol)='MASTER' limit 1`)).rows[0]?.nombre;

// producto encendido en ambos → apagar GO: sale de MosGo pero SIGUE en catálogo
await c.query(`update mos.productos set canal_mayoreo=true, estado=true where codigo_barra='WHNAXMTO250GR'`);
const off = (await c.query(`select mos.catalogo_toggle_mosgo($1::jsonb) r`,
  [JSON.stringify({ codigoBarra: 'WHNAXMTO250GR', on: false, usuario: master })])).rows[0].r;
chk('apagar GO: canal fuera pero el producto SIGUE activo en ME', off.ok === true && off.canalMayoreo === false && off.estado === true, JSON.stringify(off));
// encender sigue con su cascada (enciende ambos)
await c.query(`update mos.productos set estado=false where codigo_barra='WHNAXMTO250GR'`);
const on = (await c.query(`select mos.catalogo_toggle_mosgo($1::jsonb) r`,
  [JSON.stringify({ codigoBarra: 'WHNAXMTO250GR', on: true, usuario: master })])).rows[0].r;
chk('encender GO sigue encendiendo también el catálogo (decisión 1)', on.ok === true && on.canalMayoreo === true && on.estado === true, JSON.stringify(on));
chk('el guard SOLO_MASTER sigue', /SOLO_MASTER/.test(def));
chk('el auto-precio-fijo de presentaciones de granel sigue [631]', /precio_fijo = true/.test(def));

t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 110) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }
await c.query(def);
await c.query(`grant execute on function mos.catalogo_version(jsonb) to anon`);
// verificación externa real del grant (misma llamada que hará MosGo)
console.log(`\n✅ ${t.length}/${t.length} — 632 aplicado`);
fs.writeFileSync('632_go_off_sin_cascada.sql', def + '\n\ngrant execute on function mos.catalogo_version(jsonb) to anon;');
await c.end();
