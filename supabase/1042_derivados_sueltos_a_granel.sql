-- 1042 · Barrido: derivados "<X> NNGR" sueltos (familia WA/WZ… LEV1601–1642 + arroz glutinoso) → vinculados a su "<X> GRANEL"
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- PREPARADO 2026-10-09 (NO APLICADO). Continúa a 1041 (anís estrella) con el mismo modelo y guardas.
-- Dueño 09-oct: arreglar TODOS los casos parecidos · presentaciones "· N g" del granel se MANTIENEN ·
-- envase_sku queda NULL (lo elige en MOS).
-- Dueño 09-oct (2ª ronda): NO aplicar todavía · no incluir pimienta molida 10g / chapa 10g / clavo indonesio / coco 40g ·
--   CANELA MOLIDA 5GR (LEV1623, cb WACAXIDA010GR) pesa 5 g de verdad: si se agrega, va con 0.005 kg y excepción a la guarda cb.
--
-- CAUSA RAÍZ (igual que 1041)
--   La migración MIGRACION_ME trajo los sobres pequeños WA…/WZ…NNNGR como CANONICO con
--   codigo_producto_base NULL y factor_conversion_base NULL. El Envasador de WH (EnvasadorView._buildCatalog)
--   cuelga los hijos por codigoProductoBase → estos sobres no aparecen para envasar y en MOS salen "aparte".
--
-- QUÉ HACE (data-driven, sin UPDATE por patrón: cada fila está listada con id + sku + cb + base + kg)
--   1. Derivados (27 filas, 21 graneles): codigo_producto_base = sku del granel,
--      factor_conversion_base = gramos del nombre / 1000, factor_conversion = 1, tipo_producto = DERIVADO,
--      envase_sku NO se toca (sigue NULL), historial_cambios con source SQL_1042 (cap 50).
--   2. Graneles: es_envasable = true. Los 21 graneles del barrido YA lo son (verificado 09-oct); el único que
--      cambia es UMSHA AZUCAR IMPALPABLE GRANEL (LEV724), que ya tenía 3 derivados y no era envasable.
--
-- GUARDAS (si el estado vivo cambió desde el diagnóstico, aborta TODO)
--   · FOR UPDATE sobre todas las filas implicadas.
--   · Granel: CANONICO, KGM, factor 1, activo, sin codigo_producto_base, sku_base/cb exactos.
--   · Derivado: único dueño de su sku_base (count=1), CANONICO, NIU, suelto (base NULL, fcb NULL),
--     gramaje del NOMBRE vivo = kg de la tabla; si el cb trae gramaje (…NNNGR) también debe coincidir;
--     ningún otro derivado del mismo granel con el mismo factor (no se crean dos "10 g" del mismo granel).
--   · row_count = 1 por UPDATE.
--
-- EFECTO EN DINERO / STOCK (mismo análisis que 1041, re-verificado 09-oct)
--   · Stock: no se mueve. wh.stock / me.stock_zonas van por codigo_barra (intacto).
--   · Ventas: me.ventas_detalle no se toca; mos._venta_canonico resuelve por sku_base + factor_conversion
--     (intactos) → cada sobre sigue descontando SU stock, no el del granel.
--   · Precio: mos._propagar_precio es NO-OP [772]. No se tocan precios.
--   · Triggers: no se tocan descripcion/codigo_barra/sku_base/categoria_ia/marca/unidad_medida →
--     no disparan tg_herencia_*, tg_producto_cb_unico ni tg_granel_unidad_con_derivados.
--     tg_touch_updated_at (delta catálogo) y tg_bump_catversion (caché POS, al COMMIT) sí: deseado.
--   · Demanda: mos.almacen_demanda_envasable / mos.granel_demanda_derivados empiezan a sumar la deuda de
--     estos sobres a su granel (efecto deseado; canela entera pasa de 0 a 6 hijos).
--
-- FUERA DE ESTE SQL (dudosos, decide el dueño): LEV1623 CANELA MOLIDA 5GR (cb WACAXIDA010GR) ·
--   MANI CAJU ENTERA 500/250/100GR (01888/01889/01890: cb sin gramaje, 2 inactivos y duplican
--   WHMAJTRA500/250/100GR ya existentes) · CLAVO DE OLOR INDONESIO 13GR/25GR (granel se llama
--   "…INDONESIO PREMIUM GRANEL") · COCO RALLADO FINO 40GR (3 graneles de coco) · PIMIENTA CHAPA 10GR
--   (granel "PIMIENTA CHAPA ENTERA GRANEL") · PIMIENTA NEGRA MOLIDO 10GR (granel "…MOLIDA GRANEL").
-- ────────────────────────────────────────────────────────────────────────────────────────────────

begin;

do $$
declare
  -- ══ DECISIONES ════════════════════════════════════════════════════════════════════════════════
  -- ARROZ GLUTINOSO ENTERO 250GR (LEV0002356) tiene cb autogenerado NLEV… sin gramaje → la verificación
  -- nombre↔cb no es posible (no hay incoherencia; solo no se puede cruzar). Granel único, nombre exacto.
  c_incluir_arroz boolean := true;
  -- ═════════════════════════════════════════════════════════════════════════════════════════════

  c_usr  constant text := 'MASTER';
  c_src  constant text := 'SQL_1042';
  c_mot  constant text := 'Vincular derivado a su granel (venía suelto de la migración; no aparecía para envasar en WH)';
  v_ts   text := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  r      record;
  v_n    int;
  v_g    numeric;
  v_hist jsonb;
begin
  -- ── Tablas de trabajo (explícitas) ───────────────────────────────────────────────────────────
  create temp table _g1042 (id text primary key, sku text not null, cb text not null) on commit drop;
  insert into _g1042 values
    ('IDPRO0000026','LEV453','WHAJCOVO'),          -- AJI PANCA POLVO GRANEL
    ('IDPRO0000057','LEV319','WHAJNLVO'),          -- AJO EN POLVO GRANEL
    ('IDPRO0000063','LEV149','WHAJARUM'),          -- AJONJOLI BLANCO PREMIUM GRANEL EXO
    ('IDPRO0000145','LEV1568','WHARINRO'),         -- ARROZ GLUTINOSO ENTERO GRANEL
    ('IDPRO0000239','LEV525','WHBITSIO'),          -- BICARBONATO DE SODIO GRANEL
    ('IDPRO0000306','LEV928','WHCAXERA'),          -- CANELA ENTERA GRANEL
    ('IDPRO0000313','LEV179','WHCAXIDA'),          -- CANELA MOLIDA GRANEL
    ('IDPRO0000344','LEV540','WHCEALVO'),          -- CEBOLLA POLVO GRANEL
    ('IDPRO0000422','LEV649','WHCLOPVO'),          -- CLAVO DE OLOR POLVO GRANEL
    ('IDPRO0000461','LEV170','WHCOXERO'),          -- COMINO ENTERO GRANEL
    ('IDPRO0000837','LEV320','WHKIXVVO'),          -- KION POLVO GRANEL
    ('IDPRO0000944','LEV270','WHLIXIUM'),          -- LINAZA PREMIUM GRANEL
    ('IDPRO0001174','LEV185','WHORLIRO'),          -- OREGANO MOLIDO PIZERO GRANEL
    ('IDPRO0001195','LEV143','WHPAPOVO'),          -- PALILLO PURO POLVO GRANEL EXO
    ('IDPRO0001221','LEV490','WHPAALVO'),          -- PAPRICA POLVO GRANEL
    ('IDPRO0001274','LEV324','WHPIAREL'),          -- PIMIENTA CAYENA GRANEL
    ('IDPRO0001283','LEV005','WHPIENRA'),          -- PIMIENTA NEGRA ENTERA GRANEL
    ('IDPRO0001372','LEV406','WHROXERO'),          -- ROMERO ENTERO GRANEL
    ('IDPRO0001377','LEV284','WHROXIDO'),          -- ROMERO MOLIDO GRANEL
    ('IDPRO0001583','LEV623','WHTOOERO'),          -- TOMILLO ENTERO GRANEL
    ('IDPRO0001588','LEV584','WHTOOIDO'),          -- TOMILLO MOLIDO GRANEL
    ('IDPRO0001609','LEV724','7750243069458');     -- UMSHA AZUCAR IMPALPABLE GRANEL (solo es_envasable)

  create temp table _d1042 (id text primary key, sku text not null, cb text not null, base text not null,
                            kg numeric(10,4) not null) on commit drop;
  insert into _d1042 values
    -- id_producto,  sku_base,     codigo_barra,         base,      kg/u
    ('IDPRO0000023','LEV1613',    'WAAJCOVO015GR',      'LEV453',  0.0150),  -- AJI PANCA POLVO 15GR
    ('IDPRO0000053','LEV1611',    'WAAJNLVO010GR',      'LEV319',  0.0100),  -- AJO EN POLVO 10GR
    ('IDPRO0000062','LEV1641',    'WZAJARUM050GR',      'LEV149',  0.0500),  -- AJONJOLI BLANCO PREMIUM 50GR
    ('IDPRO0002356','LEV0002356', 'NLEV1780409905597',  'LEV1568', 0.2500),  -- ARROZ GLUTINOSO ENTERO 250GR (cb sin gramaje)
    ('IDPRO0000237','LEV1634',    'WABITSIO030GR',      'LEV525',  0.0300),  -- BICARBONATO DE SODIO 30GR
    ('IDPRO0000298','LEV1630',    'WACAXERA010GR',      'LEV928',  0.0100),  -- CANELA ENTERA 10GR
    ('IDPRO0000301','LEV1629',    'WACAXERA020GR',      'LEV928',  0.0200),  -- CANELA ENTERA 20GR
    ('IDPRO0000305','LEV1628',    'WACAXERA050GR',      'LEV928',  0.0500),  -- CANELA ENTERA 50GR
    ('IDPRO0000297','LEV1627',    'WACAXERA100GR',      'LEV928',  0.1000),  -- CANELA ENTERA 100GR
    ('IDPRO0000303','LEV1626',    'WACAXERA250GR',      'LEV928',  0.2500),  -- CANELA ENTERA 250GR
    ('IDPRO0000304','LEV1625',    'WACAXERA500GR',      'LEV928',  0.5000),  -- CANELA ENTERA 500GR
    ('IDPRO0000309','LEV1624',    'WACAXIDA020GR',      'LEV179',  0.0200),  -- CANELA MOLIDA 20GR
    ('IDPRO0000341','LEV1612',    'WACEALVO015GR',      'LEV540',  0.0150),  -- CEBOLLA POLVO 15GR
    ('IDPRO0000418','LEV1605',    'WACLOPVO010GR',      'LEV649',  0.0100),  -- CLAVO DE OLOR POLVO 10GR
    ('IDPRO0000419','LEV1604',    'WACLOPVO020GR',      'LEV649',  0.0200),  -- CLAVO DE OLOR POLVO 20GR
    ('IDPRO0000458','LEV1631',    'WACOXERO020GR',      'LEV170',  0.0200),  -- COMINO ENTERO 20GR
    ('IDPRO0000834','LEV1610',    'WAKIXVVO015GR',      'LEV320',  0.0150),  -- KION POLVO 15GR
    ('IDPRO0000943','LEV1642',    'WZLIXIUM050GR',      'LEV270',  0.0500),  -- LINAZA PREMIUM 50GR
    ('IDPRO0001170','LEV1601',    'WAORLIRO015GR',      'LEV185',  0.0150),  -- OREGANO MOLIDO PIZERO 15GR
    ('IDPRO0001193','LEV1633',    'WAPAPOVO020GR',      'LEV143',  0.0200),  -- PALILLO PURO POLVO 20GR
    ('IDPRO0001218','LEV1609',    'WAPAALVO015GR',      'LEV490',  0.0150),  -- PAPRICA POLVO 15GR
    ('IDPRO0001272','LEV1622',    'WAPIAYNA010GR',      'LEV324',  0.0100),  -- PIMIENTA CAYENA 10GR (raíz cb ≠ WHPIAREL; nombre exacto)
    ('IDPRO0001280','LEV1632',    'WAPIENRA010GR',      'LEV005',  0.0100),  -- PIMIENTA NEGRA ENTERA 10GR
    ('IDPRO0001369','LEV1620',    'WAROXERO015GR',      'LEV406',  0.0150),  -- ROMERO ENTERO 15GR
    ('IDPRO0001373','LEV1621',    'WAROXIDO010GR',      'LEV284',  0.0100),  -- ROMERO MOLIDO 10GR
    ('IDPRO0001579','LEV1618',    'WATOOERO015GR',      'LEV623',  0.0150),  -- TOMILLO ENTERO 15GR
    ('IDPRO0001584','LEV1619',    'WATOOIDO015GR',      'LEV584',  0.0150);  -- TOMILLO MOLIDO 15GR

  if not c_incluir_arroz then
    delete from _d1042 where sku = 'LEV0002356';
    delete from _g1042 where sku = 'LEV1568';
  end if;

  -- ── 0. Bloqueo ───────────────────────────────────────────────────────────────────────────────
  perform 1 from mos.productos
   where id_producto in (select id from _g1042 union all select id from _d1042)
   order by id_producto for update;

  -- ── 0b. Guardas de los graneles ──────────────────────────────────────────────────────────────
  for r in select * from _g1042 loop
    perform 1 from mos.productos g
     where g.id_producto = r.id and g.sku_base = r.sku and g.codigo_barra = r.cb
       and g.tipo_producto::text = 'CANONICO' and upper(coalesce(g.unidad_medida,'')) = 'KGM'
       and coalesce(nullif(g.factor_conversion,0),1) = 1 and coalesce(g.estado,true)
       and coalesce(nullif(btrim(g.codigo_producto_base),''),'') = '';
    if not found then raise exception '[1042] granel % (%) no está en el estado esperado', r.sku, r.cb; end if;
    select count(*) into v_n from mos.productos where sku_base = r.sku and tipo_producto::text = 'CANONICO';
    if v_n <> 1 then raise exception '[1042] granel %: % canónicos con ese sku_base (esperado 1)', r.sku, v_n; end if;
  end loop;

  -- ── 1. Derivados: canónico suelto → DERIVADO del granel ────────────────────────────────────────
  for r in select d.* from _d1042 d order by d.base, d.kg loop
    if not exists (select 1 from _g1042 g where g.sku = r.base) then
      raise exception '[1042] % apunta a base % fuera de la tabla de graneles', r.sku, r.base; end if;

    -- único dueño de su sku_base (sin presentaciones colgando)
    select count(*) into v_n from mos.productos where sku_base = r.sku;
    if v_n <> 1 then raise exception '[1042] % tiene % filas con su sku_base (esperado 1)', r.sku, v_n; end if;

    -- gramaje del NOMBRE vivo = kg de la tabla; y el del cb (si lo trae) también
    select substring(upper(btrim(descripcion)) from '([0-9]+)\s*GR$')::numeric / 1000 into v_g
      from mos.productos where id_producto = r.id;
    if v_g is distinct from r.kg then
      raise exception '[1042] % : gramaje del nombre (% kg) ≠ tabla (% kg)', r.sku, v_g, r.kg; end if;
    if r.cb ~ '[0-9]{3}GR$' and (substring(r.cb from '([0-9]{3})GR$')::numeric / 1000) <> r.kg then
      raise exception '[1042] % : gramaje del cb % ≠ % kg', r.sku, r.cb, r.kg; end if;

    -- no duplicar un tamaño que el granel ya tiene como derivado
    perform 1 from mos.productos z
     where z.codigo_producto_base = r.base and z.factor_conversion_base = r.kg and z.id_producto <> r.id;
    if found then raise exception '[1042] el granel % ya tiene un derivado de % kg (no se vincula %)', r.base, r.kg, r.sku; end if;

    v_hist := jsonb_build_object(
      'ts', v_ts, 'accion', 'editar', 'source', c_src, 'usuario', c_usr, 'motivo', c_mot,
      'cambios', jsonb_build_array(
        jsonb_build_object('campo','codigoProductoBase',   'antes', null,       'despues', r.base),
        jsonb_build_object('campo','factorConversionBase', 'antes', null,       'despues', r.kg),
        jsonb_build_object('campo','tipoProducto',         'antes', 'CANONICO', 'despues', 'DERIVADO')));

    update mos.productos t set
      codigo_producto_base   = r.base,
      factor_conversion_base = r.kg,
      factor_conversion      = 1,
      tipo_producto          = 'DERIVADO'::mos.producto_tipo,   -- misma regla que mos.actualizar_producto
      historial_cambios      = case
        when jsonb_typeof(t.historial_cambios) = 'array' and jsonb_array_length(t.historial_cambios) >= 50 then
          (select jsonb_agg(e order by ord)
             from jsonb_array_elements(t.historial_cambios || v_hist) with ordinality x(e, ord) where ord > 1)
        when jsonb_typeof(t.historial_cambios) = 'array' then t.historial_cambios || v_hist
        else jsonb_build_array(v_hist) end
    where t.id_producto = r.id and t.sku_base = r.sku and t.codigo_barra = r.cb
      and t.tipo_producto::text = 'CANONICO'
      and coalesce(nullif(btrim(t.codigo_producto_base),''),'') = ''
      and t.factor_conversion_base is null
      and coalesce(nullif(t.factor_conversion,0),1) = 1
      and upper(coalesce(t.unidad_medida,'')) = 'NIU';
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception '[1042] % (%) no está en el estado esperado; nada aplicado', r.sku, r.cb; end if;
  end loop;

  -- ── 2. Graneles → envasables (solo los que no lo son; hoy únicamente LEV724) ────────────────────
  v_hist := jsonb_build_object('ts', v_ts, 'accion', 'editar', 'source', c_src, 'usuario', c_usr, 'motivo',
              'Granel con derivados pasa a envasable (aparece en el Envasador de WH)',
              'cambios', jsonb_build_array(jsonb_build_object('campo','esEnvasable','antes', 0, 'despues', 1)));
  update mos.productos t set
    es_envasable      = true,
    historial_cambios = case
      when jsonb_typeof(t.historial_cambios) = 'array' and jsonb_array_length(t.historial_cambios) >= 50 then
        (select jsonb_agg(e order by ord)
           from jsonb_array_elements(t.historial_cambios || v_hist) with ordinality x(e, ord) where ord > 1)
      when jsonb_typeof(t.historial_cambios) = 'array' then t.historial_cambios || v_hist
      else jsonb_build_array(v_hist) end
  where t.id_producto in (select id from _g1042) and coalesce(t.es_envasable,false) = false;
  get diagnostics v_n = row_count;
  raise notice '[1042] graneles pasados a envasable: %', v_n;

  -- post-condición: todos los graneles envasables y con >=1 hijo (si no, WH los descarta)
  perform 1 from _g1042 g join mos.productos p on p.id_producto = g.id
   where not coalesce(p.es_envasable,false)
      or not exists (select 1 from mos.productos d where d.codigo_producto_base in (p.sku_base, p.id_producto)
                                                     and coalesce(d.estado,true));
  if found then raise exception '[1042] post-condición: hay granel no envasable o sin hijos activos'; end if;
end $$;

-- ── 3. Verificación (lo que verá el Envasador de WH: base envasable + hijos + posibles con stock WH) ──
select b.sku_base, b.codigo_barra as base_cod, b.descripcion as base, coalesce(s.cantidad_disponible,0) as stock_base_kg,
       d.codigo_barra as deriv_cod, d.descripcion as derivado, d.tipo_producto, d.factor_conversion_base as kg_por_u,
       d.envase_sku,
       floor(coalesce(s.cantidad_disponible,0) / nullif(d.factor_conversion_base,0)) as posibles,
       d.historial_cambios @> '[{"source":"SQL_1042"}]' as nuevo_1042
  from mos.productos b
  join mos.productos d on d.codigo_producto_base in (b.sku_base, b.id_producto) and coalesce(d.estado,true)
  left join wh.stock s on s.cod_producto = b.codigo_barra
 where b.es_envasable and coalesce(b.estado,true)
   and b.sku_base in ('LEV453','LEV319','LEV149','LEV1568','LEV525','LEV928','LEV179','LEV540','LEV649','LEV170',
                      'LEV320','LEV270','LEV185','LEV143','LEV490','LEV324','LEV005','LEV406','LEV284','LEV623',
                      'LEV584','LEV724')
 order by b.sku_base, d.factor_conversion_base desc;

commit;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- ROLLBACK (exacto al estado del 2026-10-09; quita solo las entradas SQL_1042 del historial)
-- Los derivados vinculados tenían historial NULL (salvo LEV0002356, array de 1) → si queda vacío vuelve a NULL.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- begin;
-- update mos.productos set
--        codigo_producto_base = null, factor_conversion_base = null, factor_conversion = 1,
--        tipo_producto = 'CANONICO'::mos.producto_tipo,
--        historial_cambios = (select jsonb_agg(e) from jsonb_array_elements(historial_cambios) e
--                              where e->>'source' is distinct from 'SQL_1042')
--  where tipo_producto::text = 'DERIVADO'
--    and historial_cambios @> '[{"source":"SQL_1042","cambios":[{"campo":"tipoProducto"}]}]';
-- update mos.productos set es_envasable = false,
--        historial_cambios = (select jsonb_agg(e) from jsonb_array_elements(historial_cambios) e
--                              where e->>'source' is distinct from 'SQL_1042')
--  where historial_cambios @> '[{"source":"SQL_1042","cambios":[{"campo":"esEnvasable"}]}]';   -- solo LEV724
-- commit;
-- Nota rollback: si entre medio se ENVASÓ algún sobre en WH, esos envasados (wh.envasados + guías + kardex)
-- quedan válidos; el rollback solo deshace el vínculo de catálogo, no revierte stock.
