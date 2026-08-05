// 628 · MOSGO CONECTADO AL CATÁLOGO REAL (decisiones del dueño, 2026-08-05)
//
// 1. Columna mos.productos.precio_fijo (base de la regla "granel + presentación FIJO").
// 2. Limpieza del seed ficticio: canal_mayoreo=false en TODO (default OFF, el dueño
//    activa a mano) y tramos_mayoreo=null (obsoleto: la escalera son las presentaciones).
// 3. catalogo_pos_rls expone Precio_Fijo a ME (para que la caja cobre la etiqueta).
// 4. ruta_boot v2: FAMILIAS reales — base + escalones (presentaciones 🛵), precios del
//    catálogo, stock de almacén. Sin tramos.
// 5. ruta_pedido_crear v2: el precio SIEMPRE del catálogo (antes aceptaba el precio del
//    celular sin validar — hueco de dinero); ahorro calculado vs comprar suelto.
// 6. mos.catalogo_toggle_mosgo: el interruptor 🛵 con cascada (ON enciende catálogo+🛵;
//    OFF apaga ambos) y guard MASTER server-side.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };

// ── DDL fuera de la tx de prueba (idempotente e inofensiva)
await c.query(`alter table mos.productos add column if not exists precio_fijo boolean not null default false`);

// ── catalogo_pos_rls parchado desde la definición VIVA
let cat = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='mos' and p.proname='catalogo_pos_rls' and p.prokind='f'`)).rows[0].d;
const rep = (s, from, to, etq) => {
  const n = s.split(from).length - 1;
  if (n !== 1) throw new Error(`[${etq}] esperaba 1 coincidencia, hay ${n}`);
  return s.replace(from, to);
};
cat = rep(cat,
  `             id_producto, codigo_barra, descripcion, precio_venta,`,
  `             id_producto, codigo_barra, descripcion, precio_venta,
             coalesce(precio_fijo, false) as precio_fijo,   -- [628] presentación de granel con precio de etiqueta`,
  'act-cte');
cat = rep(cat,
  `            'Factor', coalesce((m->>'factor')::numeric, 1))`,
  `            'Factor', coalesce((m->>'factor')::numeric, 1),
            'Precio_Fijo', coalesce((m->>'precio_fijo')::boolean, false))`,
  'v_pr');

const RUTA_BOOT = `
create or replace function mos.ruta_boot(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_fam jsonb; v_clis jsonb; v_pct numeric;
begin
  -- [628] FAMILIAS: una por producto base (canónico o derivado). La escalera de una
  -- familia = su unidad base (si tiene 🛵) + sus presentaciones con 🛵. Los precios
  -- salen SIEMPRE del catálogo; el stock del almacén (base: kg o unidades).
  with go as (
    select * from mos.productos
     where coalesce(estado, true) = true and canal_mayoreo = true
  ),
  fam_keys as (
    select distinct coalesce(nullif(btrim(sku_base),''), id_producto) as fsku
      from go where tipo_producto::text <> 'PRESENTACION'
    union
    select distinct nullif(btrim(sku_base),'')
      from go where tipo_producto::text = 'PRESENTACION' and nullif(btrim(sku_base),'') is not null
  ),
  basep as (
    select k.fsku, pr.codigo_barra, pr.descripcion, pr.precio_venta,
           upper(coalesce(nullif(btrim(pr.unidad_medida),''), pr.unidad, 'NIU')) as um,
           (coalesce(pr.canal_mayoreo,false) and coalesce(pr.estado,true)) as base_mosgo,
           coalesce(s.cantidad_disponible, 0) as stock
      from fam_keys k
      join lateral (
        select * from mos.productos p
         where coalesce(nullif(btrim(p.sku_base),''), p.id_producto) = k.fsku
           and p.tipo_producto::text <> 'PRESENTACION'
           and coalesce(nullif(p.factor_conversion,0),1) = 1
         order by (upper(coalesce(nullif(btrim(p.unidad_medida),''), p.unidad,'')) = 'KGM') desc, p.id_producto
         limit 1) pr on true
      left join wh.stock s on upper(btrim(s.cod_producto)) = upper(btrim(pr.codigo_barra))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'fsku',       b.fsku,
           'baseCod',    b.codigo_barra,
           'baseNombre', b.descripcion,
           'baseUnidad', b.um,
           'basePrecio', coalesce(b.precio_venta, 0),
           'baseMosgo',  b.base_mosgo,
           'stockBase',  b.stock,
           'escalones',  coalesce((
              select jsonb_agg(jsonb_build_object(
                       'cod',    e.codigo_barra,
                       'nombre', e.descripcion,
                       'factor', coalesce(nullif(e.factor_conversion,0),1),
                       'precio', coalesce(e.precio_venta,0),
                       'fijo',   coalesce(e.precio_fijo,false)
                     ) order by coalesce(nullif(e.factor_conversion,0),1))
                from go e
               where e.tipo_producto::text = 'PRESENTACION'
                 and nullif(btrim(e.sku_base),'') = b.fsku), '[]'::jsonb)
         ) order by b.descripcion), '[]'::jsonb)
    into v_fam from basep b;

  select coalesce(jsonb_agg(jsonb_build_object(
    'documento', cf.documento, 'nombre', cf.nombre, 'tipo_doc', cf.tipo_doc,
    'direccion', coalesce(cf.direccion,''),
    'tipo_negocio', coalesce(ce.tipo_negocio,''), 'direccion_entrega', coalesce(ce.direccion_entrega,''),
    'telefono_wsp', coalesce(ce.telefono_wsp,''), 'dia_visita', coalesce(ce.dia_visita,''),
    'notas', coalesce(ce.notas,'')
  ) order by cf.nombre), '[]'::jsonb) into v_clis
  from me.clientes_frecuentes cf
  left join ruta.clientes_ext ce on ce.documento = cf.documento;

  select (v)::text::numeric into v_pct from ruta.config where k = 'comision_pct';
  -- 'productos' [] mantiene vivo al frontend viejo hasta que se actualice (mostrará vacío).
  return jsonb_build_object('ok', true, 'familias', v_fam, 'productos', '[]'::jsonb,
    'clientes', v_clis, 'comision_pct', coalesce(v_pct, 3));
end; $fn$;`;

const RUTA_PEDIDO = `
create or replace function mos.ruta_pedido_crear(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_local text := btrim(coalesce(p->>'local_id',''));
  v_vend  text := btrim(coalesce(p->>'vendedor',''));
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_it jsonb; v_total numeric := 0; v_ahorro numeric := 0; v_ajustados int := 0;
  v_cant numeric; v_pu numeric; v_pu_cli numeric; v_sub numeric;
  v_prod record; v_base_precio numeric; v_factor numeric;
  v_clean jsonb := '[]'::jsonb; v_id text; v_ex ruta.pedidos%rowtype;
begin
  if v_local = '' or v_vend = '' then return jsonb_build_object('ok', false, 'error', 'local_id y vendedor requeridos'); end if;
  if jsonb_array_length(v_items) = 0 then return jsonb_build_object('ok', false, 'error', 'pedido vacío'); end if;

  select * into v_ex from ruta.pedidos where local_id = v_local;
  if found then
    return jsonb_build_object('ok', true, 'id_pedido', v_ex.id_pedido, 'estado', v_ex.estado,
      'total', v_ex.total, 'dedup', true);
  end if;

  for v_it in select * from jsonb_array_elements(v_items) loop
    v_cant := coalesce((v_it->>'cant')::numeric, 0);
    if v_cant <= 0 then return jsonb_build_object('ok', false, 'error', 'cantidad inválida: ' || coalesce(v_it->>'codigo_barra','?')); end if;

    -- [628] EL PRECIO ES DEL CATÁLOGO, no del celular. Antes se aceptaba precio_unit
    -- del cliente sin validar: un request manipulado podía comprar a S/ 0.01.
    select codigo_barra, descripcion, precio_venta, sku_base,
           tipo_producto::text as tipo, coalesce(nullif(factor_conversion,0),1) as factor
      into v_prod
      from mos.productos
     where codigo_barra = v_it->>'codigo_barra'
       and coalesce(estado, true) = true and canal_mayoreo = true
     limit 1;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'ITEM_NO_MOSGO: ' || coalesce(v_it->>'codigo_barra','?'));
    end if;
    v_pu := round(coalesce(v_prod.precio_venta, 0), 2);
    if v_pu <= 0 then return jsonb_build_object('ok', false, 'error', 'SIN_PRECIO: ' || v_prod.codigo_barra); end if;
    v_pu_cli := coalesce((v_it->>'precio_unit')::numeric, v_pu);
    if abs(v_pu_cli - v_pu) > 0.009 then v_ajustados := v_ajustados + 1; end if;

    v_sub := round(v_cant * v_pu, 2);
    v_total := round(v_total + v_sub, 2);

    -- ahorro vs comprar suelto: solo presentaciones (factor>1) contra su unidad base
    if v_prod.tipo = 'PRESENTACION' and v_prod.factor > 1 then
      select precio_venta into v_base_precio from mos.productos
       where coalesce(nullif(btrim(sku_base),''), id_producto) = nullif(btrim(v_prod.sku_base),'')
         and tipo_producto::text <> 'PRESENTACION'
         and coalesce(nullif(factor_conversion,0),1) = 1
       limit 1;
      if v_base_precio is not null then
        v_ahorro := round(v_ahorro + greatest(0, round(v_cant * (v_prod.factor * v_base_precio - v_pu), 2)), 2);
      end if;
    end if;

    v_clean := v_clean || jsonb_build_object(
      'codigo_barra', v_prod.codigo_barra, 'descripcion', coalesce(v_prod.descripcion,''),
      'cant', v_cant, 'precio_unit', v_pu, 'subtotal', v_sub,
      'tramo', coalesce(v_it->>'tramo',''));
  end loop;

  v_id := 'R-' || lpad(nextval('ruta.seq_pedido')::text, 4, '0');
  insert into ruta.pedidos (id_pedido, local_id, documento_cliente, nombre_cliente, vendedor, id_vendedor,
    items, total, ahorro_total, fecha_entrega, nota)
  values (v_id, v_local, coalesce(p->>'documento_cliente',''), coalesce(p->>'nombre_cliente',''),
    v_vend, nullif(p->>'id_vendedor',''), v_clean, v_total, v_ahorro,
    nullif(p->>'fecha_entrega','')::date, coalesce(p->>'nota',''))
  on conflict (local_id) do nothing;
  return jsonb_build_object('ok', true, 'id_pedido', v_id, 'estado', 'CONFIRMADO',
    'total', v_total, 'ahorro', v_ahorro, 'ajustados', v_ajustados, 'items', v_clean);
end; $fn$;`;

const TOGGLE = `
create or replace function mos.catalogo_toggle_mosgo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod text := btrim(coalesce(p->>'codigoBarra',''));
  v_on boolean := coalesce((p->>'on')::boolean, false);
  v_usr text := btrim(coalesce(p->>'usuario',''));
  v_row record;
begin
  -- [628] Guard server-side: SOLO MASTER puede tocar el canal MosGo (decisión 5).
  if not exists (select 1 from mos.personal
                  where upper(btrim(nombre)) = upper(v_usr) and upper(coalesce(rol,'')) = 'MASTER') then
    return jsonb_build_object('ok', false, 'error', 'SOLO_MASTER');
  end if;
  if v_cod = '' then return jsonb_build_object('ok', false, 'error', 'Requiere codigoBarra'); end if;

  select codigo_barra, estado, canal_mayoreo into v_row from mos.productos where codigo_barra = v_cod;
  if not found then return jsonb_build_object('ok', false, 'error', 'NO_EXISTE'); end if;

  if v_on then
    -- Encender 🛵 enciende también el catálogo (todo lo de MosGo se vende en ME — decisión 1).
    update mos.productos set canal_mayoreo = true, estado = true where codigo_barra = v_cod;
  else
    -- Apagar 🛵 apaga AMBOS (decisión 3 del dueño: cascada en un solo gesto).
    update mos.productos set canal_mayoreo = false, estado = false where codigo_barra = v_cod;
  end if;

  select estado, canal_mayoreo into v_row from mos.productos where codigo_barra = v_cod;
  return jsonb_build_object('ok', true, 'codigoBarra', v_cod,
    'estado', v_row.estado, 'canalMayoreo', v_row.canal_mayoreo);
end; $fn$;`;

// ══ VERIFICACIÓN en tx (con el piloto nakamito simulado) ═══════════════════════
await c.query('begin');
await c.query(cat);
await c.query(RUTA_BOOT);
await c.query(RUTA_PEDIDO);
await c.query(TOGGLE);
// limpieza del seed dentro de la tx (se re-aplica al final)
const seed = (await c.query(`update mos.productos set canal_mayoreo = false where canal_mayoreo = true returning codigo_barra`)).rowCount;
await c.query(`update mos.productos set tramos_mayoreo = null where tramos_mayoreo is not null`);
chk(`seed ficticio apagado (${seed} productos vuelven a OFF)`, seed >= 1, seed);

// piloto simulado: granel + derivado 1kg + presentación x25 con precio fijo
await c.query(`update mos.productos set canal_mayoreo=true where codigo_barra in ('WHNAXMTO','WHNAXMTO001KG','P-NKMGLT-X25')`);
await c.query(`update mos.productos set precio_fijo=true where codigo_barra='P-NKMGLT-X25'`);

const boot = (await c.query(`select mos.ruta_boot('{}'::jsonb) r`)).rows[0].r;
const fams = boot.familias || [];
chk('boot v2 devuelve familias', Array.isArray(fams) && fams.length === 2, `n=${fams.length}`);
const fGranel = fams.find(f => f.fsku === 'LEV015');
const fKilo = fams.find(f => f.fsku === 'LEV1385');
chk('familia del granel existe con su escalón saco', !!fGranel && fGranel.escalones.length === 1, JSON.stringify(fGranel?.escalones?.map(e => e.cod)));
chk('el escalón trae precio del CATÁLOGO y marca fijo', fGranel?.escalones?.[0]?.precio === 155 && fGranel?.escalones?.[0]?.fijo === true,
    JSON.stringify(fGranel?.escalones?.[0]));
chk('la base granel es KGM con su precio por kg', fGranel?.baseUnidad === 'KGM' && fGranel?.basePrecio === 8);
chk('familia del envasado 1kg existe (base sola, sin escalones aún)', !!fKilo && fKilo.escalones.length === 0 && fKilo.baseMosgo === true);
chk('el stock del almacén viaja en la familia', typeof fGranel?.stockBase === 'number' || typeof fGranel?.stockBase === 'string');
chk('clientes y comisión siguen presentes', Array.isArray(boot.clientes) && boot.comision_pct !== undefined);

// pedido: precio manipulado por el cliente → manda el catálogo
const ped = (await c.query(`select mos.ruta_pedido_crear($1::jsonb) r`, [JSON.stringify({
  local_id: 'T628-' + 1, vendedor: 'TEST', items: [
    { codigo_barra: 'P-NKMGLT-X25', cant: 2, precio_unit: 0.01 },
    { codigo_barra: 'WHNAXMTO001KG', cant: 5, precio_unit: 8 }
  ]
})])).rows[0].r;
chk('pedido: el precio manipulado (0.01) se IGNORA y cobra catálogo', ped.ok === true && Number(ped.total) === 350, `total=${ped?.total} (155×2+8×5=350)`);
chk('pedido: avisa que ajustó 1 precio', Number(ped.ajustados) === 1, ped?.ajustados);
chk('pedido: ahorro vs suelto calculado (2×(25×8−155)=90)', Number(ped.ahorro) === 90, ped?.ahorro);
const pedMal = (await c.query(`select mos.ruta_pedido_crear($1::jsonb) r`, [JSON.stringify({
  local_id: 'T628-2', vendedor: 'TEST', items: [{ codigo_barra: '7751087002380', cant: 1 }]
})])).rows[0].r;
chk('pedido: un ítem SIN 🛵 se rechaza', pedMal.ok === false && /ITEM_NO_MOSGO/.test(pedMal.error || ''), pedMal?.error);

// toggle: guard MASTER + cascada
const master = (await c.query(`select nombre from mos.personal where upper(rol)='MASTER' limit 1`)).rows[0]?.nombre;
const tg1 = (await c.query(`select mos.catalogo_toggle_mosgo($1::jsonb) r`, [JSON.stringify({ codigoBarra: 'WHNAXMTO250GR', on: true, usuario: master })])).rows[0].r;
chk('toggle ON (MASTER): enciende 🛵 y catálogo', tg1.ok === true && tg1.canalMayoreo === true && tg1.estado === true, JSON.stringify(tg1));
const tg2 = (await c.query(`select mos.catalogo_toggle_mosgo($1::jsonb) r`, [JSON.stringify({ codigoBarra: 'WHNAXMTO250GR', on: false, usuario: master })])).rows[0].r;
chk('toggle OFF: apaga AMBOS (cascada decisión 3)', tg2.ok === true && tg2.canalMayoreo === false && tg2.estado === false, JSON.stringify(tg2));
const tg3 = (await c.query(`select mos.catalogo_toggle_mosgo($1::jsonb) r`, [JSON.stringify({ codigoBarra: 'WHNAXMTO250GR', on: true, usuario: 'CAJERO CUALQUIERA' })])).rows[0].r;
chk('toggle con usuario NO master → SOLO_MASTER', tg3.ok === false && tg3.error === 'SOLO_MASTER', JSON.stringify(tg3));

// catalogo_pos_rls: el flag viaja a ME
const pos = (await c.query(`select mos.catalogo_pos_rls() r`)).rows[0].r;
const presX25 = (pos?.data?.PRESENTACIONES || []).find(x => x.Cod_Barras === 'P-NKMGLT-X25');
chk('catalogo_pos_rls: la presentación lleva Precio_Fijo=true a ME', presX25?.Precio_Fijo === true, JSON.stringify(presX25 || null).slice(0, 120));
const presOtra = (pos?.data?.PRESENTACIONES || []).find(x => x.Precio_Fijo === false);
chk('las demás presentaciones viajan con Precio_Fijo=false (legacy intacto)', !!presOtra);

t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 110) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }

// ── APLICAR de verdad (sin el piloto: el dueño activa a mano, default OFF)
await c.query(cat);
await c.query(RUTA_BOOT);
await c.query(RUTA_PEDIDO);
await c.query(TOGGLE);
await c.query(`update mos.productos set canal_mayoreo = false where canal_mayoreo = true`);
await c.query(`update mos.productos set tramos_mayoreo = null where tramos_mayoreo is not null`);
console.log(`\n✅ ${t.length}/${t.length} — 628 aplicado · seed ficticio limpio · MosGo espera que actives con 🛵`);
fs.writeFileSync('628_mosgo_catalogo_real.sql',
  '-- 628 aplicado vía 628_mosgo_catalogo_real.mjs\n' + cat + '\n' + RUTA_BOOT + '\n' + RUTA_PEDIDO + '\n' + TOGGLE);
await c.end();
