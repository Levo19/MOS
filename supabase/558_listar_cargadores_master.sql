-- ════════════════════════════════════════════════════════════════════
-- 558 — wh.listar_cargadores_master: catálogo de cargadores (proveedores con
-- prefijo "CARGADOR") DIRECTO de Supabase (cero GAS). El modal de cargadores lo
-- usa cuando el cache local de proveedores aún no está cargado (ej. abrir desde
-- el dashboard). Antes `listarCargadoresMaster` no tenía handler → caía a GAS.
-- Devuelve {ok, data:[{idCargador, nombre(sin prefijo)}]}.
-- ════════════════════════════════════════════════════════════════════

create or replace function wh.listar_cargadores_master(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v jsonb;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idCargador', id_proveedor,
           'nombre', nullif(btrim(regexp_replace(coalesce(nombre,''), '^cargador\s*', '', 'i')), '')
         ) order by nombre), '[]'::jsonb)
    into v
    from mos.proveedores
   where upper(coalesce(nombre,'')) like 'CARGADOR%'
     and coalesce(estado,'') = '1';
  return jsonb_build_object('ok', true, 'data', coalesce(v, '[]'::jsonb));
end; $function$;

grant execute on function wh.listar_cargadores_master(jsonb) to anon, authenticated, service_role;
