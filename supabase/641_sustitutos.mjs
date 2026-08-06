// 641 · SUSTITUTOS de producto (decisión dueño): ayudar al vendedor a satisfacer al cliente.
//   · mos.productos.sustitutos_internos / sustitutos_externos (jsonb, 1–3 c/u) — SOLO en
//     LÍDERES (CANONICO y DERIVADO: el granel y la bolsa 250gr sustituyen distinto).
//     Las PRESENTACIONES los heredan del líder. La FAMILIA queda excluida (el 250gr no es
//     "sustituto" del 50gr: es el mismo producto — ese nivel lo resuelve el catálogo en vivo).
//   · sust_stale + sust_intentos: frescura. Detonantes: ficha nueva/actualizada (ia_guardar)
//     → self + PARES de subcategoría stale (así Alacena re-evalúa cuando entra Alpaso);
//     líder NUEVO → pares stale; validador SQL quita referencias muertas o que cambiaron
//     de subcategoría (mayonesa→ketchup) y re-marca stale si la lista queda vacía.
//   · RPCs service_role: sust_pendientes (con CANDIDATOS pre-filtrados por SQL: misma
//     categoría, subcategoría primero, sin familia) · sust_guardar (re-valida server-side)
//     · sust_marcar_intento (los que fallan se van al fondo de la cola) · sust_validar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const DDL = String.raw`
alter table mos.productos add column if not exists sustitutos_internos jsonb;
alter table mos.productos add column if not exists sustitutos_externos jsonb;
alter table mos.productos add column if not exists sust_stale boolean not null default false;
alter table mos.productos add column if not exists sust_intentos int not null default 0;

-- líderes pendientes + sus candidatos internos (la IA SOLO puede elegir de esta lista)
create or replace function mos.sust_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  with lid as (
    select pr.codigo_barra, pr.descripcion, pr.marca, pr.unidad, pr.descripcion_ia,
           pr.tipo_producto::text tipo,
           pr.categoria_ia->>'categoria' catg, pr.categoria_ia->>'subcategoria' subc,
           coalesce(nullif(btrim(pr.codigo_producto_base),''), pr.sku_base) raiz
      from mos.productos pr
     where pr.tipo_producto::text in ('CANONICO','DERIVADO')
       and coalesce(pr.estado, true) and coalesce(pr.es_insumo, false) = false
       and pr.descripcion_ia is not null and pr.categoria_ia is not null
       and (pr.sust_stale or pr.sustitutos_internos is null)
     order by pr.sust_intentos asc, pr.sust_stale desc, pr.codigo_barra
     limit least(greatest(coalesce((p->>'max')::int, 2), 1), 5)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'codigo_barra', l.codigo_barra, 'descripcion', l.descripcion,
      'marca', coalesce(l.marca, ''), 'unidad', coalesce(l.unidad, ''),
      'tipo', l.tipo, 'categoria', l.catg, 'subcategoria', l.subc,
      'ficha', l.descripcion_ia, 'candidatos', cand.arr)), '[]'::jsonb)
    from lid l
    cross join lateral (
      select coalesce(jsonb_agg(x.j), '[]'::jsonb) arr from (
        select jsonb_build_object('sku', cd.sku_base, 'cod', cd.codigo_barra,
                 'nombre', cd.descripcion, 'sub', cd.categoria_ia->>'subcategoria') j
          from mos.productos cd
         where cd.tipo_producto::text in ('CANONICO','DERIVADO')
           and coalesce(cd.estado, true) and coalesce(cd.es_insumo, false) = false
           and cd.categoria_ia->>'categoria' = l.catg
           and coalesce(nullif(btrim(cd.codigo_producto_base),''), cd.sku_base) <> l.raiz
           and cd.codigo_barra <> l.codigo_barra
         order by (cd.categoria_ia->>'subcategoria' = l.subc) desc, length(cd.descripcion)
         limit 40
      ) x
    ) cand;
$fn$;
revoke all on function mos.sust_pendientes(jsonb) from public, anon, authenticated;
grant execute on function mos.sust_pendientes(jsonb) to service_role;

-- anti-bucle: los tomados suben intento (los que fallan se hunden en la cola)
create or replace function mos.sust_marcar_intento(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_n int;
begin
  set local session_replication_role = replica;
  update mos.productos set sust_intentos = sust_intentos + 1
   where codigo_barra in (select jsonb_array_elements_text(coalesce(p->'codigos','[]'::jsonb)));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'marcados', v_n);
end $fn$;
revoke all on function mos.sust_marcar_intento(jsonb) from public, anon, authenticated;
grant execute on function mos.sust_marcar_intento(jsonb) to service_role;

-- guardar con RE-VALIDACIÓN server-side: cada interno debe existir, estar activo y NO ser familia
create or replace function mos.sust_guardar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod text := btrim(coalesce(p->>'codigoBarra',''));
  v_h record; v_raiz text;
  v_int jsonb := '[]'::jsonb; v_ext jsonb := '[]'::jsonb;
  e jsonb; t record; v_n int := 0;
begin
  if v_cod = '' then return jsonb_build_object('ok',false,'error','codigoBarra requerido'); end if;
  select codigo_barra, sku_base, coalesce(nullif(btrim(codigo_producto_base),''), sku_base) raiz
    into v_h from mos.productos
   where codigo_barra = v_cod and tipo_producto::text in ('CANONICO','DERIVADO');
  if v_h.codigo_barra is null then return jsonb_build_object('ok',false,'error','líder no existe'); end if;
  v_raiz := v_h.raiz;

  for e in select * from jsonb_array_elements(coalesce(p->'internos','[]'::jsonb)) loop
    exit when jsonb_array_length(v_int) >= 3;
    select cd.sku_base, cd.codigo_barra, cd.descripcion, cd.categoria_ia->>'subcategoria' sub
      into t from mos.productos cd
     where cd.codigo_barra = btrim(coalesce(e->>'cod',''))
       and cd.tipo_producto::text in ('CANONICO','DERIVADO')
       and coalesce(cd.estado, true)
       and coalesce(nullif(btrim(cd.codigo_producto_base),''), cd.sku_base) <> v_raiz;
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

  -- sin bump (las apps aún no consumen esto) + herencia explícita a las presentaciones del líder
  set local session_replication_role = replica;
  update mos.productos
     set sustitutos_internos = v_int, sustitutos_externos = v_ext,
         sust_stale = false, sust_intentos = 0
   where codigo_barra = v_cod;
  update mos.productos pr
     set sustitutos_internos = v_int, sustitutos_externos = v_ext
   where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = v_h.sku_base;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'internos', jsonb_array_length(v_int),
    'externos', jsonb_array_length(v_ext), 'presentaciones', v_n);
end $fn$;
revoke all on function mos.sust_guardar(jsonb) from public, anon, authenticated;
grant execute on function mos.sust_guardar(jsonb) to service_role;

-- validador (cron, sin IA): quita referencias muertas/inactivas o que CAMBIARON de
-- subcategoría (mayonesa→ketchup); si la lista queda vacía → stale para regenerar
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
         sust_stale = case when jsonb_array_length(f.nuevo) < 1 then true else h.sust_stale end
    from filtrados f
   where h.codigo_barra = f.cb and h.sustitutos_internos is distinct from f.nuevo;
  get diagnostics v_n = row_count;
  -- reflejar limpieza en las presentaciones de los líderes tocados (mismo criterio simple)
  update mos.productos pr
     set sustitutos_internos = l.sustitutos_internos
    from mos.productos l
   where l.tipo_producto::text in ('CANONICO','DERIVADO') and pr.tipo_producto::text = 'PRESENTACION'
     and pr.sku_base = l.sku_base and pr.sustitutos_internos is distinct from l.sustitutos_internos;
  return jsonb_build_object('ok', true, 'limpiados', v_n);
end $fn$;
revoke all on function mos.sust_validar(jsonb) from public, anon, authenticated;
grant execute on function mos.sust_validar(jsonb) to service_role;`;

// trigger de herencia v4: presentaciones nacen con sustitutos del líder · líder nuevo → pares stale
const FICHA = String.raw`
create or replace function mos._tg_herencia_ficha() returns trigger
language plpgsql security definer set search_path to '' as $fn$
declare v_l record;
begin
  if tg_op = 'INSERT' then
    if new.tipo_producto::text = 'CANONICO' then
      if new.categoria_ia is null then
        new.categoria_ia := coalesce(
          mos.clasificar_producto(new.descripcion, new.descripcion_ia),
          case when nullif(btrim(coalesce(new.id_categoria,'')),'') is not null
               then jsonb_build_object('categoria', new.id_categoria, 'subcategoria', 'Por clasificar') end);
      end if;
    elsif new.tipo_producto::text = 'PRESENTACION' then
      select marca, descripcion_ia, categoria_ia, sustitutos_internos, sustitutos_externos
        into v_l from mos.productos
       where sku_base = new.sku_base and tipo_producto::text in ('CANONICO','DERIVADO')
         and codigo_barra is distinct from new.codigo_barra
       order by (descripcion_ia is not null) desc, (codigo_barra !~* '^PRE[0-9]') desc, length(descripcion) desc
       limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
        new.sustitutos_internos := coalesce(v_l.sustitutos_internos, new.sustitutos_internos);
        new.sustitutos_externos := coalesce(v_l.sustitutos_externos, new.sustitutos_externos);
        if nullif(btrim(coalesce(v_l.marca,'')),'') is not null then new.marca := v_l.marca; end if;
      end if;
    elsif new.tipo_producto::text = 'DERIVADO' then
      select descripcion_ia, categoria_ia into v_l from mos.productos
       where sku_base = new.codigo_producto_base and tipo_producto::text = 'CANONICO'
       order by (descripcion_ia is not null) desc, (codigo_barra !~* '^PRE[0-9]') desc, length(descripcion) desc
       limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
      end if;
      new.marca := 'TONYS';
    end if;
    -- [641] líder nuevo → sus PARES de subcategoría re-evalúan sustitutos (caso Alpaso/Alacena)
    if new.tipo_producto::text in ('CANONICO','DERIVADO') and new.categoria_ia is not null then
      update mos.productos p2 set sust_stale = true
       where p2.tipo_producto::text in ('CANONICO','DERIVADO') and coalesce(p2.estado, true)
         and p2.categoria_ia->>'subcategoria' = new.categoria_ia->>'subcategoria'
         and coalesce(nullif(btrim(p2.codigo_producto_base),''), p2.sku_base)
             <> coalesce(nullif(btrim(new.codigo_producto_base),''), new.sku_base);
    end if;
  elsif tg_op = 'UPDATE' and new.tipo_producto::text = 'CANONICO'
        and (new.descripcion is distinct from old.descripcion
          or new.codigo_barra is distinct from old.codigo_barra) then
    new.categoria_ia := coalesce(mos.clasificar_producto(new.descripcion, new.descripcion_ia), new.categoria_ia);
    new.ia_refresh := true;
    new.sust_stale := true;   -- identidad cambió → sustitutos a re-evaluar
  end if;
  if new.categoria_ia is not null then
    new.id_categoria := coalesce(new.categoria_ia->>'categoria', new.id_categoria);
    perform mos._tax_registrar(new.categoria_ia->>'categoria', new.categoria_ia->>'subcategoria');
  end if;
  return new;
end $fn$;`;

// ia_guardar v4: ficha nueva/actualizada → self + pares de subcategoría stale
const IA_SUST = String.raw`
create or replace function mos._ia_marcar_sust(p_cod text, p_sub text)
returns void language sql security definer set search_path to '' as $fn$
  update mos.productos set sust_stale = true
   where (codigo_barra = p_cod)
      or (tipo_producto::text in ('CANONICO','DERIVADO') and coalesce(estado, true)
          and categoria_ia->>'subcategoria' = p_sub and codigo_barra <> p_cod);
$fn$;`;

const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };

// ══ FASE 1: tests (tx + ROLLBACK) ══
await c.query('begin');
await c.query(DDL); await c.query(FICHA); await c.query(IA_SUST);
// parchear ia_guardar VIVA para añadir el marcado (sin re-declarar todo el cuerpo aquí)
{
  const def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='ia_guardar_descripcion'`)).rows[0].d;
  if (!/_ia_marcar_sust/.test(def)) {
    const nuevo = def.replace(
      `  return jsonb_build_object('ok', true, 'actualizados', 1, 'refresh', v_refresh,`,
      `  perform mos._ia_marcar_sust(v_cod, v_cat->>'subcategoria');   -- [641] sustitutos a re-evaluar (self+pares)\n  return jsonb_build_object('ok', true, 'actualizados', 1, 'refresh', v_refresh,`);
    if (nuevo === def) throw new Error('ancla de ia_guardar no encontrada');
    await c.query(nuevo);
  }
}

// líder real con familia para probar candados: un canónico con derivados
const lider = (await c.query(`select p.codigo_barra, p.sku_base, p.categoria_ia->>'subcategoria' sub
  from mos.productos p
  where p.tipo_producto::text='CANONICO' and coalesce(p.estado,true) and p.descripcion_ia is not null
    and exists (select 1 from mos.productos d where d.tipo_producto::text='DERIVADO' and d.codigo_producto_base=p.sku_base)
    and exists (select 1 from mos.productos pr2 where pr2.tipo_producto::text='PRESENTACION' and pr2.sku_base=p.sku_base)
  limit 1`)).rows[0];

// 1) pendientes: incluye al líder marcado, con candidatos SIN su familia
await c.query(`update mos.productos set sust_stale=true where codigo_barra=$1`, [lider.codigo_barra]);
{
  const r = (await c.query(`select mos.sust_pendientes('{"max":5}'::jsonb) r`)).rows[0].r;
  const yo = r.find(x => x.codigo_barra === lider.codigo_barra);
  const fam = (await c.query(`select array_agg(codigo_barra) a from mos.productos
    where coalesce(nullif(btrim(codigo_producto_base),''), sku_base) = $1`, [lider.sku_base])).rows[0].a || [];
  const sinFam = yo && yo.candidatos.every(cd => !fam.includes(cd.cod));
  chk('pendientes trae al líder con candidatos sin su familia', !!yo && yo.candidatos.length > 0 && sinFam,
    `cands=${yo?.candidatos.length} fam=${fam.length}`);
  // 2) guardar: elige el 1er candidato válido + 1 externo → guarda, limpia stale, hereda a presentaciones
  const cand = yo.candidatos[0];
  const g = (await c.query(`select mos.sust_guardar($1::jsonb) r`, [JSON.stringify({
    codigoBarra: lider.codigo_barra,
    internos: [{ cod: cand.cod, motivo: 'prueba' }, { cod: fam[1] || 'XNOEXISTE', motivo: 'familia debe rechazarse' }],
    externos: [{ nombre: 'Marca X Mayonesa 100g', marca: 'X', presentacion: 'doypack', motivo: 'prueba' }],
  })])).rows[0].r;
  await c.query(`set local session_replication_role = origin`);
  const h = (await c.query(`select sustitutos_internos si, sust_stale st from mos.productos where codigo_barra=$1`, [lider.codigo_barra])).rows[0];
  const pres = (await c.query(`select bool_and(sustitutos_internos is not null) ok from mos.productos where tipo_producto::text='PRESENTACION' and sku_base=$1`, [lider.sku_base])).rows[0];
  chk('guardar: 1 interno válido (familia rechazada) + externo + hereda a presentaciones',
    g.ok === true && g.internos === 1 && g.externos === 1 && h.st === false && pres.ok === true, JSON.stringify(g));
  // 3) validador: meto referencia muerta → la quita y marca stale
  await c.query(`update mos.productos set sustitutos_internos = '[{"sku":"X","cod":"NOEXISTE641","nombre":"x","sub":"Nada"}]'::jsonb where codigo_barra=$1`, [lider.codigo_barra]);
  const v = (await c.query(`select mos.sust_validar('{}'::jsonb) r`)).rows[0].r;
  await c.query(`set local session_replication_role = origin`);
  const h2 = (await c.query(`select jsonb_array_length(sustitutos_internos) n, sust_stale st from mos.productos where codigo_barra=$1`, [lider.codigo_barra])).rows[0];
  chk('validador quita referencia muerta y re-marca stale', v.ok === true && Number(h2.n) === 0 && h2.st === true, JSON.stringify(h2));
}
// 4) líder NUEVO → pares de su subcategoría quedan stale (caso Alpaso/Alacena)
{
  await c.query(`update mos.productos set sust_stale=false where categoria_ia->>'subcategoria'=$1`, [lider.sub]);
  await c.query(`insert into mos.productos (id_producto, sku_base, codigo_barra, descripcion, tipo_producto, estado, precio_venta, categoria_ia, descripcion_ia, fecha_creacion)
    values ('IDT641N','LEVT641N','TEST641NUEVO','PRODUCTO NUEVO PAR 641', 'CANONICO', true, 9,
            jsonb_build_object('categoria','ESPECIAS','subcategoria',$1::text), '🏷 x ✅ y', now())`, [lider.sub]);
  const n = (await c.query(`select count(*) n from mos.productos where sust_stale and categoria_ia->>'subcategoria'=$1 and codigo_barra<>'TEST641NUEVO'`, [lider.sub])).rows[0].n;
  chk('líder nuevo marca stale a sus pares de subcategoría', Number(n) > 0, 'pares=' + n);
}
// 5) ia_guardar (ficha) marca self+pares
{
  await c.query(`update mos.productos set sust_stale=false where categoria_ia->>'subcategoria'=$1`, [lider.sub]);
  const txt = '🏷 Marca: T641\n🧪 Hecho de: prueba\n📋 Composición: prueba\n📦 Presentación: prueba\n🎨 Características: prueba larga para pasar guardas de longitud\n✅ Usos y beneficios: prueba';
  const g = (await c.query(`select mos.ia_guardar_descripcion($1::jsonb) r`, [JSON.stringify({ codigoBarra: 'TEST641NUEVO', texto: txt, marca: '' })])).rows[0].r;
  await c.query(`set local session_replication_role = origin`);
  const n = (await c.query(`select count(*) n from mos.productos where sust_stale and categoria_ia->>'subcategoria'=$1`, [lider.sub])).rows[0].n;
  chk('ficha nueva/actualizada marca self+pares para re-evaluar', g.ok === true && Number(n) > 1, 'stale=' + n);
}
t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 130) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} — NO se aplica`); await c.end(); process.exit(1); }

// ══ FASE 2: aplicar ══
await c.query('begin');
await c.query(DDL); await c.query(FICHA); await c.query(IA_SUST);
{
  const def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='ia_guardar_descripcion'`)).rows[0].d;
  if (!/_ia_marcar_sust/.test(def)) {
    await c.query(def.replace(
      `  return jsonb_build_object('ok', true, 'actualizados', 1, 'refresh', v_refresh,`,
      `  perform mos._ia_marcar_sust(v_cod, v_cat->>'subcategoria');   -- [641] sustitutos a re-evaluar (self+pares)\n  return jsonb_build_object('ok', true, 'actualizados', 1, 'refresh', v_refresh,`));
  }
}
await c.query('commit');
const pend = (await c.query(`select count(*) n from mos.productos
  where tipo_producto::text in ('CANONICO','DERIVADO') and coalesce(estado,true)
    and coalesce(es_insumo,false)=false and descripcion_ia is not null and categoria_ia is not null
    and sustitutos_internos is null`)).rows[0].n;
console.log(`\n✅ ${t.length}/${t.length} — 641 aplicado · líderes pendientes de backfill: ${pend}`);
await c.end();
