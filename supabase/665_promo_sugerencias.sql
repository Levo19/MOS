-- 665 · mos.promo_sugerencias() — EL RADAR: cards de promoción pensadas con los datos reales.
--   Cada card trae: producto · POR QUÉ (dato duro) · jugada del playbook · explicación educativa
--   ("¿por qué esta jugada?") · precio normal → precio promo · margen resultante en % y en S/.
--
--   REGLAS DEL DUEÑO
--     🔥 REMATE        vence < 3 meses      → escalón inicial −20% / −30% según urgencia, tope en COSTO.
--                                             Bajo costo ⇒ perdida=true (badge rojo + doble confirmación).
--     ⏰ POR VENCER    vence 3..4.5 meses   → empuje suave desde 2 unidades, margen protegido (≥12%).
--     📦 SOBRE-STOCK   cobertura DÍAS = stock / venta diaria 30d; compra SEMANAL ⇒ > 15 días sobra.
--                                             2ª unidad al %. Exige movimiento real (≥4/mes).
--     🐌 BAJA ROTACIÓN ≤1 venta en 30d      → COMBO ancla con el líder de su subcategoría.
--                                             EXCLUYE graneles/base cuyos derivados SÍ rotan (materia prima).
--     📉 ESCALERA      promo activa ≥14d con 0 ventas → sube el escalón (20→30→40%).
--   JUGADAS PROACTIVAS (rellenan para que NUNCA haya menos de 2 ideas):
--     2️⃣ margen gordo + rotación media → 2ª unidad al %
--     🔁 cruce con sustitutos internos ya mapeados
--     ⏰ horas valle 14:00-17:00
--   🛡 NUNCA el top 20% por rotación · nunca lo que ya tiene promo activa · nunca lo descartado (30 días).
--   Rotación de ideas: semilla por día (o 'nonce') baraja el pool top-12 de cada regla.
--   La creación SIEMPRE la confirma el dueño: esta RPC solo propone.

create or replace function mos._promo_psico(x numeric)
returns numeric language sql immutable as $fn$
  select case
    when coalesce(x,0) <= 0.60 then 0.50
    else greatest(0.50, floor(x) + case
        when (x - floor(x)) >= 0.70 then 0.90
        when (x - floor(x)) >= 0.40 then 0.50
        else -0.10 end)
  end;
$fn$;

-- el .90/.50 mas cercano HACIA ARRIBA (piso de costo: nunca sugerir por debajo)
create or replace function mos._promo_psico_up(x numeric)
returns numeric language sql immutable as $fn$
  select case
    when coalesce(x,0) <= 0.50 then 0.50
    else floor(x) + case
        when (x - floor(x)) <= 0.50 then 0.50
        when (x - floor(x)) <= 0.90 then 0.90
        else 1.50 end
  end;
$fn$;

-- S/ 12.90 → texto de dinero corto y consistente
create or replace function mos._promo_sol(x numeric)
returns text language sql immutable as $fn$
  select 'S/ ' || to_char(coalesce(x,0), 'FM999990.00');
$fn$;

create or replace function mos.promo_sugerencias(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_n    int  := greatest(1, least(24, coalesce(nullif(btrim(coalesce(p->>'n','')),'')::int, 6)));
  v_seed text := coalesce(nullif(btrim(coalesce(p->>'seed','')),''),
                          to_char(now() at time zone 'America/Lima','YYYYMMDD'));
  v_data jsonb;
  v_play jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  create temporary table if not exists _pgs_bb (
    sku_base text, codigo_barra text, descripcion text, marca text,
    pv numeric, pc numeric, envasable boolean, base text,
    categoria text, subcat text, q30 numeric, q14 numeric, stock numeric,
    fvenc timestamptz, cob_dias numeric, meses_venc numeric, margen numeric,
    q_hijos numeric, n_hijos int, pr30 numeric, ya_promo boolean,
    sust_nom text, sust_sub text
  ) on commit drop;
  delete from _pgs_bb;

  insert into _pgs_bb
  with prod as (
    select pr.sku_base,
           coalesce(pr.codigo_barra,'')                           as codigo_barra,
           coalesce(pr.descripcion,'')                            as descripcion,
           coalesce(pr.marca,'')                                  as marca,
           coalesce(pr.precio_venta,0)::numeric                   as pv,
           coalesce(pr.precio_costo,0)::numeric                   as pc,
           coalesce(pr.es_envasable,false)                        as envasable,
           nullif(btrim(coalesce(pr.codigo_producto_base,'')),'') as base,
           coalesce(pr.categoria_ia->>'categoria','')             as categoria,
           coalesce(pr.categoria_ia->>'subcategoria','')          as subcat,
           case when jsonb_typeof(pr.sustitutos_internos)='array'
                 and jsonb_array_length(pr.sustitutos_internos) > 0
                then pr.sustitutos_internos->0->>'nombre' end     as sust_nom,
           case when jsonb_typeof(pr.sustitutos_internos)='array'
                 and jsonb_array_length(pr.sustitutos_internos) > 0
                then pr.sustitutos_internos->0->>'sub' end        as sust_sub
      from mos.productos pr
     where coalesce(pr.estado,false)
       and pr.tipo_producto::text in ('CANONICO','DERIVADO')
       and coalesce(pr.es_insumo,false) = false
       and coalesce(pr.precio_venta,0) > 0
  ),
  ven as (
    select vd.sku, sum(coalesce(vd.cantidad,0))::numeric as q
      from me.ventas_detalle vd join me.ventas v on v.id_venta = vd.id_venta
     where v.fecha >= now() - interval '30 days' and coalesce(v.estado_envio,'') = 'COMPLETADO'
     group by 1
  ),
  ven14 as (
    select vd.sku, sum(coalesce(vd.cantidad,0))::numeric as q
      from me.ventas_detalle vd join me.ventas v on v.id_venta = vd.id_venta
     where v.fecha >= now() - interval '14 days' and coalesce(v.estado_envio,'') = 'COMPLETADO'
     group by 1
  ),
  stk as (
    select s.cod_producto, sum(coalesce(s.cantidad_disponible,0))::numeric as st
      from wh.stock s group by 1
  ),
  venc as (
    select l.cod_producto, min(l.fecha_vencimiento) as fv
      from wh.lotes_vencimiento l
     where coalesce(l.estado,'ACTIVO') = 'ACTIVO'
       and coalesce(l.cantidad_actual,0) > 0
       and l.fecha_vencimiento is not null
     group by 1
  ),
  b as (
    select pr.*,
           coalesce(vn.q,0)  as q30,
           coalesce(v14.q,0) as q14,
           coalesce(sk.st,0) as stock,
           vc.fv             as fvenc,
           case when coalesce(vn.q,0) > 0 and coalesce(sk.st,0) > 0
                then coalesce(sk.st,0) / (coalesce(vn.q,0)/30.0) end   as cob_dias,
           case when vc.fv is not null
                then (extract(epoch from (vc.fv - now()))/2629746.0)::numeric end as meses_venc,
           case when pr.pv > 0 and pr.pc > 0
                then (pr.pv - pr.pc)/pr.pv*100.0 end                   as margen
      from prod pr
      left join ven   vn  on vn.sku  = pr.sku_base
      left join ven14 v14 on v14.sku = pr.sku_base
      left join stk   sk  on sk.cod_producto = pr.codigo_barra
      left join venc  vc  on vc.cod_producto = pr.codigo_barra
  ),
  der as (
    select b.base, sum(b.q30) as q_hijos, count(*)::int as n_hijos
      from b where b.base is not null group by 1
  ),
  rk as (
    select b.sku_base, percent_rank() over (order by b.q30) as pr30 from b where b.q30 > 0
  )
  select b.sku_base, b.codigo_barra, b.descripcion, b.marca, b.pv, b.pc, b.envasable,
         b.base, b.categoria, b.subcat, b.q30, b.q14, b.stock, b.fvenc, b.cob_dias,
         b.meses_venc, b.margen, coalesce(d.q_hijos,0), coalesce(d.n_hijos,0),
         coalesce(rk.pr30,0),
         exists(select 1 from mos.promociones pm
                 where pm.sku_base = b.sku_base and coalesce(pm.activa,true)),
         b.sust_nom, b.sust_sub
    from b left join der d on d.base = b.sku_base left join rk on rk.sku_base = b.sku_base;

  create temporary table if not exists _pgs_lider (
    subcat text, l_sku text, l_desc text, l_pv numeric, l_pc numeric, l_q30 numeric
  ) on commit drop;
  delete from _pgs_lider;
  insert into _pgs_lider
  select distinct on (subcat) subcat, sku_base, descripcion, pv, pc, q30
    from _pgs_bb where subcat <> '' and q30 > 0
   order by subcat, q30 desc, sku_base;

  with eleg as (
    select * from _pgs_bb b
     where not b.ya_promo
       and b.pr30 < 0.80                                   -- 🛡 jamás el top 20% por rotación
       and not exists (select 1 from mos.promo_descartes dd
                        where dd.sku_base = b.sku_base
                          and dd.descartado_en > now() - interval '30 days')
  ),

  -- ═══ 🔥 REMATE ═══
  c_remate as (
    select e.sku_base, 'REMATE'::text as regla, '🔥'::text as emoji, 'Remate'::text as etiqueta,
           'remate'::text as estrategia,
           (900.0 - coalesce(e.meses_venc,3)*100 + case when e.pc > 0 then 150 else 0 end)::numeric as score,
           'PORCENTAJE'::text as tipo, 1::numeric as cant_min, 'UNITARIO'::text as valor_modo,
           null::jsonb as items_j, null::numeric as pc_extra,
           null::text as hora_d, null::text as hora_h,
           mos._promo_psico(e.pv * (1 - (case when e.meses_venc < 1.5 then 30 else 20 end)/100.0)) as precio_unit,
           ('Vence en ' || to_char(coalesce(e.meses_venc,0),'FM990.0') || ' meses (' ||
            to_char(e.fvenc,'DD/MM/YYYY') || ') · ' || to_char(e.stock,'FM999999990.##') || ' en stock')::text as porque,
           ('Vence en ' || to_char(coalesce(e.meses_venc,0),'FM990.0') || ' meses, así que arranco el escalón en −' ||
            (case when e.meses_venc < 1.5 then '30' else '20' end) || '% (menos de mes y medio = urgencia alta). ' ||
            'Precio ' || mos._promo_sol(e.pv) || ' → ' ||
            mos._promo_sol(mos._promo_psico(e.pv * (1 - (case when e.meses_venc < 1.5 then 30 else 20 end)/100.0))) || '. ' ||
            case when e.pc > 0
                 then 'El tope es tu costo (' || mos._promo_sol(e.pc) || '): más abajo ya es vender a pérdida.'
                 else 'Este producto no tiene precio_costo cargado, así que el margen no es verificable: revísalo antes de confirmar.'
            end || ' Si en 2 semanas no mueve, sube al siguiente escalón.')::text as detalle
      from eleg e
     where e.meses_venc is not null and e.meses_venc > 0 and e.meses_venc < 3 and e.stock > 0
  ),
  -- ═══ ⏰ POR VENCER ═══
  c_venc as (
    select e.sku_base, 'POR_VENCER'::text, '⏰'::text, 'Por vencer'::text, 'escalera'::text,
           (700.0 - coalesce(e.meses_venc,4)*50 + case when e.pc > 0 then 150 else 0 end)::numeric,
           'PORCENTAJE'::text, 2::numeric, 'UNITARIO'::text, null::jsonb, null::numeric,
           null::text, null::text,
           mos._promo_psico(e.pv * (1 - least(25, greatest(10, floor(coalesce(e.margen,0)) - 12))/100.0)),
           ('Vence en ' || to_char(coalesce(e.meses_venc,0),'FM990.0') || ' meses (' ||
            to_char(e.fvenc,'DD/MM/YYYY') || ') · todavía hay tiempo de empujarlo sin rematar')::text,
           ('Le quedan ' || to_char(coalesce(e.meses_venc,0),'FM990.0') || ' meses de vida: todavía NO es remate. ' ||
            'Con un empuje suave desde 2 unidades alcanza — ' || mos._promo_sol(e.pv) || ' → ' ||
            mos._promo_sol(mos._promo_psico(e.pv * (1 - least(25, greatest(10, floor(coalesce(e.margen,0)) - 12))/100.0))) || '. ' ||
            case when e.margen is not null
                 then 'Tu margen hoy es ' || to_char(e.margen,'FM990') || '%, y el descuento se calculó para no bajar de 12%.'
                 else 'Sin precio_costo cargado el descuento se mantiene conservador (10%).' end ||
            ' La idea es no llegar nunca a la zona de remate.')::text
      from eleg e
     where e.meses_venc is not null and e.meses_venc >= 3 and e.meses_venc <= 4.5 and e.stock > 0
  ),
  -- ═══ 📦 SOBRE-STOCK ═══
  c_stock as (
    select e.sku_base, 'SOBRE_STOCK'::text, '📦'::text, 'Sobre-stock'::text, 'segunda'::text,
           (500.0 + least(coalesce(e.cob_dias,0), 180)/2.0 + case when e.pc > 0 then 150 else 0 end)::numeric,
           'GRUPO'::text, 2::numeric, 'TOTAL'::text, null::jsonb, null::numeric,
           null::text, null::text,
           mos._promo_psico(e.pv + e.pv * (1 - least(30, greatest(10, floor(coalesce(e.margen,0)) - 12))/100.0)),
           ('Cobertura ' || to_char(least(coalesce(e.cob_dias,0),9999),'FM999990') ||
            ' días de venta (compras semanales: sobre 15 ya sobra) · stock ' ||
            to_char(e.stock,'FM999999990.##') || ', vende ' || to_char(e.q30/30.0,'FM990.00') || '/día')::text,
           ('Elegí 2ª unidad al −' || to_char(least(30, greatest(10, floor(coalesce(e.margen,0)) - 12)),'FM990') ||
            '% porque: tienes ' || to_char(least(coalesce(e.cob_dias,0),9999),'FM999990') ||
            ' días de cobertura y compras semanal, o sea te sobra; ' ||
            case when e.margen is not null
                 then 'su margen del ' || to_char(e.margen,'FM990') || '% aguanta el descuento solo en la segunda unidad'
                 else 'el descuento se mantiene bajo porque no hay precio_costo cargado' end ||
            '; y bajar el precio de lista dañaría el margen de TODAS las unidades, no solo de la que sobra. ' ||
            'El par queda en ' || mos._promo_sol(mos._promo_psico(e.pv + e.pv * (1 - least(30, greatest(10, floor(coalesce(e.margen,0)) - 12))/100.0))) || '.')::text
      from eleg e
     where e.cob_dias is not null and e.cob_dias > 15 and e.q30 >= 4 and e.stock > 0
  ),
  -- ═══ 🐌 BAJA ROTACIÓN (ancla con el líder) ═══
  c_lento as (
    select x.sku_base, 'BAJA_ROTACION'::text, '🐌'::text, 'No rota'::text,
           (case when x.l_sku is not null then 'ancla' else 'psicologico' end)::text,
           (300.0 + least(x.stock, 200) + case when x.pc > 0 then 150 else 0 end)::numeric,
           (case when x.l_sku is not null then 'COMBO' else 'PORCENTAJE' end)::text,
           (case when x.l_sku is not null then 1 else 2 end)::numeric,
           (case when x.l_sku is not null then 'TOTAL' else 'UNITARIO' end)::text,
           case when x.l_sku is not null then jsonb_build_array(
                jsonb_build_object('skuBase', x.sku_base, 'cantidad', 1, 'descripcion', x.descripcion),
                jsonb_build_object('skuBase', x.l_sku,   'cantidad', 1, 'descripcion', x.l_desc))
                else null end,
           x.l_pc, null::text, null::text,
           case when x.l_sku is not null
                then mos._promo_psico(x.pv * (1 - x.pct/100.0) + x.l_pv)
                else mos._promo_psico(x.pv * (1 - x.pct/100.0)) end,
           (case when x.q30 <= 0 then 'Sin una sola venta en 30 días'
                 else 'Solo ' || to_char(x.q30,'FM999990.##') || ' vendido en 30 días' end ||
            ' · ' || to_char(x.stock,'FM999999990.##') || ' en stock parado' ||
            case when x.l_sku is not null then ' · lo anclamos al líder de "' || x.subcat || '"' else '' end)::text,
           (case when x.l_sku is not null
                 then 'Lo colgué de ' || x.l_desc || ' (el líder de "' || x.subcat || '", ' ||
                      to_char(x.l_q30,'FM999990') || ' vendidos/30d) porque solo no rota (' ||
                      to_char(x.q30,'FM999990.##') || ' en 30 días) — el estrella arrastra. ' ||
                      'El combo sale a ' || mos._promo_sol(mos._promo_psico(x.pv * (1 - x.pct/100.0) + x.l_pv)) ||
                      ' (el lento entra con −' || to_char(x.pct,'FM990') || '%, el líder a precio normal), ' ||
                      'así el descuento lo paga el que no rota y no el que ya se vende solo.'
                 else 'No tiene líder claro en su subcategoría, así que va descuento directo de −' ||
                      to_char(x.pct,'FM990') || '% desde 2 unidades, con precio psicológico terminado en .90/.50. ' ||
                      'Tiene ' || to_char(x.stock,'FM999999990.##') || ' en stock parado: cada semana ahí es capital dormido.' end)::text
      from (
        select e.*, li.l_sku, li.l_desc, li.l_pv, li.l_pc, li.l_q30,
               least(35, greatest(15, floor(coalesce(e.margen,0)) - 12))::numeric as pct
          from eleg e
          -- el ancla solo tiene sentido si son de escala de precio comparable
          left join _pgs_lider li on li.subcat = e.subcat and li.l_sku <> e.sku_base
                                 and e.pv <= li.l_pv * 3 and li.l_pv <= e.pv * 5
         where e.q30 <= 1 and e.stock > 0
           and not (e.n_hijos > 0 and e.q_hijos > 0)   -- materia prima: sus derivados sí rotan
      ) x
  ),
  -- ═══ 2️⃣ PROACTIVA: margen gordo + rotación media ═══
  c_prosegunda as (
    select e.sku_base, 'MARGEN_GORDO'::text, '2️⃣'::text, 'Margen gordo'::text, 'segunda'::text,
           (250.0 + coalesce(e.margen,0))::numeric,
           'GRUPO'::text, 2::numeric, 'TOTAL'::text, null::jsonb, null::numeric,
           null::text, null::text,
           mos._promo_psico(e.pv + e.pv * (1 - least(30, floor(e.margen) - 12)/100.0)),
           ('Margen ' || to_char(e.margen,'FM990') || '% con rotación media (' ||
            to_char(e.q30,'FM999990.##') || ' en 30 días) · hay espacio para subir el ticket')::text,
           ('Margen gordo (' || to_char(e.margen,'FM990') || '%) con rotación media (' ||
            to_char(e.q30,'FM999990.##') || ' en 30 días): la 2ª unidad al −' ||
            to_char(least(30, floor(e.margen) - 12),'FM990') ||
            '% sube el ticket promedio sin tocar el precio de lista. El par queda en ' ||
            mos._promo_sol(mos._promo_psico(e.pv + e.pv * (1 - least(30, floor(e.margen) - 12)/100.0))) ||
            ' y el margen combinado sigue sano. Es la jugada más segura: protege la 1ª unidad siempre.')::text
      from eleg e
     where e.margen is not null and e.margen >= 30 and e.q30 between 2 and 40 and e.stock > 0
  ),
  -- ═══ 🔁 PROACTIVA: cruce con sustitutos ═══
  c_prosust as (
    select e.sku_base, 'SUSTITUTO'::text, '🔁'::text, 'Sustituto'::text, 'sustitutos'::text,
           (230.0 + least(e.stock,100))::numeric,
           'PORCENTAJE'::text, 1::numeric, 'UNITARIO'::text, null::jsonb, null::numeric,
           null::text, null::text,
           mos._promo_psico(e.pv * 0.85),
           ('Tiene sustituto interno mapeado (' || e.sust_nom || ') y rota poco (' ||
            to_char(e.q30,'FM999990.##') || ' en 30 días)')::text,
           ('Ya está mapeado como sustituto de ' || e.sust_nom || ' en "' || coalesce(e.sust_sub, e.subcat) ||
            '". Un −15% chico (' || mos._promo_sol(e.pv) || ' → ' || mos._promo_sol(mos._promo_psico(e.pv * 0.85)) ||
            ') convierte el "no hay" en venta: cuando falte el otro, el cajero ofrece este con descuento y no pierdes el ticket. ' ||
            'Hoy rota ' || to_char(e.q30,'FM999990.##') || ' al mes, así que el descuento no canibaliza nada.')::text
      from eleg e
     where e.sust_nom is not null and e.q30 <= 4 and e.stock > 0
  ),
  -- ═══ ⏰ PROACTIVA: horas valle ═══
  c_provalle as (
    select e.sku_base, 'HORAS_VALLE'::text, '⏰'::text, 'Horas valle'::text, 'valle'::text,
           (210.0 + least(e.stock,100))::numeric,
           'PORCENTAJE'::text, 1::numeric, 'UNITARIO'::text, null::jsonb, null::numeric,
           '14:00'::text, '17:00'::text,
           mos._promo_psico(e.pv * (1 - least(20, greatest(10, floor(coalesce(e.margen,0)) - 12))/100.0)),
           ('Rotación media (' || to_char(e.q30,'FM999990.##') || ' en 30 días) y ' ||
            to_char(e.stock,'FM999999990.##') || ' en stock · candidato a mover en horario muerto')::text,
           ('Rota ' || to_char(e.q30,'FM999990.##') || ' al mes con ' || to_char(e.stock,'FM999999990.##') ||
            ' en stock: en vez de descontarlo todo el día, la promo vive solo de 14:00 a 17:00 (el hueco de la tarde). ' ||
            'Mueve inventario sin canibalizar la venta fuerte de la mañana ni la del cierre — el mismo cliente que ya venía a las 10am ' ||
            'sigue pagando precio completo. Precio en valle: ' ||
            mos._promo_sol(mos._promo_psico(e.pv * (1 - least(20, greatest(10, floor(coalesce(e.margen,0)) - 12))/100.0))) || '.')::text
      from eleg e
     where e.q30 between 3 and 30 and e.stock > 0
  ),
  -- ═══ 📉 ESCALERA ═══
  esc as (
    select pm.sku_base, 'ESCALERA'::text, '📉'::text, 'Escalón'::text, 'escalera'::text,
           1000.0::numeric,
           'PORCENTAJE'::text, coalesce(nullif(pm.cant_min,0),1), 'UNITARIO'::text, null::jsonb, null::numeric,
           case when pm.hora_desde is null then null else to_char(pm.hora_desde,'HH24:MI') end,
           case when pm.hora_hasta is null then null else to_char(pm.hora_hasta,'HH24:MI') end,
           mos._promo_psico(bx.pv * (1 - least(50, coalesce(pm.valor_promo,20) + 10)/100.0)),
           ('Promo activa hace ' ||
            to_char(greatest(0, extract(epoch from (now() - coalesce(
              case when pm.vigencia_desde ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then left(pm.vigencia_desde,10)::timestamptz end,
              pm.updated_at, now())))/86400.0), 'FM999990') ||
            ' días y 0 ventas en 14 días')::text,
           ('La promo lleva ' ||
            to_char(greatest(0, extract(epoch from (now() - coalesce(
              case when pm.vigencia_desde ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then left(pm.vigencia_desde,10)::timestamptz end,
              pm.updated_at, now())))/86400.0), 'FM999990') ||
            ' días viva y no movió ni una unidad en las últimas 2 semanas: el descuento actual (' ||
            to_char(coalesce(pm.valor_promo,20),'FM990') || '%) no alcanzó. Sube el escalón a ' ||
            to_char(least(50, coalesce(pm.valor_promo,20) + 10),'FM990') || '% (' || mos._promo_sol(bx.pv) || ' → ' ||
            mos._promo_sol(mos._promo_psico(bx.pv * (1 - least(50, coalesce(pm.valor_promo,20) + 10)/100.0))) ||
            '). El peor descuento es la merma al 100%.')::text
      from mos.promociones pm
      join _pgs_bb bx on bx.sku_base = pm.sku_base
     where coalesce(pm.activa,true) and upper(coalesce(pm.tipo_promo,'')) = 'PORCENTAJE'
       and coalesce(bx.q14,0) = 0
       and coalesce(
             case when pm.vigencia_desde ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then left(pm.vigencia_desde,10)::timestamptz end,
             pm.updated_at) <= now() - interval '14 days'
  ),
  todo as (
    select * from c_remate union all select * from c_venc union all select * from c_stock
    union all select * from c_lento union all select * from c_prosegunda
    union all select * from c_prosust union all select * from c_provalle
    union all select * from esc
  ),
  dedup as (   -- un producto = una sola idea (gana la de mayor score)
    select distinct on (t.sku_base) t.* from todo t order by t.sku_base, t.score desc
  ),
  fin0 as (
    select d.*, b.descripcion, b.marca, b.codigo_barra, b.pv, b.pc, b.stock, b.q30,
           b.cob_dias, b.meses_venc, b.fvenc, b.margen, b.categoria, b.subcat,
           -- unidades que entran en el precio propuesto (GRUPO: cant_min / COMBO: 2 / resto: 1)
           (case when d.tipo = 'GRUPO' then greatest(coalesce(d.cant_min,2),1)
                 when d.tipo = 'COMBO' then 2 else 1 end)::numeric as unidades,
           -- costo total del paquete propuesto (0 = no verificable)
           (case when d.tipo = 'COMBO'
                 then case when b.pc > 0 and coalesce(d.pc_extra,0) > 0 then b.pc + d.pc_extra else 0 end
                 when d.tipo = 'GRUPO' then b.pc * greatest(coalesce(d.cant_min,2),1)
                 else b.pc end)::numeric as costo_total
      from dedup d join _pgs_bb b on b.sku_base = d.sku_base
  ),
  fin as (
    select f.*,
           -- PISO: fuera del remate nunca por debajo de costo+12%; en remate el tope ES el costo
           (case
              when f.costo_total > 0 and f.regla = 'REMATE' and f.precio_unit < f.costo_total
                   then mos._promo_psico_up(f.costo_total)
              when f.costo_total > 0 and f.regla <> 'REMATE' and f.precio_unit < f.costo_total * 1.12
                   then mos._promo_psico_up(f.costo_total * 1.12)
              else f.precio_unit end)::numeric as precio_total,
           (f.costo_total > 0 and (
              (f.regla = 'REMATE'  and f.precio_unit < f.costo_total) or
              (f.regla <> 'REMATE' and f.precio_unit < f.costo_total * 1.12))) as tope_costo
      from fin0 f
  ),
  fin2 as (   -- si el piso de costo se comio el descuento, la idea NO sirve: fuera
    select * from fin where (precio_total / unidades) < pv * 0.97
  ),
  pool as (   -- top 12 de cada regla por calidad…
    select f.*, row_number() over (partition by f.regla order by f.score desc, f.sku_base) as rq from fin2 f
  ),
  barajado as (  -- …y dentro de ese pool, semilla del día para que las ideas roten
    select p2.*, row_number() over (partition by p2.regla
             order by md5(p2.sku_base || '|' || v_seed)) as rn
      from pool p2 where p2.rq <= 12
  ),
  elegidas as (
    select * from barajado
     order by (case when rn <= 2 then 0 else 1 end), score desc, rn, sku_base
     limit v_n
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id',            e.regla || '_' || e.sku_base,
      'regla',         e.regla,
      'emoji',         e.emoji,
      'etiqueta',      e.etiqueta,
      'estrategia',    e.estrategia,
      'skuBase',       e.sku_base,
      'codigoBarra',   e.codigo_barra,
      'descripcion',   e.descripcion,
      'marca',         e.marca,
      'categoria',     e.categoria,
      'subcategoria',  e.subcat,
      'porque',        e.porque,
      'porqueDetalle', e.detalle,
      'precioVenta',   round(e.pv, 2),
      'precioCosto',   round(e.pc, 2),
      'costoConocido', (e.pc > 0),
      'margenActual',  case when e.margen is null then null else round(e.margen, 1) end,
      'stock',         round(e.stock, 2),
      'ventas30',      round(e.q30, 2),
      'ventaDiaria',   round(e.q30/30.0, 2),
      'coberturaDias', case when e.cob_dias is null then null else round(e.cob_dias, 0) end,
      'mesesVenc',     case when e.meses_venc is null then null else round(e.meses_venc, 1) end,
      'fechaVenc',     case when e.fvenc is null then null else to_char(e.fvenc,'YYYY-MM-DD') end,
      'tipo',          e.tipo,
      'cantMin',       e.cant_min,
      'valorModo',     e.valor_modo,
      'items',         e.items_j,
      'horaDesde',     e.hora_d,
      'horaHasta',     e.hora_h,
      'precioNormal',        round(e.pv, 2),
      'precioPromo',         round(e.precio_total / e.unidades, 2),
      'precioSugerido',      round(e.precio_total, 2),
      'precioUnitEfectivo',  round(e.precio_total / e.unidades, 2),
      'costoTotal',    case when e.costo_total > 0 then round(e.costo_total, 2) end,
      'unidades',      e.unidades,
      'topeCosto',     e.tope_costo,
      'descuentoPct',  case when e.pv > 0 then round(greatest(0, (1 - (e.precio_total/e.unidades)/e.pv)*100), 1) else 0 end,
      'valorPromo',    case when e.tipo = 'PORCENTAJE'
                            then case when e.pv > 0 then round(greatest(1, (1 - (e.precio_total/e.unidades)/e.pv)*100), 1) else 0 end
                            else round(e.precio_total, 2) end,
      'margenResultante', case when e.precio_total > 0 and e.costo_total > 0
                               then round((e.precio_total - e.costo_total)/e.precio_total*100, 1) end,
      'margenSoles',   case when e.costo_total > 0 then round(e.precio_total - e.costo_total, 2) end,
      'perdida',       (e.costo_total > 0 and e.precio_total < e.costo_total),
      'descripcionSugerida', case
          when e.tipo = 'GRUPO'  then 'Lleva ' || to_char(e.unidades,'FM990') || ' y paga ' || mos._promo_sol(e.precio_total)
          when e.tipo = 'COMBO'  then 'Combo ' || e.descripcion || ' + ' ||
               coalesce((e.items_j->1->>'descripcion'),'líder') || ' a ' || mos._promo_sol(e.precio_total)
          when e.regla = 'REMATE' then 'REMATE ' ||
               to_char(greatest(0,(1 - (e.precio_total/e.unidades)/nullif(e.pv,0))*100),'FM990') || '% OFF'
          when e.regla = 'HORAS_VALLE' then 'Happy hour 14:00-17:00 · ' ||
               to_char(greatest(0,(1 - (e.precio_total/e.unidades)/nullif(e.pv,0))*100),'FM990') || '% OFF'
          else to_char(greatest(0,(1 - (e.precio_total/e.unidades)/nullif(e.pv,0))*100),'FM990') || '% de descuento' end
    ) order by e.score desc), '[]'::jsonb)
    into v_data
    from elegidas e;

  -- ═══ PLAYBOOK con ejemplos REALES del catálogo ═══
  select jsonb_build_object(
    'ancla', (select jsonb_build_object('lento', b.descripcion, 'lentoSku', b.sku_base,
                     'lider', li.l_desc, 'liderSku', li.l_sku, 'liderVentas', round(li.l_q30,0), 'sub', b.subcat)
                from _pgs_bb b join _pgs_lider li on li.subcat = b.subcat and li.l_sku <> b.sku_base
               where b.q30 <= 1 and b.stock > 0 and b.subcat <> '' and not (b.n_hijos > 0 and b.q_hijos > 0)
               order by b.stock desc limit 1),
    'sustitutos', (select jsonb_build_object('producto', b.descripcion, 'productoSku', b.sku_base,
                          'sustituto', b.sust_nom, 'sub', coalesce(b.sust_sub, b.subcat))
                     from _pgs_bb b where b.sust_nom is not null and b.q30 <= 4
                    order by b.stock desc limit 1),
    'segunda', (select jsonb_build_object('producto', b.descripcion, 'productoSku', b.sku_base,
                       'cobertura', round(b.cob_dias,0), 'margen', round(b.margen,0))
                  from _pgs_bb b where b.cob_dias > 15 and b.q30 >= 4 and not b.ya_promo and b.pr30 < 0.80
                    and b.margen is not null and b.margen >= 20
                 order by b.cob_dias desc limit 1),
    'pack', (select jsonb_build_object('producto', b.descripcion, 'productoSku', b.sku_base, 'stock', round(b.stock,0))
               from _pgs_bb b where b.stock > 0 and b.q30 <= 2 and not b.ya_promo and b.pr30 < 0.80
              order by b.stock desc limit 1),
    'topseller', (select jsonb_build_object('producto', b.descripcion, 'productoSku', b.sku_base, 'ventas30', round(b.q30,0))
                    from _pgs_bb b where b.q30 > 0 order by b.q30 desc limit 1),
    'estacionalidad', (select jsonb_build_object('producto', b.descripcion, 'productoSku', b.sku_base, 'cat', b.categoria)
                         from _pgs_bb b
                        where b.categoria ilike '%REPOSTER%' and b.stock > 0 and b.q30 <= 3
                        order by b.stock desc limit 1),
    'valle', (select jsonb_build_object('producto', b.descripcion, 'productoSku', b.sku_base, 'ventas30', round(b.q30,0))
                from _pgs_bb b where b.q30 between 3 and 30 and b.stock > 0 and b.pr30 < 0.80
               order by b.stock desc limit 1),
    'psicologico', (select jsonb_build_object('producto', b.descripcion, 'productoSku', b.sku_base,
                           'de', round(b.pv,2), 'a', mos._promo_psico(b.pv * 0.75))
                      from _pgs_bb b where b.pv >= 3 and b.q30 <= 1 and b.stock > 0
                     order by b.stock desc limit 1),
    'remate', (select jsonb_build_object('producto', b.descripcion, 'productoSku', b.sku_base, 'meses', round(b.meses_venc,1))
                 from _pgs_bb b where b.meses_venc is not null and b.meses_venc > 0 and b.meses_venc < 6 and b.stock > 0
                order by b.meses_venc limit 1),
    'escalera', (select jsonb_build_object('producto', b.descripcion, 'productoSku', b.sku_base,
                        'stock', round(b.stock,0), 'ventas30', round(b.q30,0))
                   from _pgs_bb b where b.q30 <= 1 and b.stock > 5 and not b.ya_promo and b.pr30 < 0.80
                  order by b.stock desc limit 1)
  ) into v_play;

  return jsonb_build_object('ok', true, 'data', coalesce(v_data,'[]'::jsonb), 'playbook', v_play,
                            'seed', v_seed, 'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI'));
end;
$fn$;

revoke all on function mos.promo_sugerencias(jsonb) from public, anon;
grant execute on function mos.promo_sugerencias(jsonb) to authenticated;
revoke all on function mos._promo_psico(numeric) from public, anon;
grant execute on function mos._promo_psico(numeric) to authenticated;
revoke all on function mos._promo_sol(numeric) from public, anon;
grant execute on function mos._promo_sol(numeric) to authenticated;
revoke all on function mos._promo_psico_up(numeric) from public, anon;
grant execute on function mos._promo_psico_up(numeric) to authenticated;
