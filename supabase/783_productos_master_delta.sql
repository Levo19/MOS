-- 783 · MOS: catálogo DELTA para el panel (14-ago-2026).
-- Problema: cada bump de catalogo_version re-descargaba productos_master_rls COMPLETO
-- (5.8 MB) en cada dispositivo. En días de cambios masivos (ayer: 31 bumps por la
-- regularización IGV) los equipos con wifi débil se arrastraban.
-- Fix (mismo patrón que el delta WH, SQL 277): mos.productos_master_delta(p{desde})
-- devuelve SOLO los productos con updated_at >= desde (o cuyos tramos cambiaron),
-- los eliminados (tombstones) y server_ts para el próximo baseline. Solape -2s
-- idempotente (merge por id_producto). El front cae a full ante cualquier anomalía.
begin;

-- 1 · precio_tramos no tenía touch de updated_at (solo default al insertar): un UPDATE
--     de tramo no viajaría por el delta. Mismo trigger que mos.productos.
drop trigger if exists tg_touch_updated_at on mos.precio_tramos;
create trigger tg_touch_updated_at
  before insert or update on mos.precio_tramos
  for each row execute function mos._touch_updated_at();

-- 2 · La RPC delta — shape de fila IDÉNTICO a productos_master_rls (to_jsonb + segmentos_precio).
create or replace function mos.productos_master_delta(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
set statement_timeout to '15s'
as $function$
declare
  v_desde timestamptz := nullif(btrim(coalesce(p->>'desde','')),'')::timestamptz;
  v_cut   timestamptz;
  v_prod  jsonb; v_elim jsonb; v_count int; v_total int;
  v_hb timestamptz; v_ttl int; v_fresh boolean;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_desde is null then return jsonb_build_object('ok', false, 'error', 'DELTA_SIN_DESDE'); end if;
  v_cut := v_desde - interval '2 seconds';   -- solape idempotente (borde de reloj)

  select coalesce(jsonb_agg(
           (to_jsonb(t) || jsonb_build_object('segmentos_precio', coalesce(pt.tramos, '[]'::jsonb)))
           order by t.id_producto), '[]'::jsonb), count(*)
    into v_prod, v_count
    from mos.productos t
    left join mos.precio_tramos pt on pt.sku_base = t.sku_base
   where t.updated_at >= v_cut
      or exists (select 1 from mos.precio_tramos x
                  where x.sku_base = t.sku_base and x.updated_at >= v_cut);

  select coalesce(jsonb_agg(distinct ts.id_producto), '[]'::jsonb)
    into v_elim
    from mos.catalogo_tombstones ts
   where ts.deleted_at >= v_cut;

  -- Gate de frescura idéntico al full (money-safe: jamás servir sombra muerta).
  select count(*) into v_total from mos.productos;
  begin select (valor)::timestamptz into v_hb from mos.config where clave='CATALOGO_SYNC_HEARTBEAT' limit 1;
  exception when others then v_hb := null; end;
  begin select (valor)::int into v_ttl from mos.config where clave='CATALOGO_SYNC_TTL_MIN' limit 1;
  exception when others then v_ttl := null; end;
  v_ttl := coalesce(v_ttl, 180);
  if v_ttl < 15 then v_ttl := 15; end if;
  if v_ttl > 1440 then v_ttl := 1440; end if;
  v_fresh := (v_hb is not null) and (now() - v_hb < make_interval(mins => v_ttl)) and (v_total > 0);

  return jsonb_build_object('ok', true,
    'productos',  v_prod,
    'eliminados', v_elim,
    '_count',     v_count,
    '_fresh',     v_fresh,
    'server_ts',  now());
end;
$function$;

revoke all on function mos.productos_master_delta(jsonb) from public;
grant execute on function mos.productos_master_delta(jsonb) to authenticated, service_role;

commit;
