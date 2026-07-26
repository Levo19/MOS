-- ════════════════════════════════════════════════════════════════════
-- 564 — wh.conteo_cargas_por_dia: mapa {fecha 'YYYY-MM-DD' → nº de cargas ACTIVAS}
-- de los últimos 120 días. Lo usan los acumuladores por día de Guías y Preingresos
-- para pintar el chip 🛺 (moto punteada cuando 0, con conteo cuando hay). Cero GAS.
-- ════════════════════════════════════════════════════════════════════

create or replace function wh.conteo_cargas_por_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v jsonb;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_object_agg(dia, n), '{}'::jsonb) into v
  from (
    select to_char((fecha at time zone 'America/Lima')::date,'YYYY-MM-DD') as dia, count(*)::int as n
      from wh.cargadores_log
     where upper(coalesce(estado,'')) = 'ACTIVO'
       and (fecha at time zone 'America/Lima')::date >= ((now() at time zone 'America/Lima')::date - 120)
     group by 1
  ) q;
  return jsonb_build_object('ok', true, 'data', coalesce(v, '{}'::jsonb));
end; $function$;

grant execute on function wh.conteo_cargas_por_dia(jsonb) to anon, authenticated, service_role;
