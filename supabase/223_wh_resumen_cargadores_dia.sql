-- 223_wh_resumen_cargadores_dia.sql — getResumenCargadoresDia 100% Supabase (Frente 4, read-only).
-- Cierra asimetría: add/remove_cargador_dia YA escriben directo a wh.cargadores_log, pero el RESUMEN
-- (badge/topbar) leía la Hoja vía GAS. Agrupa ACTIVO del día por id_cargador. Comparación de día IDÉNTICA
-- a add_cargador_dia: (fecha at time zone 'America/Lima')::date = v_dia (fecha está anclada a medianoche Lima).
create or replace function wh.resumen_cargadores_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_fraw text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_dia  date := case when v_fraw is not null and left(v_fraw,10) ~ '^\d{4}-\d{2}-\d{2}$'
                      then left(v_fraw,10)::date else (now() at time zone 'America/Lima')::date end;
  v_cargs jsonb;
  v_total int;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with activos as (
    select id_cargador, max(nombre) filter (where coalesce(nombre,'') <> '') as nombre, count(*)::int as cnt
      from wh.cargadores_log
     where upper(coalesce(estado,'')) = 'ACTIVO'
       and (fecha at time zone 'America/Lima')::date = v_dia
     group by id_cargador
  )
  select coalesce(jsonb_agg(jsonb_build_object('idCargador', id_cargador, 'nombre', coalesce(nombre,''), 'count', cnt)
                            order by cnt desc, id_cargador), '[]'::jsonb),
         coalesce(sum(cnt),0)::int
    into v_cargs, v_total from activos;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'fecha', to_char(v_dia,'YYYY-MM-DD'), 'total', v_total, 'cargadores', v_cargs));
end;
$fn$;

revoke all on function wh.resumen_cargadores_dia(jsonb) from public;
grant execute on function wh.resumen_cargadores_dia(jsonb) to authenticated;
