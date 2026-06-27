-- ════════════════════════════════════════════════════════════════════════════
-- 215 · wh.crear_pickup_cierre_caja(p) — NACE el pickup en SUPABASE (mata el alta GAS)
-- ════════════════════════════════════════════════════════════════════════════
-- Reemplaza a warehouseMos/gas/Guias.gs::recibirPickupDeME + el alta de la Hoja
-- + _dualWritePickupWH. ME, al cerrar caja, llama ESTA RPC directo (sin GAS).
-- Computa la reposición desde me.ventas/me.ventas_detalle de la caja:
--   · excluye anuladas (forma_pago='ANULADO' — fuente de verdad de anulación en ME)
--   · agrupa por canónico (mos.productos.sku_base), solicitado = Σ cantidad×factor
--     (el pickup SIEMPRE habla en unidades del canónico — espejo del algoritmo ME)
--   · codigosOriginales = codigo_barra del canónico + equivalencias activas
-- Inserta en wh.pickups (ME_CIERRE_CAJA, PENDIENTE) → dispara el trigger 214 que
-- consolida en la lista acumulada de la zona. Idempotente por id_caja (id estable).
-- 100% Supabase. Sin Hoja, sin UrlFetchApp.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function wh.crear_pickup_cierre_caja(p jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_caja   text := nullif(btrim(coalesce(p->>'id_caja', p->>'idCaja', '')), '');
  v_ventas jsonb := coalesce(p->'ventas', '[]'::jsonb);
  v_zona   text;
  v_cajero text;
  v_idp    text;
  v_items  jsonb;
  v_n      int;
  v_n2     int;
  v_now    timestamptz := now();
begin
  if v_caja is null then return jsonb_build_object('ok', false, 'error', 'Requiere id_caja'); end if;

  -- La caja debe existir (autorización mínima: no se inventan pickups de cajas falsas).
  select coalesce(nullif(btrim(zona_id),''), '') , coalesce(vendedor,'')
    into v_zona, v_cajero
    from me.cajas where id_caja = v_caja;
  if not found then return jsonb_build_object('ok', false, 'error', 'Caja no encontrada'); end if;

  v_idp := 'PCK-CC-' || v_caja;   -- id estable → idempotente

  -- Idempotencia: si ya se creó el pickup de esta caja, no duplicar (devolver el existente).
  perform 1 from wh.pickups where id_pickup = v_idp;
  if found then
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('idPickup', v_idp, 'dedup', true));
  end if;

  -- ── Reposición por canónico. Fuente: p.ventas [{cod_barras,cantidad}] si ME la pasa
  --    (cero riesgo de timing al cerrar caja); si no, las ventas NO anuladas de me.ventas.
  --    La resolución a canónico + factor ocurre 100% en SQL (mos.productos). ──────────
  with src as (
    select btrim(e->>'cod_barras') as cod_barras, null::text as sku,
           wh._num(coalesce(e->>'cantidad','0')) as cantidad
      from jsonb_array_elements(case when jsonb_typeof(v_ventas)='array' and jsonb_array_length(v_ventas) > 0
                                     then v_ventas else '[]'::jsonb end) e
    union all
    select vd.cod_barras, vd.sku, wh._num(vd.cantidad::text)
      from me.ventas v
      join me.ventas_detalle vd on vd.id_venta = v.id_venta
     where v.id_caja = v_caja
       and upper(coalesce(v.forma_pago,'')) <> 'ANULADO'
       and not (jsonb_typeof(v_ventas)='array' and jsonb_array_length(v_ventas) > 0)
  ),
  det as (
    select coalesce(
             (select pp.sku_base from mos.productos pp where pp.codigo_barra = src.cod_barras limit 1),
             (select pp.sku_base from mos.productos pp where src.sku is not null and pp.sku_base    = src.sku limit 1),
             (select pp.sku_base from mos.productos pp where src.sku is not null and pp.id_producto = src.sku limit 1),
             nullif(src.sku,''), nullif(src.cod_barras,'')
           ) as skub,
           src.cantidad * coalesce(
             (select pp.factor_conversion from mos.productos pp where pp.codigo_barra = src.cod_barras limit 1),
             (select pp.factor_conversion from mos.productos pp where src.sku is not null and pp.sku_base = src.sku limit 1),
             1) as q
      from src
  ),
  agg as (
    select skub, sum(q) as solicitado
      from det
     where skub is not null and skub <> ''
     group by skub
    having sum(q) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'skuBase', a.skub,
           'nombre', coalesce(
              (select pp.descripcion from mos.productos pp where pp.sku_base = a.skub order by (pp.codigo_producto_base is null) desc limit 1),
              a.skub),
           'solicitado', a.solicitado,
           'despachado', 0,
           'codigosOriginales', coalesce((
              select jsonb_agg(distinct cod) from (
                select pp.codigo_barra cod from mos.productos pp
                  where pp.sku_base = a.skub and coalesce(pp.codigo_barra,'') <> ''
                union
                select e.codigo_barra from mos.equivalencias e
                  where e.sku_base = a.skub and e.activo and coalesce(e.codigo_barra,'') <> ''
              ) q), '[]'::jsonb)
         ) order by a.skub), '[]'::jsonb)
    into v_items
    from agg a;

  v_n := jsonb_array_length(coalesce(v_items, '[]'::jsonb));
  if v_n = 0 then
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('idPickup', null, 'items', 0, 'vacio', true));
  end if;

  -- Insert → el trigger 214 consolida en la acumulada de la zona.
  -- [40x] ON CONFLICT race-safe: un doble-cierre concurrente NO duplica ni rompe
  -- (el segundo no inserta y se reporta dedup, sin PK violation).
  insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
  values (v_idp, 'ME_CIERRE_CAJA', 'PENDIENTE', v_items, v_zona,
          'idCaja=' || v_caja || ' · cajero=' || v_cajero, coalesce(nullif(v_cajero,''),'ME_AUTO'), v_now, v_now)
  on conflict (id_pickup) do nothing;
  get diagnostics v_n2 = row_count;
  if v_n2 = 0 then
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('idPickup', v_idp, 'dedup', true));
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('idPickup', v_idp, 'items', v_n, 'zona', v_zona));
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM);
end;
$fn$;

revoke all on function wh.crear_pickup_cierre_caja(jsonb) from public;
grant execute on function wh.crear_pickup_cierre_caja(jsonb) to authenticated, service_role;
