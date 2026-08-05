// 631 · (a) Marca el Pack x25 de nakamito como PRECIO FIJO (existía de antes de la regla:
//         sin la marca, MosGo lo oculta y ME lo cobraría por kg → 25×8=200 en vez de 155).
//       (b) catalogo_toggle_mosgo: al ENCENDER una presentación de granel que venga sin
//         la marca, se la pone solo (decisión 4: todo escalón tiene SU precio de etiqueta).
//         Así ningún otro pack legacy vuelve a "desaparecer" de MosGo.
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
  `  if v_on then
    -- Encender 🛵 enciende también el catálogo (todo lo de MosGo se vende en ME — decisión 1).
    update mos.productos set canal_mayoreo = true, estado = true where codigo_barra = v_cod;`,
  `  if v_on then
    -- Encender 🛵 enciende también el catálogo (todo lo de MosGo se vende en ME — decisión 1).
    update mos.productos set canal_mayoreo = true, estado = true where codigo_barra = v_cod;
    -- [631] presentación de un granel (base KGM) sin precio_fijo → se marca sola: en el
    -- canal GO todo escalón se cobra a etiqueta; sin la marca, MosGo la oculta y ME la
    -- cobraría por kg (precio mentiroso). Solo al ENCENDER, decisión explícita del MASTER.
    update mos.productos pr set precio_fijo = true
     where pr.codigo_barra = v_cod
       and pr.tipo_producto::text = 'PRESENTACION'
       and coalesce(pr.precio_fijo, false) = false
       and exists (select 1 from mos.productos b
                    where coalesce(nullif(btrim(b.sku_base),''), b.id_producto) = nullif(btrim(pr.sku_base),'')
                      and b.tipo_producto::text <> 'PRESENTACION'
                      and coalesce(nullif(b.factor_conversion,0),1) = 1
                      and upper(coalesce(nullif(btrim(b.unidad_medida),''), b.unidad,'')) = 'KGM');`,
  'auto-fijo');

def = rep(def,
  `  select estado, canal_mayoreo into v_row from mos.productos where codigo_barra = v_cod;
  return jsonb_build_object('ok', true, 'codigoBarra', v_cod,
    'estado', v_row.estado, 'canalMayoreo', v_row.canal_mayoreo);`,
  `  select estado, canal_mayoreo, precio_fijo into v_row from mos.productos where codigo_barra = v_cod;
  return jsonb_build_object('ok', true, 'codigoBarra', v_cod,
    'estado', v_row.estado, 'canalMayoreo', v_row.canal_mayoreo, 'precioFijo', v_row.precio_fijo);`,
  'return');

await c.query('begin');
await c.query(def);
const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };
const master = (await c.query(`select nombre from mos.personal where upper(rol)='MASTER' limit 1`)).rows[0]?.nombre;

// caso real: apagar la marca del x25 y encenderlo por el toggle → debe marcarse sola
await c.query(`update mos.productos set precio_fijo=false where codigo_barra='P-NKMGLT-X25'`);
const r1 = (await c.query(`select mos.catalogo_toggle_mosgo($1::jsonb) r`,
  [JSON.stringify({ codigoBarra: 'P-NKMGLT-X25', on: true, usuario: master })])).rows[0].r;
chk('encender GO una presentación de granel le pone precio_fijo solo', r1.ok === true && r1.precioFijo === true, JSON.stringify(r1));

// una presentación de base NIU no se toca (su precio ya es de etiqueta por naturaleza)
const presNiu = (await c.query(`select pr.codigo_barra from mos.productos pr
  join mos.productos b on coalesce(nullif(btrim(b.sku_base),''), b.id_producto) = nullif(btrim(pr.sku_base),'')
   and b.tipo_producto::text <> 'PRESENTACION' and coalesce(nullif(b.factor_conversion,0),1) = 1
   and upper(coalesce(nullif(btrim(b.unidad_medida),''), b.unidad,'')) <> 'KGM'
  where pr.tipo_producto::text='PRESENTACION' and coalesce(pr.precio_fijo,false)=false limit 1`)).rows[0]?.codigo_barra;
if (presNiu) {
  await c.query(`select mos.catalogo_toggle_mosgo($1::jsonb)`, [JSON.stringify({ codigoBarra: presNiu, on: true, usuario: master })]);
  chk('una presentación de base NIU no se marca (no lo necesita)',
    (await c.query(`select precio_fijo from mos.productos where codigo_barra=$1`, [presNiu])).rows[0].precio_fijo === false, presNiu);
}
// boot: la familia granel ya trae su escalón saco con fijo=true
const boot = (await c.query(`select mos.ruta_boot('{}'::jsonb) r`)).rows[0].r;
const fG = (boot.familias || []).find(f => f.fsku === 'LEV015');
chk('ruta_boot: la familia granel muestra el saco (fijo=true, S/155)',
  !!fG && fG.escalones.some(e => e.cod === 'P-NKMGLT-X25' && e.fijo === true && Number(e.precio) === 155),
  JSON.stringify(fG?.escalones));
chk('el guard SOLO_MASTER sigue', /SOLO_MASTER/.test(def));
chk('la cascada de apagado sigue intacta', def.includes('set canal_mayoreo = false, estado = false'));

t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 120) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }

await c.query(def);
// el fix inmediato del dato real: el x25 ya activado queda marcado FIJO
await c.query(`update mos.productos set precio_fijo=true
  where codigo_barra='P-NKMGLT-X25' and coalesce(precio_fijo,false)=false`);
const vivo = (await c.query(`select precio_fijo, canal_mayoreo, precio_venta from mos.productos where codigo_barra='P-NKMGLT-X25'`)).rows[0];
console.log(`\n✅ ${t.length}/${t.length} — 631 aplicado · P-NKMGLT-X25 →`, JSON.stringify(vivo));
fs.writeFileSync('631_saco_fijo_auto.sql', def);
await c.end();
