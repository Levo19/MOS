-- ════════════════════════════════════════════════════════════════════════════
-- 252 · REPARACIÓN #4 (Etapa 2) — mos.me_historial_venta normaliza ts→timestamp
-- ════════════════════════════════════════════════════════════════════════════
-- El render del modal (_tkHistRender) lee `ev.timestamp || ev.fecha` para la fecha, pero la sombra
-- guarda los eventos con clave `ts` (ver me.ventas.historial_cambios). Sin normalizar, el path directo
-- mostraría los eventos SIN fecha. Acá agregamos `timestamp` (desde ts/fecha) a cada evento que no lo
-- tenga → el path Supabase queda >= GAS (muestra la fecha siempre). Resto del shape intacto (passthrough).
-- ════════════════════════════════════════════════════════════════════════════
create or replace function mos.me_historial_venta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')), '');
  v_raw   jsonb;
  v_hist  jsonb;
  v_found boolean := false;
  v_fr    jsonb := mos._frescura_sombra();
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido') || v_fr; end if;

  select true, coalesce(v.historial_cambios, '[]'::jsonb)
    into v_found, v_raw
    from me.ventas v where v.id_venta = v_id limit 1;

  -- si historial_cambios fuese {historial:[...]} en vez de array, desenvolver.
  if v_raw is not null and jsonb_typeof(v_raw) = 'object' and v_raw ? 'historial' then
    v_raw := v_raw->'historial';
  end if;
  if v_raw is null or jsonb_typeof(v_raw) <> 'array' then v_raw := '[]'::jsonb; end if;

  -- normalizar: garantizar `timestamp` por evento (desde ts/fecha) preservando el orden original.
  select coalesce(jsonb_agg(
           case when (e ? 'timestamp') or (e ? 'fecha') then e
                else e || jsonb_build_object('timestamp', coalesce(e->>'ts', e->>'fecha')) end
           order by ord), '[]'::jsonb)
    into v_hist
    from jsonb_array_elements(v_raw) with ordinality as t(e, ord);

  return jsonb_build_object('ok', true, 'encontrado', coalesce(v_found,false), 'historial', v_hist) || v_fr;
end;
$fn$;
revoke all on function mos.me_historial_venta(jsonb) from public;
grant execute on function mos.me_historial_venta(jsonb) to service_role, authenticated;

notify pgrst, 'reload schema';
