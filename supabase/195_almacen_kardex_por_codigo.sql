-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 195_almacen_kardex_por_codigo.sql — HISTORIAL POR CÓDIGO (pestañas) en el kardex de ALMACÉN (Zona/RIZ · MOS).
-- App de DINERO en PROD · SOLO LECTURA (no escribe stock/dinero/sync). Aditivo: no cambia el shape "Total" previo.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- CONTEXTO
--   El ámbito ALMACÉN tiene su PROPIO kardex: el de WH (wh.stock_movimientos + wh.guias), separado del de zonas
--   (que vive en ME). mos.almacen_kardex_historial YA lee WH. Esta migración la pone a la PAR de
--   mos.zona_kardex_historial (SQL 192/193):
--     1) acepta skuBase y arma el GRUPO = canónico (mos.productos) ∪ equivalentes activos (mos.equivalencias),
--        EXCLUYENDO presentaciones (idéntica regla que SQL 192). WH solo maneja canónicos/equivalentes.
--     2) cuando el grupo tiene MÁS DE UN código, agrega data.porCodigo : { "<cod>": { codBarra, esEquivalente,
--        descripcion, totalMovimientos, saldoFinal, movimientos:[...] }, ... } — cada código lee SU propio
--        kardex de WH. El front pinta una pestaña por código + la pestaña "Total" (el combinado del grupo).
--     3) 1 solo código en el grupo → porCodigo = null (vista directa, sin pestañas) — como mos.zona_kardex_historial.
--     4) compat por codBarra: se conserva (consulta directa de UN canónico + sus equivalentes activos).
--
-- SHAPE — paritario con mos.zona_kardex_historial para REUSAR la UI de pestañas del front (_zonaKardexConstruirTabs):
--   data: { ambito:'ALMACEN', codBarra, codBarras[], skuBase, reconstruido:false, totalMovimientos, movimientos[],
--           porCodigo: null | { "<cod>": { codBarra, esEquivalente, descripcion, totalMovimientos, saldoFinal,
--                                          movimientos[] } } }
--   (El kardex de almacén NO reconstruye contra stock_zonas — los saldos son los stock_despues REALES de WH —
--    por eso aquí no hay 'cuadra'/'stockZonas'; el front trata almacén como "saldo = último movimiento".)
--
-- IDEMPOTENTE (create or replace). No cambia firmas públicas, ni flags, ni sync. No toca dinero.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

set search_path to '';

-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ HELPER INTERNO · mos._almacen_kardex_movs(codes[]) → jsonb de MOVIMIENTOS del kardex de ALMACÉN (WH) para   ║
-- ║ un conjunto de códigos (1 = pestaña de un código · N = Total del grupo). Mismo objeto-fila que la RPC, en   ║
-- ║ orden fecha DESC (shape WH). Reusado por el Total y por cada pestaña → algoritmo IDÉNTICO.                  ║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
create or replace function mos._almacen_kardex_movs(v_codes text[])
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $fn$
declare
  v_movs jsonb := '[]'::jsonb;
begin
  if v_codes is null or coalesce(array_length(v_codes,1),0) = 0 then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(row order by row_fecha desc, row_id desc), '[]'::jsonb) into v_movs
  from (
    select
      m.fecha as row_fecha,
      m.id_mov as row_id,
      jsonb_build_object(
        'idGuia',        coalesce(m.origen,''),
        'fecha',         m.fecha,
        'tipo',          me._kardex_label(
                            case
                              when upper(coalesce(m.tipo_operacion,'')) like '%AUDITORIA%' then 'AUDITORIA'
                              when upper(coalesce(m.tipo_operacion,'')) like '%AJUSTE%'    then 'AJUSTE'
                              when upper(coalesce(m.tipo_operacion,'')) like '%ENVASADO%'  then 'ENVASADO'
                              when upper(coalesce(m.tipo_operacion,'')) like '%INICIAL%'   then 'INICIAL'
                              else (case when coalesce(m.delta,0) >= 0 then 'INGRESO' else 'SALIDA' end)
                            end, coalesce(m.delta,0)),
        'tipoOperacion', coalesce(m.tipo_operacion,''),
        'esIngreso',     (coalesce(m.delta,0) > 0),
        'cantidad',      abs(coalesce(m.delta,0)),
        'saldo',         m.stock_despues,
        'stockAntes',    m.stock_antes,
        'usuario',       coalesce(nullif(btrim(m.usuario),''),'—'),
        'origen',        coalesce(m.origen,''),
        'estado',        'CERRADA',
        'fuente',        case when upper(coalesce(m.tipo_operacion,'')) like '%AJUSTE%'
                               or upper(coalesce(m.tipo_operacion,'')) like '%AUDITORIA%' then 'ajuste' else 'guia' end,
        'aplicado',      true,
        -- ── LOTE (sólo INGRESOS, donde es atable) ────────────────────────────────────────────────────────────
        'idLote',          lote.id_lote,
        'loteVencimiento', lote.fecha_vencimiento,
        -- ── ZONA destino (sólo SALIDAS hacia zona; '' si no aplica / sin zona conocida) ───────────────────────
        'zona',          case when coalesce(m.delta,0) < 0 then mos._norm_zona_almacen(g.id_zona) else '' end,
        'destino',       case when coalesce(m.delta,0) < 0 then mos._norm_zona_almacen(g.id_zona) else '' end
      ) as row
    from wh.stock_movimientos m
    -- guía de la salida → zona destino + usuario autoritativo
    left join wh.guias g
           on coalesce(m.delta,0) < 0 and g.id_guia = m.origen
    -- lote del INGRESO: (1) por id_guia (proveedor) ó (2) por cod+cantidad+ventana de fecha (envasado).
    left join lateral (
      select lv.id_lote,
             case when lv.fecha_vencimiento is not null
                  then to_char(lv.fecha_vencimiento, 'YYYY-MM-DD"T"HH24:MI:SSOF') else null end as fecha_vencimiento
        from wh.lotes_vencimiento lv
       where coalesce(m.delta,0) > 0
         and btrim(lv.cod_producto) = btrim(m.cod_producto)
         and (
               lv.id_guia = m.origen
               or (lv.cantidad_inicial = m.delta
                   and abs(extract(epoch from (lv.fecha_creacion - m.fecha))) <= 120)
             )
       order by (lv.id_guia = m.origen) desc,   -- preferimos el match exacto por guía
                abs(extract(epoch from (coalesce(lv.fecha_creacion, m.fecha) - m.fecha))) asc
       limit 1
    ) lote on true
    where btrim(m.cod_producto) = any(v_codes)
  ) s;

  return v_movs;
end;
$fn$;
revoke all on function mos._almacen_kardex_movs(text[]) from public;
grant execute on function mos._almacen_kardex_movs(text[]) to service_role, authenticated;

-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ mos.almacen_kardex_historial — Total (grupo) + porCodigo (cuando hay >1 código). Compat por codBarra.       ║
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

  -- PESTAÑAS POR CÓDIGO — sólo cuando se consulta el grupo por skuBase y hay MÁS DE UN código.
  --   Cada código lee SU propio kardex de WH (movimientos independientes). El front pinta una pestaña por entrada
  --   + la pestaña "Total" (la raíz). 1 código → sin porCodigo (vista directa).
  if v_pestana is null and v_sku is not null and coalesce(array_length(v_codes,1),0) > 1 then
    foreach v_one in array v_codes loop
      v_one_movs := mos._almacen_kardex_movs(array[v_one]);
      -- saldoFinal = saldo del movimiento más reciente (movs vienen DESC); null/0 si no hay movimientos.
      v_saldo := case when jsonb_array_length(v_one_movs) > 0
                      then (v_one_movs->0->>'saldo')::numeric else 0 end;
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
          'movimientos',      v_one_movs));
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'ambito', 'ALMACEN', 'codBarra', v_cod, 'codBarras', to_jsonb(v_codes), 'skuBase', v_sku,
      'cod', v_pestana,                              -- eco del filtro de pestaña (null si Total/grupo)
      'reconstruido', false, 'totalMovimientos', jsonb_array_length(v_movs),
      'movimientos', v_movs,
      'porCodigo', case when v_porcod = '{}'::jsonb then null else v_porcod end))
    || mos._frescura_sombra();
end;
$function$;
revoke all on function mos.almacen_kardex_historial(jsonb) from public;
grant execute on function mos.almacen_kardex_historial(jsonb) to service_role, authenticated;
