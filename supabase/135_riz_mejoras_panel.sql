-- 135_riz_mejoras_panel.sql — [RIZ · CAPA 2 · MEJORAS DEL PANEL PEDIDAS POR EL DUEÑO] — backward-compatible
-- Módulo de Reposición Inteligente por Zona (RIZ). Diseño: DISENO_modulo_reposicion_zona.md.
--
-- ⚠️ INERTE (igual que 128/129/132): estas RPCs existen y tienen grant, pero el módulo RIZ del frontend está
--    gated OFF (flag mos_zona_modulo). Este archivo NO toca flags/sync/frontend/GAS/version/sw. Solo CREATE OR
--    REPLACE de me.zona_panel + me.zona_ajustar_stock (re-define las de 128/129) y reafirma el wrapper mos.* (la
--    firma jsonb NO cambia → no hace falta tocarlo, pero lo dejamos idempotente por claridad). Patrón intacto:
--    security definer · set search_path='' · gate mos._claim_ok() · grants revoke public + service_role,authenticated ·
--    lecturas concatenan || mos._frescura_sombra().
--
-- ── LOS 3 CAMBIOS (todos ADITIVOS: agregan campos al item, NO rompen los existentes) ─────────────────────────
--   CAMBIO 1 — BRECHA con stock NEGATIVO (regla del dueño): un stock negativo es dato MALO (alerta a corregir),
--     no significa "falta tanto". brecha = greatest(0, esperada − greatest(stockZona,0)). Con stock negativo el
--     negativo se trata como 0 → brecha = esperada (lo que hay que comprar). stockZona se sigue mostrando TAL CUAL
--     (negativo incluido — el dueño quiere verlo). Nuevo flag por item: stockNegativo (bool).
--   CAMBIO 2 — TIPO de unidad: nuevo campo `unidad` (de mos.productos.unidad del canónico; '' si no hay) + flag
--     derivado `esGranel` (true si la unidad es de peso/volumen — SUNAT KGM/GRM/… o texto KG/GR/LT/ML/… — o si el
--     factor del canónico es fraccionario <1). El front lo usa para mostrar "kg" con decimales vs "un" entero.
--   CAMBIO 3 — DESGLOSE por CÓDIGO DE BARRA: nuevo array `codigos:[{codBarra, descripcion, stock, esEquivalente}]`
--     = TODOS los códigos del skuBase (canónico/presentaciones de mos.productos + equivalentes de mos.equivalencias)
--     con su stock individual en me.stock_zonas (0 si no hay fila). stockZona (global) = suma de esos stocks
--     (igual que hoy). esperada sigue siendo GLOBAL del skuBase (NO por código). El front expande/edita por código.
--
--   Además me.zona_ajustar_stock: ya aceptaba codBarras (alias del array: codBarra). Se ENDURECE para que el front
--   pueda mandar SOLO {zona, codBarra, nuevo, usuario} (sin skuBase) — ajusta esa fila de me.stock_zonas por
--   (cod_barras, zona). skuBase pasa a OPCIONAL (se deriva del código para el log si no viene). Acepta codBarra
--   y codBarras (alias). Mantiene idempotencia por localId, upsert atómico y log en me.zona_ajuste_log.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- HELPER interno: me._riz_es_granel(p_unidad text, p_factor numeric) → boolean.
--   true si la unidad es de peso/volumen (SUNAT KGM/GRM/MGM/LTR/MLT/MTR/… o texto KG/GR/G/LT/L/ML/MT/CM/…) o si el
--   factor del canónico es fraccionario (>0 y <1, ej. 0.25 kg por presentación). Centraliza la detección (una sola
--   definición de "granel"). stable, sin acceso a datos → no necesita gate propio (lo consumen RPCs definer).
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me._riz_es_granel(p_unidad text, p_factor numeric)
returns boolean
language sql
immutable
security definer
set search_path = ''
as $fn$
  select case
    when nullif(btrim(coalesce(p_unidad,'')),'') is not null and upper(btrim(p_unidad)) in (
      'KGM','GRM','MGM','TNE',        -- SUNAT masa: kilogramo, gramo, miligramo, tonelada
      'LTR','MLT','GLI','BG',         -- SUNAT volumen: litro, mililitro, galón, bolsa-granel
      'KG','G','GR','GRS','LT','L','ML','LTS','MG'  -- texto libre común
    ) then true
    -- factor fraccionario del canónico ⇒ se vende por fracción de unidad base ⇒ granel/peso
    when coalesce(p_factor,1) > 0 and coalesce(p_factor,1) < 1 then true
    else false
  end;
$fn$;
revoke all on function me._riz_es_granel(text, numeric) from public;
grant execute on function me._riz_es_granel(text, numeric) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- me.zona_panel(p jsonb { zona (req), filtro? })  — los cards del módulo. (RE-DEFINE 128 con los 3 cambios.)
--    Shape data.items[] (AMPLIADO, backward-compatible):
--      { skuBase, descripcion, stockZona, esperada, brecha, stockAlmacen, tendencia, bcg, picos[],
--        vencimientoProximo:{fecha,dias}|null, countLotes,            ← TODOS los de antes, intactos
--        stockNegativo:bool,                                          ← CAMBIO 1 (brecha ya corregida arriba)
--        unidad:text, esGranel:bool,                                  ← CAMBIO 2
--        codigos:[{codBarra, descripcion, stock, esEquivalente}] }    ← CAMBIO 3 (desglose multi-barcode)
--    brecha = greatest(0, esperada − greatest(stockZona,0)).  stockZona = suma de codigos[].stock (sin cambios).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_panel(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_filtro text := upper(btrim(coalesce(p->>'filtro','')));
  v_hoy    date := (now() at time zone 'America/Lima')::date;
  v_data   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  with
  -- resolver de zona inverso (idéntico a 128): aliases que mapean a la zona canónica.
  zona_aliases as (
    select v_zona as alias
    union select upper(btrim(es.id_zona)) from mos.estaciones es where upper(btrim(es.id_zona)) = v_zona
  ),
  -- mapa cod_barra → (skuBase, descripción del código, esEquivalente). Presentaciones propias de mos.productos
  -- (ord 0, esEquiv=false) + equivalentes de mos.equivalencias (ord 1, esEquiv=true). Para un código repetido
  -- gana el principal (ord 0). Esta es la BASE del desglose por código (CAMBIO 3) y del stock por skuBase.
  cb_sku as (
    select distinct on (cb) cb, sku, cb_desc, es_equiv from (
      select upper(btrim(p2.codigo_barra)) cb,
             coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku,
             nullif(btrim(p2.descripcion),'') cb_desc,
             false es_equiv, 0 ord
        from mos.productos p2 where nullif(btrim(p2.codigo_barra),'') is not null
      union all
      select upper(btrim(e.codigo_barra)),
             e.sku_base,
             nullif(btrim(e.descripcion),''),
             true, 1
        from mos.equivalencias e
        where coalesce(e.activo,true) and nullif(btrim(e.codigo_barra),'') is not null and nullif(btrim(e.sku_base),'') is not null
    ) t order by cb, ord
  ),
  -- descripción canónica por skuBase + unidad/factor del canónico (CAMBIO 2). El canónico = factor 1 / sin base.
  sku_meta as (
    select distinct on (sku) sku, descripcion, unidad, factor from (
      select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku,
             p2.descripcion,
             coalesce(nullif(btrim(p2.unidad),''),'') as unidad,
             coalesce(p2.factor_conversion,1) as factor,
             case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord,
             p2.id_producto
      from mos.productos p2
    ) t order by sku, ord, id_producto
  ),
  -- stock individual por (skuBase, código) en ESTA zona (CAMBIO 3). Suma por si hubiese filas duplicadas.
  stock_cod as (
    select cs.sku as sku_base, cs.cb as cod_barra, cs.cb_desc, cs.es_equiv,
           sum(coalesce(z.cantidad,0)) as cant
    from cb_sku cs
    join me.stock_zonas z on upper(btrim(z.cod_barras)) = cs.cb
    where upper(btrim(z.zona_id)) in (select alias from zona_aliases)
    group by cs.sku, cs.cb, cs.cb_desc, cs.es_equiv
  ),
  -- desglose codigos[] por skuBase (CAMBIO 3): array de {codBarra, descripcion, stock, esEquivalente}.
  cod_arr as (
    select sk.sku_base,
           jsonb_agg(jsonb_build_object(
             'codBarra', sk.cod_barra,
             'descripcion', coalesce(sk.cb_desc, sk.cod_barra),
             'stock', sk.cant,
             'esEquivalente', sk.es_equiv
           ) order by sk.es_equiv, sk.cod_barra) as codigos,
           sum(sk.cant) as stock_zona
    from stock_cod sk
    group by sk.sku_base
  ),
  -- stock de ALMACÉN por skuBase (sin cambios: wh.stock por cualquier barra del canónico+equivalentes).
  stock_alm as (
    select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) as cant
    from wh.stock s
    join cb_sku cs on cs.cb = upper(btrim(s.cod_producto))
    group by cs.sku
  ),
  -- lotes de la zona por skuBase (sin cambios).
  lotes as (
    select l.sku_base, min(l.fecha_vencimiento) as venc_prox, count(*) as n
    from me.zona_lotes l
    where upper(btrim(l.zona_id)) = v_zona and coalesce(l.cant_restante,0) > 0
    group by l.sku_base
  ),
  -- esperado materializado (sin cambios).
  esp as (
    select e.sku_base, e.esperado, e.tendencia, e.bcg, e.picos
    from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  -- universo = skus con esperado ∪ skus con stock en la zona (sin cambios).
  universo as (
    select sku_base from esp union select sku_base from cod_arr
  ),
  filas as (
    select
      u.sku_base,
      coalesce(sm.descripcion, u.sku_base) as descripcion,
      coalesce(ca.stock_zona, 0) as stock_zona,
      coalesce(es.esperado, 0) as esperada,
      -- CAMBIO 1: el negativo se trata como 0 para comprar → brecha = esperada cuando stock<0; nunca negativa.
      greatest(0, coalesce(es.esperado, 0) - greatest(coalesce(ca.stock_zona, 0), 0)) as brecha,
      (coalesce(ca.stock_zona, 0) < 0) as stock_negativo,                        -- CAMBIO 1 (flag alerta)
      coalesce(sa.cant, 0) as stock_almacen,
      coalesce(es.tendencia, 'NULA') as tendencia,
      coalesce(es.bcg, 'PERRO') as bcg,
      coalesce(es.picos, '[]'::jsonb) as picos,
      lo.venc_prox,
      coalesce(lo.n, 0) as count_lotes,
      coalesce(sm.unidad, '') as unidad,                                         -- CAMBIO 2
      me._riz_es_granel(sm.unidad, sm.factor) as es_granel,                      -- CAMBIO 2
      coalesce(ca.codigos, '[]'::jsonb) as codigos                              -- CAMBIO 3
    from universo u
    left join sku_meta   sm on sm.sku = u.sku_base
    left join cod_arr    ca on ca.sku_base = u.sku_base
    left join esp        es on es.sku_base = u.sku_base
    left join stock_alm  sa on sa.sku_base = u.sku_base
    left join lotes      lo on lo.sku_base = u.sku_base
  )
  select jsonb_build_object(
    'zona', v_zona,
    'filtro', nullif(v_filtro,''),
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'skuBase', f.sku_base,
      'descripcion', f.descripcion,
      'stockZona', f.stock_zona,
      'esperada', f.esperada,
      'brecha', f.brecha,
      'stockNegativo', f.stock_negativo,
      'stockAlmacen', f.stock_almacen,
      'tendencia', f.tendencia,
      'bcg', f.bcg,
      'picos', f.picos,
      'unidad', f.unidad,
      'esGranel', f.es_granel,
      'codigos', f.codigos,
      'vencimientoProximo', case when f.venc_prox is null then null else jsonb_build_object(
        'fecha', to_char((f.venc_prox at time zone 'America/Lima')::date, 'YYYY-MM-DD'),
        'dias', ((f.venc_prox at time zone 'America/Lima')::date - v_hoy)) end,
      'countLotes', f.count_lotes
    ) order by f.brecha desc, f.stock_zona desc), '[]'::jsonb)
  ) into v_data
  from filas f
  where v_filtro = '' or v_filtro is null
     or (v_filtro = 'BRECHA' and f.brecha > 0)
     or (v_filtro = 'SIN_ROTACION' and f.tendencia = 'NULA')
     or (v_filtro in ('CRECIENTE','DECRECIENTE','ESTABLE') and f.tendencia = v_filtro)
     or (v_filtro in ('ESTRELLA','VACA','INTERROGANTE','PERRO') and f.bcg = v_filtro);

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_panel(jsonb) from public;
grant execute on function me.zona_panel(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- me.zona_ajustar_stock(p jsonb { zona (req), codBarra|codBarras (req si no hay skuBase), skuBase?, nuevo (req),
--                                  usuario?, localId? })   (RE-DEFINE 129: ajuste POR CÓDIGO DE BARRA.)
--   El dueño quiere ajustar cada CÓDIGO del desglose por separado (poner un número manual o cero). Ahora:
--     · Si viene codBarra/codBarras → ajusta ESA fila de me.stock_zonas (cod_barras, zona). skuBase es opcional;
--       se deriva del código (mos.productos/equivalencias) solo para enriquecer el log.
--     · Si NO viene código pero sí skuBase → se deriva la barra del canónico del skuBase (comportamiento legacy).
--   Idempotente por localId. Upsert ATÓMICO de la fila (cantidad := nuevo). Log en me.zona_ajuste_log
--   (stock_antes/después/delta). 'nuevo' puede ser 0 o negativo (no se valida signo: es ajuste de inventario).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_ajustar_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_nuevo numeric := nullif(btrim(coalesce(p->>'nuevo','')), '')::numeric;
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  -- acepta codBarra (nuevo, del desglose) y codBarras (alias legacy).
  v_cb    text := upper(nullif(btrim(coalesce(p->>'codBarra', p->>'codBarras', '')), ''));
  v_antes numeric;
  v_existe bigint;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_nuevo is null then
    return jsonb_build_object('ok',false,'error','Requiere zona y nuevo (numérico)');
  end if;
  if v_cb is null and v_sku is null then
    return jsonb_build_object('ok',false,'error','Requiere codBarra (o skuBase para resolver el canónico)');
  end if;

  -- IDEMPOTENCIA por localId: si el gesto ya se aplicó → devolver lo persistido (dedup).
  if v_local is not null then
    select id into v_existe from me.zona_ajuste_log where local_id = v_local limit 1;
    if found then
      return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idLog', v_existe));
    end if;
  end if;

  -- resolver el código concreto: explícito (codBarra/codBarras) → o barra del canónico del skuBase (legacy).
  if v_cb is null then
    select upper(btrim(pr.codigo_barra)) into v_cb
    from mos.productos pr
    where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku
      and nullif(btrim(pr.codigo_barra),'') is not null
    order by (case when coalesce(pr.codigo_producto_base,'')='' and coalesce(pr.factor_conversion,1)=1 then 0 else 1 end), pr.id_producto
    limit 1;
  end if;
  if v_cb is null then
    return jsonb_build_object('ok',false,'error','No se encontró código de barra para el skuBase '||coalesce(v_sku,''));
  end if;

  -- si vino código pero no skuBase, derivar el skuBase del código (para el log; no bloquea si no se resuelve).
  if v_sku is null then
    select sk into v_sku from (
      select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) sk, 0 ord
        from mos.productos pr where upper(btrim(pr.codigo_barra)) = v_cb
      union all
      select e.sku_base, 1 from mos.equivalencias e where upper(btrim(e.codigo_barra)) = v_cb and coalesce(e.activo,true)
    ) t order by ord limit 1;
  end if;

  -- stock antes (suma de esa barra en la zona; normalmente 1 fila por (cod_barras, zona_id)).
  select coalesce(sum(cantidad),0) into v_antes from me.stock_zonas
   where upper(btrim(cod_barras)) = v_cb and upper(btrim(zona_id)) = v_zona;

  -- escribir el nuevo stock (upsert atómico sobre PK (cod_barras, zona_id)).
  insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
  values (v_cb, v_zona, v_nuevo, v_user, now())
  on conflict (cod_barras, zona_id) do update set
    cantidad = excluded.cantidad, usuario = excluded.usuario, fecha_ultimo_registro = now();

  -- log [D] (idempotente por local_id; on conflict do nothing por si dos gestos colisionan).
  insert into me.zona_ajuste_log (zona_id, sku_base, cod_barras, stock_antes, stock_despues, delta, usuario, local_id)
  values (v_zona, v_sku, v_cb, v_antes, v_nuevo, v_nuevo - v_antes, v_user, v_local)
  on conflict (local_id) where local_id is not null do nothing;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'zona', v_zona, 'skuBase', v_sku, 'codBarra', v_cb, 'codBarras', v_cb,
    'stockAntes', v_antes, 'stockDespues', v_nuevo, 'delta', v_nuevo - v_antes));
end;
$fn$;
revoke all on function me.zona_ajustar_stock(jsonb) from public;
grant execute on function me.zona_ajustar_stock(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- WRAPPERS mos.* — la firma jsonb NO cambia (siguen siendo pass-through puro a me.*). Se reafirman idempotentes
-- para que un deploy de SOLO este archivo deje el wrapper apuntando a la versión nueva (el cuerpo ya era genérico).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.zona_panel(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_panel(p);
end;
$fn$;
revoke all on function mos.zona_panel(jsonb) from public;
grant execute on function mos.zona_panel(jsonb) to service_role, authenticated;

create or replace function mos.zona_ajustar_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_ajustar_stock(p);
end;
$fn$;
revoke all on function mos.zona_ajustar_stock(jsonb) from public;
grant execute on function mos.zona_ajustar_stock(jsonb) to service_role, authenticated;
