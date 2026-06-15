-- 77_mos_historial_precios_rls.sql — [MIGRACIÓN MOS · FASE 1] Habilitar historial_precios_lista para LECTURA DIRECTA del navegador.
-- Espeja la acción GAS `getHistorialPrecios` (gas/Productos.gs:928) → {ok:true, data:[...]} (filas camelCase del header de la hoja).
--
-- ⚠️ INERTE por diseño: re-define mos.historial_precios_lista agregando gate de claim app='MOS' + señal `_fresh`,
--    y CORRIGE el grant. El frontend NO la invoca hasta activar el flag por-acción `mos_historial_directo`
--    (default OFF). Hoy `getHistorialPrecios` ni siquiera lo consume la PWA — se cabla por completitud/futuro.
--
-- ── FIX DE SEGURIDAD (grant PUBLIC en producción) ────────────────────────────────────────────────────────
--   El 12_fase1d_mos_historial.sql declaraba grant SOLO service_role, pero en la DB la función quedó con
--   `language sql` SIN revoke → PostgreSQL da EXECUTE a PUBLIC por defecto. Verificado en vivo: grantee=PUBLIC.
--   Eso significa que CUALQUIER anónimo (anon key) podía llamar la RPC y leer el historial de precios.
--   Este archivo lo cierra: `revoke all from public` + `grant ... to service_role, authenticated` + gate interno
--   mos._claim_ok() → solo service_role/GAS o JWT app='MOS'. Cualquier otro authenticated/anon → APP_NO_AUTORIZADA.
--
-- ── GATE DE FRESCURA ─────────────────────────────────────────────────────────────────────────────────────
--   historial_precios_lista lee SOLO de mos.historial_precios, una SOMBRA sincronizada por el trigger GAS
--   `syncMOSReciente` (cada 15 min, puede morir en silencio). Mismo criterio que finanzas: _fresh se basa en
--   mos.config[MOS_SYNC_HEARTBEAT] + TTL (MOS_SYNC_TTL_MIN, default 30 min, sembrado en 76_…). Si _fresh=false
--   → el FRONT cae a GAS (lee la hoja viva). La RPC SIEMPRE devuelve los datos; el front decide con _fresh.
--   _fresh va como SIBLING de ok/data → backward-compatible con el comparador GAS (compararHistorialPreciosMOS
--   solo lee r.data.data).
--
-- La SELECT del cuerpo es IDÉNTICA a 12_fase1d_mos_historial.sql (mismos filtros sku/codigo/limit, mismo orden
-- id desc → últimas N, salida en orden ascendente como slice(-limit), misma TZ Lima para fecha).
-- ============================================================

create schema if not exists mos;

create or replace function mos.historial_precios_lista(p_sku text default null, p_codigo text default null, p_limit int default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_data  jsonb;
  v_hb    timestamptz;
  v_ttl   int;
  v_fresh boolean;
begin
  -- Gate de claim: service_role/GAS (sin claim) o JWT app='MOS'. Resto (anon/mosExpress/warehouseMos) → fuera.
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  with filtered as (
    select * from mos.historial_precios
    where (p_sku    is null or p_sku=''    or sku_base    = p_sku)
      and (p_codigo is null or p_codigo='' or codigo_barra = p_codigo)
  ),
  sel as (
    select * from filtered
    order by id desc                                  -- últimas (más recientes) primero
    limit (case when p_limit is not null and p_limit>0 then p_limit else 2147483647 end)
  )
  select jsonb_build_object('ok', true, 'data', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',             id,
      'skuBase',        coalesce(sku_base,''),
      'codigoBarra',    coalesce(codigo_barra,''),
      'descripcion',    coalesce(descripcion,''),
      'precioAnterior', precio_anterior,
      'precioNuevo',    precio_nuevo,
      'usuario',        coalesce(usuario,''),
      'motivo',         coalesce(motivo,''),
      'appOrigen',      coalesce(app_origen,''),
      'fecha',          case when fecha is not null then to_char(fecha at time zone 'America/Lima','YYYY-MM-DD') else '' end
    ) order by id)                                     -- salida en orden de hoja ascendente (como slice)
    from sel), '[]'::jsonb))
  into v_data;

  -- frescura de la sombra MOS (reusa MOS_SYNC_HEARTBEAT/MOS_SYNC_TTL_MIN del 76_).
  begin
    select (valor)::timestamptz into v_hb from mos.config where clave = 'MOS_SYNC_HEARTBEAT' limit 1;
  exception when others then v_hb := null;
  end;
  begin
    select (valor)::int into v_ttl from mos.config where clave = 'MOS_SYNC_TTL_MIN' limit 1;
  exception when others then v_ttl := null;
  end;
  v_ttl := coalesce(v_ttl, 30);
  if v_ttl < 15   then v_ttl := 15;   end if;
  if v_ttl > 1440 then v_ttl := 1440; end if;
  v_fresh := (v_hb is not null) and (now() - v_hb < make_interval(mins => v_ttl));

  return v_data || jsonb_build_object('_fresh', v_fresh, '_heartbeat', v_hb, '_now', now(), '_ttl_min', v_ttl);
end;
$fn$;

-- FIX seguridad: cerrar el grant PUBLIC heredado del language-sql y dar acceso explícito.
revoke all on function mos.historial_precios_lista(text, text, int) from public;
grant execute on function mos.historial_precios_lista(text, text, int) to service_role, authenticated;
