-- 145 · productos_master_rls: resuelve segmentos_precio por sku_base (override desde mos.precio_tramos)
-- → TODOS los miembros del grupo (canónico + presentaciones) muestran los MISMOS tramos. Solo cambia
-- el SELECT de productos (join + override); el resto (heartbeat/fresh/ttl) idéntico.
create or replace function mos.productos_master_rls()
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_prod jsonb; v_count int; v_max timestamptz; v_hb timestamptz; v_ttl int; v_fresh boolean;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- Productos COMPLETOS + tramos resueltos por sku_base (precio_tramos override la columna por-fila).
  select coalesce(jsonb_agg(
           (to_jsonb(t) || jsonb_build_object('segmentos_precio', coalesce(pt.tramos, '[]'::jsonb)))
           order by t.id_producto), '[]'::jsonb), count(*)
    into v_prod, v_count
    from mos.productos t
    left join mos.precio_tramos pt on pt.sku_base = t.sku_base;

  select greatest(max(t.updated_at), (select max(updated_at) from mos.precio_tramos)) into v_max from mos.productos t;

  begin select (valor)::timestamptz into v_hb from mos.config where clave='CATALOGO_SYNC_HEARTBEAT' limit 1;
  exception when others then v_hb := null; end;
  begin select (valor)::int into v_ttl from mos.config where clave='CATALOGO_SYNC_TTL_MIN' limit 1;
  exception when others then v_ttl := null; end;
  v_ttl := coalesce(v_ttl, 180);
  if v_ttl < 15 then v_ttl := 15; end if;
  if v_ttl > 1440 then v_ttl := 1440; end if;
  v_fresh := (v_hb is not null) and (now() - v_hb < make_interval(mins => v_ttl)) and (v_count > 0);

  return jsonb_build_object('ok', true, 'productos', v_prod, '_count', v_count,
    '_heartbeat', v_hb, '_max_updated', v_max, '_now', now(), '_ttl_min', v_ttl, '_fresh', v_fresh);
end;
$fn$;
