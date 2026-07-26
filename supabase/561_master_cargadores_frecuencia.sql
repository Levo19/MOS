-- ════════════════════════════════════════════════════════════════════
-- 561 — wh.listar_cargadores_master v2: agrega `veces` = frecuencia de registro
-- del cargador en los últimos 60 días (wh.cargadores_log, filas ACTIVO). El modal
-- lo usa para el "Agregar rápido" (top-3 los que MÁS TRAEN) y para ordenar el
-- buscador por relevancia. Sigue devolviendo {ok, data:[{idCargador, nombre, veces}]}.
-- Cero GAS. security definer + _claim_ok.
-- ════════════════════════════════════════════════════════════════════

create or replace function wh.listar_cargadores_master(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v jsonb;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with freq as (
    select id_cargador, count(distinct (fecha at time zone 'America/Lima')::date) as veces
      from wh.cargadores_log
     where upper(coalesce(estado,'')) = 'ACTIVO'
       and (fecha at time zone 'America/Lima')::date >= ((now() at time zone 'America/Lima')::date - 60)
     group by id_cargador
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'idCargador', pr.id_proveedor,
           'nombre', nullif(btrim(regexp_replace(coalesce(pr.nombre,''), '^cargador\s*', '', 'i')), ''),
           'veces', coalesce(f.veces, 0)
         ) order by coalesce(f.veces,0) desc, pr.nombre), '[]'::jsonb)
    into v
    from mos.proveedores pr
    left join freq f on f.id_cargador = pr.id_proveedor
   where upper(coalesce(pr.nombre,'')) like 'CARGADOR%'
     and coalesce(pr.estado,'') = '1';
  return jsonb_build_object('ok', true, 'data', coalesce(v, '[]'::jsonb));
end; $function$;

grant execute on function wh.listar_cargadores_master(jsonb) to anon, authenticated, service_role;
