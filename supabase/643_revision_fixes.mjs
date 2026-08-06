// 643 · FIXES de la revisión senior (agentes BD + Edge, hallazgos verificados):
//  SEGURIDAD: _tax_registrar / _ia_marcar_sust / clasificar_producto eran ejecutables con
//    la anon key (SECURITY DEFINER + PUBLIC execute) → revoke total.
//  DELTA INVISIBLE (el gordo): todo lo escrito en replica (fichas, marcas TONYS, categorías,
//    sustitutos) quedó con updated_at viejo → catalogo_wh_delta jamás lo envió a WH.
//    · ia_guardar ahora toca updated_at + bump de versión (goteo bajo, sin flood).
//    · sust_* NO tocan updated_at aún (evita inundar "editados recientes" y re-descargas
//      masivas durante el backfill; al integrar la UI se hace el touch+bump único).
//    · REMEDIACIÓN one-shot: touch de todos los productos con categoria_ia (1 bump).
//  ANTI-BUCLE de fichas: ia_intentos + mos.ia_marcar_intento (patrón sustitutos) en
//    ia_desc_pendientes E ia_repesca_pendientes.
//  CHURN de reciprocidad: sust_guardar ya no resetea sust_intentos y solo marca recíprocos
//    con sust_intentos < 3 → los 1,4xx nulls del backfill van primero.
//  sust_validar: cualquier eliminación re-encola (stale), no solo lista vacía.
//  ia_guardar: propagación del árbol con COALESCE (un canónico sin categoría no borra la
//    de sus hijos) · _ia_marcar_sust marca self + sus DERIVADOS.
//  Espejo: trigger también en UPDATE OF categoria_ia (updates puros espejan id_categoria).
//  sust_guardar: candidato debe ser de la MISMA categoría del líder.
//  taxonomia_config: gate _claim_ok() como el resto de RPCs authenticated.
//  Catálogo: 3 subcategorías curadas sin fila (Marshmallows/Celofán/Sorbetes) + OTROS/Por clasificar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const SQL = String.raw`
alter table mos.productos add column if not exists ia_intentos int not null default 0;

-- ── SEGURIDAD [rev-bd 2/3/4] ──
revoke all on function mos._tax_registrar(text, text) from public, anon, authenticated;
revoke all on function mos._ia_marcar_sust(text, text) from public, anon, authenticated;
revoke all on function mos.clasificar_producto(text, text) from public, anon, authenticated;

-- ── anti-bucle de fichas [rev-edge 1/4 · rev-bd 6] ──
create or replace function mos.ia_marcar_intento(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_n int;
begin
  set local session_replication_role = replica;
  update mos.productos set ia_intentos = ia_intentos + 1
   where codigo_barra in (select jsonb_array_elements_text(coalesce(p->'codigos','[]'::jsonb)));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'marcados', v_n);
end $fn$;
revoke all on function mos.ia_marcar_intento(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_marcar_intento(jsonb) to service_role;

create or replace function mos.ia_desc_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object(
             'codigo_barra', pr.codigo_barra,
             'descripcion',  pr.descripcion,
             'marca_actual', coalesce(nullif(btrim(pr.marca),''),''),
             'equivalentes', coalesce((select string_agg(e.codigo_barra, ', ')
                                         from mos.equivalencias e
                                        where e.sku_base = pr.sku_base and e.activo), '')
           ) as x
      from mos.productos pr
     where pr.tipo_producto::text = 'CANONICO'
       and coalesce(pr.estado, true) = true
       and coalesce(pr.es_insumo, false) = false
       and length(btrim(pr.descripcion)) >= 6
       and pr.descripcion !~* '^[0-9 .,x*/-]+\s*(metros?|unidades?|mil(lar)?|cm|mm|gr?|kg|ml|lt|litros?)?\.?\s*$'
       and ( pr.ia_refresh = true
          or (pr.descripcion_ia is null
              and coalesce(pr.fecha_creacion, pr.created_at) > now() - interval '7 days') )
     order by pr.ia_intentos asc, pr.ia_refresh desc, coalesce(pr.fecha_creacion, pr.created_at) desc
     limit least(greatest(coalesce((p->>'max')::int, 2), 1), 5)
  ) t;
$fn$;
revoke all on function mos.ia_desc_pendientes(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_desc_pendientes(jsonb) to service_role;

-- ── _ia_marcar_sust: self + sus derivados [rev-bd 10] ──
create or replace function mos._ia_marcar_sust(p_cod text, p_sub text)
returns void language sql security definer set search_path to '' as $fn$
  update mos.productos set sust_stale = true
   where codigo_barra = p_cod
      or (tipo_producto::text = 'DERIVADO' and coalesce(estado, true)
          and codigo_producto_base = (select sku_base from mos.productos where codigo_barra = p_cod));
$fn$;
revoke all on function mos._ia_marcar_sust(text, text) from public, anon, authenticated;

-- ── ia_guardar v5: updated_at + bump + coalesce en el árbol [rev-bd 1/8] ──
create or replace function mos.ia_guardar_descripcion(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod text := btrim(coalesce(p->>'codigoBarra',''));
  v_txt text := coalesce(p->>'texto','');
  v_marca text := btrim(coalesce(p->>'marca',''));
  v_pcat text := upper(btrim(coalesce(p->>'categoriaProp','')));
  v_psub text := btrim(coalesce(p->>'subcategoriaProp',''));
  v_prop jsonb := case when v_pcat <> '' and v_psub <> ''
                       then jsonb_build_object('categoria', v_pcat, 'subcategoria', v_psub) end;
  v_sku text; v_refresh boolean; v_cat jsonb; v_n int;
begin
  if v_cod = '' then return jsonb_build_object('ok',false,'error','codigoBarra requerido'); end if;
  if length(v_txt) < 60 or position('🏷' in v_txt) = 0 or position('✅' in v_txt) = 0 then
    return jsonb_build_object('ok',false,'error','FORMATO: faltan las líneas 🏷…✅');
  end if;
  select sku_base, coalesce(ia_refresh,false) into v_sku, v_refresh
    from mos.productos where codigo_barra = v_cod and tipo_producto::text = 'CANONICO';
  if v_sku is null then return jsonb_build_object('ok',false,'error','canónico no existe'); end if;

  set local session_replication_role = replica;
  update mos.productos
     set descripcion_ia = v_txt,
         marca = case when v_refresh and v_marca <> '' then v_marca
                      when nullif(btrim(coalesce(marca,'')),'') is null and v_marca <> '' then v_marca
                      else marca end,
         categoria_ia = case when v_refresh or categoria_ia is null
                                  or categoria_ia->>'subcategoria' = 'Por clasificar'
                             then coalesce(mos.clasificar_producto(descripcion, null), v_prop,
                                           mos.clasificar_producto(descripcion, v_txt), categoria_ia)
                             else categoria_ia end,
         ia_refresh = false, ia_intentos = 0,
         updated_at = now()                                   -- [643] visible en el delta WH
   where codigo_barra = v_cod and tipo_producto::text = 'CANONICO';
  get diagnostics v_n = row_count;
  if v_n <> 1 then return jsonb_build_object('ok',false,'actualizados',v_n); end if;

  select categoria_ia into v_cat from mos.productos where codigo_barra = v_cod;
  if v_cat is not null then
    perform mos._tax_registrar(v_cat->>'categoria', v_cat->>'subcategoria');
    update mos.productos set id_categoria = v_cat->>'categoria'
     where codigo_barra = v_cod and id_categoria is distinct from (v_cat->>'categoria');
  end if;

  -- árbol completo con COALESCE (un canónico sin categoría no borra la de sus hijos)
  update mos.productos d
     set descripcion_ia = coalesce(c.descripcion_ia, d.descripcion_ia),
         categoria_ia = coalesce(c.categoria_ia, d.categoria_ia),
         id_categoria = coalesce(c.categoria_ia->>'categoria', d.id_categoria),
         marca = 'TONYS', updated_at = now()
    from mos.productos c
   where c.codigo_barra = v_cod and c.tipo_producto::text='CANONICO'
     and d.tipo_producto::text = 'DERIVADO' and d.codigo_producto_base = c.sku_base;
  update mos.productos pr
     set descripcion_ia = coalesce(c.descripcion_ia, pr.descripcion_ia),
         categoria_ia = coalesce(c.categoria_ia, pr.categoria_ia),
         id_categoria = coalesce(c.categoria_ia->>'categoria', pr.id_categoria),
         marca = case when nullif(btrim(coalesce(c.marca,'')),'') is not null then c.marca else pr.marca end,
         updated_at = now()
    from mos.productos c
   where c.codigo_barra = v_cod and c.tipo_producto::text='CANONICO'
     and pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = c.sku_base;
  update mos.productos pr
     set descripcion_ia = coalesce(d.descripcion_ia, pr.descripcion_ia),
         categoria_ia = coalesce(d.categoria_ia, pr.categoria_ia),
         id_categoria = coalesce(d.categoria_ia->>'categoria', pr.id_categoria),
         marca = 'TONYS', updated_at = now()
    from mos.productos d
   where d.tipo_producto::text = 'DERIVADO' and d.codigo_producto_base = v_sku
     and pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = d.sku_base;

  perform mos._ia_marcar_sust(v_cod, v_cat->>'subcategoria');
  -- bump manual (replica apaga el trigger de versión) → ME/GO/WH re-jalan el cambio
  update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1;

  return jsonb_build_object('ok', true, 'actualizados', 1, 'refresh', v_refresh,
    'categoria', v_cat->>'categoria', 'subcategoria', v_cat->>'subcategoria');
end; $fn$;
revoke all on function mos.ia_guardar_descripcion(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_guardar_descripcion(jsonb) to service_role;

-- ── sust_guardar v3: sin reset de intentos + guard de categoría + reciprocidad acotada [rev-bd 5/11] ──
create or replace function mos.sust_guardar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod text := btrim(coalesce(p->>'codigoBarra',''));
  v_h record; v_raiz text; v_catg text;
  v_int jsonb := '[]'::jsonb; v_ext jsonb := '[]'::jsonb;
  e jsonb; t record; v_n int := 0; v_rec int := 0;
begin
  if v_cod = '' then return jsonb_build_object('ok',false,'error','codigoBarra requerido'); end if;
  select codigo_barra, sku_base, categoria_ia->>'categoria' catg,
         coalesce(nullif(btrim(codigo_producto_base),''), sku_base) raiz
    into v_h from mos.productos
   where codigo_barra = v_cod and tipo_producto::text in ('CANONICO','DERIVADO');
  if v_h.codigo_barra is null then return jsonb_build_object('ok',false,'error','líder no existe'); end if;
  v_raiz := v_h.raiz; v_catg := v_h.catg;

  for e in select * from jsonb_array_elements(coalesce(p->'internos','[]'::jsonb)) loop
    exit when jsonb_array_length(v_int) >= 3;
    select cd.sku_base, cd.codigo_barra, cd.descripcion, cd.categoria_ia->>'subcategoria' sub
      into t from mos.productos cd
     where cd.codigo_barra = btrim(coalesce(e->>'cod',''))
       and cd.tipo_producto::text in ('CANONICO','DERIVADO')
       and coalesce(cd.estado, true)
       and coalesce(nullif(btrim(cd.codigo_producto_base),''), cd.sku_base) <> v_raiz
       and (v_catg is null or cd.categoria_ia->>'categoria' = v_catg);   -- misma categoría que el líder
    if t.codigo_barra is not null then
      v_int := v_int || jsonb_build_object('sku', t.sku_base, 'cod', t.codigo_barra,
        'nombre', t.descripcion, 'sub', t.sub, 'motivo', left(btrim(coalesce(e->>'motivo','')), 140));
    end if;
  end loop;

  for e in select * from jsonb_array_elements(coalesce(p->'externos','[]'::jsonb)) loop
    exit when jsonb_array_length(v_ext) >= 3;
    if btrim(coalesce(e->>'nombre','')) <> '' then
      v_ext := v_ext || jsonb_build_object(
        'nombre', left(btrim(e->>'nombre'), 120), 'marca', left(btrim(coalesce(e->>'marca','')), 60),
        'presentacion', left(btrim(coalesce(e->>'presentacion','')), 90),
        'motivo', left(btrim(coalesce(e->>'motivo','')), 140));
    end if;
  end loop;

  -- sin bump ni updated_at TODAVÍA: las apps no consumen sustitutos (al integrar la UI se
  -- hace el touch único); sust_intentos NO se resetea (evita que el churn recíproco
  -- adelante a los null del backfill) [rev-bd 5]
  set local session_replication_role = replica;
  update mos.productos
     set sustitutos_internos = v_int, sustitutos_externos = v_ext, sust_stale = false
   where codigo_barra = v_cod;
  update mos.productos pr
     set sustitutos_internos = v_int, sustitutos_externos = v_ext
   where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = v_h.sku_base;
  get diagnostics v_n = row_count;

  update mos.productos t2
     set sust_stale = true
   where t2.codigo_barra in (select jsonb_array_elements(v_int)->>'cod')
     and t2.sustitutos_internos is not null
     and t2.sust_stale = false
     and t2.sust_intentos < 3                                   -- acotado [rev-bd 5]
     and not exists (select 1 from jsonb_array_elements(t2.sustitutos_internos) z
                      where z->>'cod' = v_cod);
  get diagnostics v_rec = row_count;

  return jsonb_build_object('ok', true, 'internos', jsonb_array_length(v_int),
    'externos', jsonb_array_length(v_ext), 'presentaciones', v_n, 'reciprocos', v_rec);
end $fn$;
revoke all on function mos.sust_guardar(jsonb) from public, anon, authenticated;
grant execute on function mos.sust_guardar(jsonb) to service_role;

-- ── sust_validar v2: cualquier eliminación re-encola [rev-bd 7] ──
create or replace function mos.sust_validar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_n int;
begin
  set local session_replication_role = replica;
  with filtrados as (
    select h.codigo_barra cb,
           coalesce(jsonb_agg(e) filter (where exists (
             select 1 from mos.productos t
              where t.codigo_barra = e->>'cod' and coalesce(t.estado, true)
                and t.tipo_producto::text in ('CANONICO','DERIVADO')
                and t.categoria_ia->>'subcategoria' = e->>'sub')), '[]'::jsonb) nuevo
      from mos.productos h
      cross join lateral jsonb_array_elements(h.sustitutos_internos) e
     where h.tipo_producto::text in ('CANONICO','DERIVADO')
       and h.sustitutos_internos is not null and jsonb_array_length(h.sustitutos_internos) > 0
     group by h.codigo_barra
  )
  update mos.productos h
     set sustitutos_internos = f.nuevo,
         sust_stale = true                                      -- se degradó → re-evaluar
    from filtrados f
   where h.codigo_barra = f.cb and h.sustitutos_internos is distinct from f.nuevo;
  get diagnostics v_n = row_count;
  update mos.productos pr
     set sustitutos_internos = l.sustitutos_internos
    from mos.productos l
   where l.tipo_producto::text in ('CANONICO','DERIVADO') and pr.tipo_producto::text = 'PRESENTACION'
     and pr.sku_base = l.sku_base and pr.sustitutos_internos is distinct from l.sustitutos_internos;
  return jsonb_build_object('ok', true, 'limpiados', v_n);
end $fn$;
revoke all on function mos.sust_validar(jsonb) from public, anon, authenticated;
grant execute on function mos.sust_validar(jsonb) to service_role;

-- ── espejo también en updates puros de categoria_ia [rev-bd 9] ──
drop trigger if exists tg_herencia_ficha on mos.productos;
create trigger tg_herencia_ficha before insert or update of descripcion, codigo_barra, categoria_ia
  on mos.productos for each row execute function mos._tg_herencia_ficha();

-- ── taxonomia_config con gate de app [rev-bd 14] ──
create or replace function mos.taxonomia_config(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select case when not mos._claim_ok() then '[]'::jsonb else (
  with cnt as (
    select categoria_ia->>'categoria' cat, categoria_ia->>'subcategoria' sub, count(*) n
      from mos.productos
     where coalesce(estado,true) and categoria_ia is not null
     group by 1, 2
  ),
  subs as (
    select t.categoria, t.subcategoria, t.descripcion, t.ejemplos, t.auto,
           coalesce(c1.n, 0) n
      from mos.taxonomia_catalogo t
      left join cnt c1 on c1.cat = t.categoria and c1.sub = t.subcategoria
  )
  select coalesce(jsonb_agg(x order by x->>'categoria'), '[]'::jsonb) from (
    select jsonb_build_object(
      'categoria',  s.categoria,
      'nombre',     coalesce(mc.nombre, initcap(replace(s.categoria,'_',' '))),
      'descripcion', coalesce(mc.descripcion, ''),
      'productos',  (select coalesce(sum(n),0) from subs z where z.categoria = s.categoria),
      'subcategorias', (select jsonb_agg(jsonb_build_object(
          'subcategoria', z.subcategoria, 'descripcion', z.descripcion,
          'ejemplos', z.ejemplos, 'auto', z.auto, 'productos', z.n) order by z.n desc, z.subcategoria)
        from subs z where z.categoria = s.categoria)
    ) x
    from (select distinct categoria from subs) s
    left join mos.categorias mc on mc.id_categoria = s.categoria
  ) t(x) ) end;
$fn$;
revoke all on function mos.taxonomia_config(jsonb) from public, anon;
grant execute on function mos.taxonomia_config(jsonb) to authenticated, service_role;

-- ── filas curadas faltantes del catálogo [rev-bd 13] ──
insert into mos.taxonomia_catalogo (categoria, subcategoria, descripcion, ejemplos, auto) values
 ('CONFITERIA','Marshmallows','Incluye: marshmallow, masmelo.','',false),
 ('DESCARTABLES','Celofán y empaques','Incluye: celofán, empaques transparentes.','',false),
 ('DESCARTABLES','Sorbetes y removedores','Incluye: sorbete, cañita, removedor.','',false),
 ('OTROS','Por clasificar','Productos que el clasificador aún no ubica — la IA los refina al llegar su ficha.','',false)
on conflict (categoria, subcategoria) do nothing;`;

const T = []; const chk = (n, cond, x) => { T.push([cond ? '✅' : '❌', n, x]); return cond; };

// ══ FASE 1: tests (tx + ROLLBACK) ══
await c.query('begin');
await c.query(SQL);
// 1) seguridad: anon fuera de las 5
{
  const g = (await c.query(`select bool_or(has_function_privilege('anon', p.oid, 'execute')) mal
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='mos' and p.proname in ('_tax_registrar','_ia_marcar_sust','clasificar_producto','ia_marcar_intento','sust_guardar')`)).rows[0];
  chk('anon sin execute en las funciones sensibles', g.mal === false, '');
}
// 2) espejo en update puro de categoria_ia
{
  const p0 = (await c.query(`select codigo_barra from mos.productos where tipo_producto::text='CANONICO' and categoria_ia is not null limit 1`)).rows[0].codigo_barra;
  await c.query(`update mos.productos set categoria_ia = jsonb_build_object('categoria','TESTESP643','subcategoria','S') where codigo_barra=$1`, [p0]);
  const r = (await c.query(`select id_categoria from mos.productos where codigo_barra=$1`, [p0])).rows[0];
  chk('update puro de categoria_ia espeja id_categoria', r.id_categoria === 'TESTESP643', r.id_categoria);
}
// 3) ia_guardar: updated_at fresco + versión bumpeada + intentos reseteados
{
  const v0 = (await c.query(`select version from mos.catalogo_meta where id=1`)).rows[0].version;
  await c.query(`insert into mos.productos (id_producto, sku_base, codigo_barra, descripcion, tipo_producto, estado, precio_venta, fecha_creacion, ia_intentos)
    values ('IDT643','LEVT643','TEST643','VINAGRE BLANCO TEST 1LT','CANONICO',true,5,now(),4)`);
  await c.query(`set local session_replication_role = origin`);
  const txt = '🏷 Marca: T643\n🧪 Hecho de: t\n📋 Composición: t\n📦 Presentación: t\n🎨 Características: texto de prueba con longitud suficiente aquí\n✅ Usos y beneficios: t';
  const g = (await c.query(`select mos.ia_guardar_descripcion($1::jsonb) r`, [JSON.stringify({ codigoBarra: 'TEST643', texto: txt, marca: '' })])).rows[0].r;
  await c.query(`set local session_replication_role = origin`);
  const r = (await c.query(`select updated_at > now() - interval '10 seconds' fresco, ia_intentos from mos.productos where codigo_barra='TEST643'`)).rows[0];
  const v1 = (await c.query(`select version from mos.catalogo_meta where id=1`)).rows[0].version;
  chk('ia_guardar: updated_at fresco + bump de versión + ia_intentos=0',
    g.ok === true && r.fresco === true && r.ia_intentos === 0 && Number(v1) > Number(v0), `v ${v0}→${v1}`);
}
// 4) ia_marcar_intento + orden de pendientes
{
  const m = (await c.query(`select mos.ia_marcar_intento($1::jsonb) r`, [JSON.stringify({ codigos: ['TEST643'] })])).rows[0].r;
  await c.query(`set local session_replication_role = origin`);
  const n = (await c.query(`select ia_intentos from mos.productos where codigo_barra='TEST643'`)).rows[0].ia_intentos;
  chk('ia_marcar_intento incrementa', m.ok === true && n === 1, 'intentos=' + n);
}
// 5) sust_guardar: NO resetea intentos + rechaza candidato de otra categoría + reciprocidad acotada
{
  const h = (await c.query(`select p.codigo_barra, p.categoria_ia->>'categoria' cat from mos.productos p
    where p.tipo_producto::text='CANONICO' and p.sustitutos_internos is not null and jsonb_array_length(p.sustitutos_internos)>0 limit 1`)).rows[0];
  const otro = (await c.query(`select codigo_barra from mos.productos
    where tipo_producto::text='CANONICO' and coalesce(estado,true) and categoria_ia->>'categoria' <> $1
      and categoria_ia is not null limit 1`, [h.cat])).rows[0].codigo_barra;
  const mismo = (await c.query(`select cd.codigo_barra from mos.productos cd, mos.productos h2
    where h2.codigo_barra=$1 and cd.tipo_producto::text='CANONICO' and coalesce(cd.estado,true)
      and cd.categoria_ia->>'categoria' = $2 and cd.sku_base <> h2.sku_base and cd.codigo_barra <> $1 limit 1`, [h.codigo_barra, h.cat])).rows[0].codigo_barra;
  await c.query(`update mos.productos set sust_intentos = 2 where codigo_barra=$1`, [h.codigo_barra]);
  const g = (await c.query(`select mos.sust_guardar($1::jsonb) r`, [JSON.stringify({
    codigoBarra: h.codigo_barra, internos: [{ cod: otro, motivo: 'otra cat' }, { cod: mismo, motivo: 'misma cat' }], externos: [] })])).rows[0].r;
  await c.query(`set local session_replication_role = origin`);
  const r = (await c.query(`select sust_intentos from mos.productos where codigo_barra=$1`, [h.codigo_barra])).rows[0];
  chk('sust_guardar: rechaza cross-categoría + conserva intentos', g.ok === true && g.internos === 1 && r.sust_intentos === 2, JSON.stringify(g));
}
// 6) sust_validar: eliminación → stale
{
  const h = (await c.query(`select codigo_barra from mos.productos where sustitutos_internos is not null and jsonb_array_length(sustitutos_internos)>0 and tipo_producto::text in ('CANONICO','DERIVADO') limit 1`)).rows[0].codigo_barra;
  await c.query(`update mos.productos set sust_stale=false,
    sustitutos_internos = sustitutos_internos || '[{"sku":"X","cod":"MUERTO643","nombre":"x","sub":"Nada"}]'::jsonb where codigo_barra=$1`, [h]);
  await c.query(`select mos.sust_validar('{}'::jsonb)`);
  await c.query(`set local session_replication_role = origin`);
  const r = (await c.query(`select sust_stale from mos.productos where codigo_barra=$1`, [h])).rows[0];
  chk('sust_validar: cualquier eliminación re-encola (stale)', r.sust_stale === true, '');
}
// 7) taxonomia_config con claim ajeno → []
{
  await c.query(`select set_config('request.jwt.claims', '{"app":"WHX"}', true)`);
  const r = (await c.query(`select mos.taxonomia_config('{}'::jsonb) r`)).rows[0].r;
  await c.query(`select set_config('request.jwt.claims', '', true)`);
  chk('taxonomia_config gateada por _claim_ok', Array.isArray(r) && r.length === 0, 'len=' + r.length);
}
// 8) filas curadas presentes
{
  const n = (await c.query(`select count(*) n from mos.taxonomia_catalogo where (categoria,subcategoria) in
    (('CONFITERIA','Marshmallows'),('DESCARTABLES','Celofán y empaques'),('DESCARTABLES','Sorbetes y removedores'),('OTROS','Por clasificar'))`)).rows[0].n;
  chk('catálogo: 4 filas curadas presentes', Number(n) === 4, 'n=' + n);
}
T.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 120) : ''));
const fallos = T.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} — NO se aplica`); await c.end(); process.exit(1); }

// ══ FASE 2: aplicar + REMEDIACIÓN del delta invisible ══
await c.query('begin');
await c.query(SQL);
await c.query('commit');
// touch one-shot: todo lo que la IA tocó en replica se vuelve visible para el delta WH
const tb = await c.query(`update mos.productos set updated_at = now() where categoria_ia is not null`);
console.log(`\n✅ ${T.length}/${T.length} — 643 aplicado · remediación delta: ${tb.rowCount} productos re-fechados (1 bump)`);
await c.end();
