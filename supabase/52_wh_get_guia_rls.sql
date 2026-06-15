-- 52_wh_get_guia_rls.sql — [PASO 5 · B3 backend] getGuia(id): 1 guía + su detalle (join), para lectura directa.
-- Reemplaza traer las 547 guías para buscar una. Devuelve CRUDO (snake_case); el FRONT mapea (specs guias+guia_detalle)
-- y enriquece el detalle con descripciones desde OfflineManager.getProductosCache() (cache local, offline-first).
-- Gate wh._claim_ok(). Replica getGuia (warehouseMos/gas/Guias.gs): guia por id + detalle filtrado, ordenado por linea.

create or replace function wh.get_guia_rls(p_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_guia jsonb;
  v_det  jsonb;
begin
  if not wh._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if p_id is null or btrim(p_id) = '' then
    return jsonb_build_object('ok', false, 'error', 'FALTA_ID_GUIA');
  end if;
  select to_jsonb(g) into v_guia from wh.guias g where g.id_guia = p_id limit 1;
  if v_guia is null then
    return jsonb_build_object('ok', false, 'error', 'Guía no encontrada: ' || p_id);
  end if;
  select coalesce(jsonb_agg(to_jsonb(d) order by d.linea), '[]'::jsonb) into v_det
    from wh.guia_detalle d where d.id_guia = p_id;
  return jsonb_build_object('ok', true, 'guia', v_guia, 'detalle', v_det);
end;
$fn$;

revoke all on function wh.get_guia_rls(text) from public;
grant execute on function wh.get_guia_rls(text) to service_role, authenticated;
