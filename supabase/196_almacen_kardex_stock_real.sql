-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 196_almacen_kardex_stock_real.sql — STOCK REAL (wh.stock) en el kardex de ALMACÉN (Zona/RIZ · MOS).
-- App de DINERO en PROD · SOLO LECTURA. Aditivo: NO cambia el shape previo (sólo agrega campos nuevos).
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- POR QUÉ (revisión senior 40x · vector #1/#3)
--   El kardex de almacén reconstruía el "stock actual" como el saldo (stock_despues) del ÚLTIMO movimiento.
--   Eso NO siempre cuadra con la verdad del almacén — wh.stock.cantidad_disponible:
--     • Productos cuyo stock se fijó SIN escribir un movimiento (p.ej. COCINERO 7750243068048 = -1 con 0 movs).
--     • Grupos multi-código: el "Total" tomaba el saldo del último movimiento de UN solo código, no la suma del
--       grupo. Medición live: 52 de 104 grupos multi-código diferían entre saldo-último-mov y Σ(wh.stock).
--   La app WH (getHistorialStock) YA muestra el "Stock actual" desde wh.stock EN VIVO (no del último mov) — ver
--   warehouseMos/js/app.js _refrescarStockVivo + stockTotal=Σ cantidadDisponible. Para que MOS == WH (auditoría
--   de dinero), el kardex de almacén debe exponer ese MISMO stock autoritativo.
--
-- QUÉ AGREGA (sin romper nada existente)
--   data.stockReal          → Σ wh.stock.cantidad_disponible de TODOS los códigos del conjunto consultado
--                             (= el grupo entero, o el único código si vino cod/codBarra/pestaña). null si ningún
--                             código tiene fila en wh.stock.
--   data.cuadraStock        → ¿el saldo del último movimiento (totalMovimientos>0) == stockReal? (informativo).
--   data.porCodigo[c].stockReal   → wh.stock.cantidad_disponible de ESE código (null si no tiene fila).
--   data.porCodigo[c].cuadraStock → ¿saldoFinal(último mov del código) == su stockReal?
--   (El front pinta "stock actual" desde stockReal y marca ✓ cuadra / ⚠ revisar según cuadraStock, igual que WH.)
--
-- IDEMPOTENTE (create or replace). No toca firmas públicas, flags, sync ni dinero.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

set search_path to '';

-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ HELPER · mos._almacen_stock_real(codes[]) → Σ wh.stock.cantidad_disponible de un conjunto de códigos.       ║
-- ║ Match por upper(btrim(...)) (wh.stock tiene 1 código en minúscula; los códigos del kardex ya vienen upper). ║
-- ║ Devuelve NULL si NINGÚN código tiene fila en wh.stock (producto sin stock conocido — no inventamos 0).      ║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
create or replace function mos._almacen_stock_real(v_codes text[])
returns numeric
language sql
stable security definer
set search_path = ''
as $fn$
  select sum(s.cantidad_disponible)
    from wh.stock s
   where v_codes is not null
     and upper(btrim(s.cod_producto)) = any (
           select upper(btrim(c)) from unnest(v_codes) c
         );
$fn$;
revoke all on function mos._almacen_stock_real(text[]) from public;
grant execute on function mos._almacen_stock_real(text[]) to service_role, authenticated;

-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ mos.almacen_kardex_historial — Total + porCodigo + STOCK REAL (wh.stock) por código y por grupo.            ║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
create or replace function mos.almacen_kardex_historial(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $function$
declare
  v_cod    text := nullif(btrim(coalesce(p->>'codBarra','')),'');
  v_sku    text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  -- Eco de pestaña (paridad con mos.zona_kardex_historial): si llega p.cod, la unidad es ese único código.
  v_pestana text := nullif(btrim(coalesce(p->>'cod','')),'');
  v_codes  text[];
  v_movs   jsonb := '[]'::jsonb;
  v_porcod jsonb := '{}'::jsonb;
  v_one    text;
  v_one_movs jsonb;
  v_saldo  numeric;
  v_desc   text;
  v_es_eq  boolean;
  v_stock_real      numeric;   -- Σ wh.stock del conjunto consultado (grupo / único código)
  v_total_saldo     numeric;   -- saldo del último movimiento del Total (null si sin movs)
  v_one_stock       numeric;   -- stock real del código de la pestaña
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- Resolver el conjunto de códigos. WH solo maneja canónicos (codigo_barra) + equivalentes activos.
  if v_pestana is not null then
    -- Consulta de PESTAÑA: la unidad consultada es ese único código.
    v_codes := array[upper(btrim(v_pestana))];
    v_cod   := v_codes[1];
  elsif v_cod is not null then
    -- Compat: UN canónico + sus equivalentes activos (mismo conjunto que devolvía la versión previa).
    select coalesce(array_agg(distinct c), array[upper(btrim(v_cod))]) into v_codes
      from (
        select upper(btrim(v_cod)) as c
        union all
        select upper(btrim(ev.codigo_barra))
          from mos.equivalencias ev
         where coalesce(ev.activo,true)
           and ev.sku_base in (select pr.sku_base from mos.productos pr where pr.codigo_barra = v_cod)
           and nullif(btrim(ev.codigo_barra),'') is not null
      ) q;
    v_cod := v_codes[1];
  elsif v_sku is not null then
    -- [192] grupo = canónico (mos.productos, EXCLUYE PRESENTACION) ∪ equivalentes activos (mos.equivalencias).
    select coalesce(array_agg(distinct cb), array[]::text[]) into v_codes
      from (
        select upper(btrim(pr.codigo_barra)) cb
          from mos.productos pr
         where pr.sku_base = v_sku
           and nullif(btrim(pr.codigo_barra),'') is not null
           and pr.tipo_producto::text is distinct from 'PRESENTACION'
        union
        select upper(btrim(e.codigo_barra))
          from mos.equivalencias e
         where e.sku_base = v_sku
           and coalesce(e.activo,true)
           and nullif(btrim(e.codigo_barra),'') is not null
      ) t;
    if coalesce(array_length(v_codes,1),0) = 0 then
      return jsonb_build_object('ok', false, 'error', 'skuBase sin codigo_barra (canónico/equivalente) en catálogo');
    end if;
    v_cod := v_codes[1];
  else
    return jsonb_build_object('ok', false, 'error', 'Requiere codBarra, cod o skuBase');
  end if;

  -- TOTAL (combinado del conjunto consultado: el grupo entero, o el único código si vino cod/codBarra/pestaña).
  v_movs := mos._almacen_kardex_movs(v_codes);

  -- STOCK REAL autoritativo (wh.stock) del conjunto + saldo del último movimiento → ¿cuadra?
  v_stock_real  := mos._almacen_stock_real(v_codes);
  v_total_saldo := case when jsonb_array_length(v_movs) > 0 then (v_movs->0->>'saldo')::numeric else null end;

  -- PESTAÑAS POR CÓDIGO — sólo cuando se consulta el grupo por skuBase y hay MÁS DE UN código.
  --   Cada código lee SU propio kardex de WH (movimientos independientes). El front pinta una pestaña por entrada
  --   + la pestaña "Total" (la raíz). 1 código → sin porCodigo (vista directa).
  if v_pestana is null and v_sku is not null and coalesce(array_length(v_codes,1),0) > 1 then
    foreach v_one in array v_codes loop
      v_one_movs := mos._almacen_kardex_movs(array[v_one]);
      -- saldoFinal = saldo del movimiento más reciente (movs vienen DESC); null/0 si no hay movimientos.
      v_saldo := case when jsonb_array_length(v_one_movs) > 0
                      then (v_one_movs->0->>'saldo')::numeric else 0 end;
      v_one_stock := mos._almacen_stock_real(array[v_one]);   -- stock real autoritativo de ESTE código
      -- descripción + esEquivalente del código (equivalencia tiene prioridad de etiqueta de equiv).
      select e.es_eq, e.descripcion into v_es_eq, v_desc from (
        select true as es_eq, nullif(btrim(eq.descripcion),'') as descripcion, 1 as ord
          from mos.equivalencias eq
         where upper(btrim(eq.codigo_barra)) = v_one and coalesce(eq.activo,true)
        union all
        select false, nullif(btrim(pr.descripcion),''), 0
          from mos.productos pr
         where upper(btrim(pr.codigo_barra)) = v_one
        order by ord desc limit 1
      ) e;
      v_porcod := v_porcod || jsonb_build_object(
        v_one,
        jsonb_build_object(
          'codBarra',         v_one,
          'esEquivalente',    coalesce(v_es_eq,false),
          'descripcion',      coalesce(v_desc, v_one),
          'totalMovimientos', jsonb_array_length(v_one_movs),
          'saldoFinal',       v_saldo,
          'stockReal',        v_one_stock,                                       -- wh.stock de este código (null si no hay)
          'cuadraStock',      case when jsonb_array_length(v_one_movs) = 0 then null
                                   else (v_saldo is not distinct from v_one_stock) end,
          'movimientos',      v_one_movs));
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'ambito', 'ALMACEN', 'codBarra', v_cod, 'codBarras', to_jsonb(v_codes), 'skuBase', v_sku,
      'cod', v_pestana,                              -- eco del filtro de pestaña (null si Total/grupo)
      'reconstruido', false, 'totalMovimientos', jsonb_array_length(v_movs),
      'stockReal',   v_stock_real,                   -- Σ wh.stock del conjunto (autoritativo, == lo que muestra WH)
      'cuadraStock', case when jsonb_array_length(v_movs) = 0 then null
                          else (v_total_saldo is not distinct from v_stock_real) end,
      'movimientos', v_movs,
      'porCodigo', case when v_porcod = '{}'::jsonb then null else v_porcod end))
    || mos._frescura_sombra();
end;
$function$;
revoke all on function mos.almacen_kardex_historial(jsonb) from public;
grant execute on function mos.almacen_kardex_historial(jsonb) to service_role, authenticated;
