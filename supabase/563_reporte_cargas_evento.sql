-- ════════════════════════════════════════════════════════════════════
-- 563 — Reporte público + ticket adaptados al modelo de CARGAS (log de eventos):
-- agrupado por cargador, cada carga con su hora, nivel y fotos. Reemplaza las
-- versiones "1 nivel por cargador" de SQL 560.
-- ════════════════════════════════════════════════════════════════════

-- ── Reporte PÚBLICO (anon key) para cargadores.html: cargadores con sus cargas. ──
create or replace function public.reporte_cargadores_dia(p_fecha text default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_dia date := wh._carg_dia(p_fecha);
  v_cargadores jsonb; v_tot_cargas int; v_tot_cargadores int; v_avg numeric;
begin
  with cargas as (
    select id_log as id_carga, id_cargador,
           coalesce(nivel,0) as nivel, coalesce(fotos,'[]'::jsonb) as fotos, ts,
           max(nombre) over (partition by id_cargador) as nombre
      from wh.cargadores_log
     where upper(coalesce(estado,'')) = 'ACTIVO'
       and (fecha at time zone 'America/Lima')::date = v_dia
  ),
  por_cargador as (
    select id_cargador,
           coalesce(nullif(btrim(max(nombre)),''), id_cargador) as nombre,
           max(ts) as ult_ts, count(*)::int as n_cargas,
           jsonb_agg(jsonb_build_object(
             'hora', to_char(ts at time zone 'America/Lima','HH24:MI'),
             'nivel', nivel, 'fotos', fotos) order by ts asc) as cargas
      from cargas group by id_cargador
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'nCargas', n_cargas, 'cargas', cargas)
           order by ult_ts desc nulls last, nombre), '[]'::jsonb),
         coalesce(sum(n_cargas),0)::int, coalesce(count(*),0)::int
    into v_cargadores, v_tot_cargas, v_tot_cargadores
    from por_cargador;
  select coalesce(round(avg(coalesce(nivel,0))),0) into v_avg
    from wh.cargadores_log
   where upper(coalesce(estado,''))='ACTIVO' and (fecha at time zone 'America/Lima')::date = v_dia;
  return jsonb_build_object('ok', true,
    'fecha', to_char(v_dia,'YYYY-MM-DD'),
    'totalCargas', v_tot_cargas,
    'totalCargadores', v_tot_cargadores,
    'promedio', v_avg,
    'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
    'cargadores', v_cargadores);
end; $function$;

grant execute on function public.reporte_cargadores_dia(text) to anon, authenticated, service_role;

-- ── Datos del ticket ESC/POS: cargadores con sus cargas (fotos como CONTEO). ──
create or replace function wh.cargadores_ticket_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_dia date := wh._carg_dia(p->>'fecha');
  v_cargadores jsonb; v_tot_cargas int; v_tot_cargadores int; v_prom numeric;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with cargas as (
    select id_cargador, coalesce(nivel,0) as nivel,
           jsonb_array_length(coalesce(fotos,'[]'::jsonb)) as nfotos, ts,
           max(nombre) over (partition by id_cargador) as nombre
      from wh.cargadores_log
     where upper(coalesce(estado,''))='ACTIVO' and (fecha at time zone 'America/Lima')::date = v_dia
  ),
  por_cargador as (
    select id_cargador, coalesce(nullif(btrim(max(nombre)),''), id_cargador) as nombre,
           max(ts) as ult_ts, count(*)::int as n_cargas,
           jsonb_agg(jsonb_build_object(
             'hora', to_char(ts at time zone 'America/Lima','HH24:MI'),
             'nivel', nivel, 'fotos', nfotos) order by ts asc) as cargas
      from cargas group by id_cargador
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'nCargas', n_cargas, 'cargas', cargas)
           order by ult_ts desc nulls last, nombre), '[]'::jsonb),
         coalesce(sum(n_cargas),0)::int, coalesce(count(*),0)::int
    into v_cargadores, v_tot_cargas, v_tot_cargadores from por_cargador;
  select coalesce(round(avg(coalesce(nivel,0))),0) into v_prom
    from wh.cargadores_log
   where upper(coalesce(estado,''))='ACTIVO' and (fecha at time zone 'America/Lima')::date = v_dia;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'fecha',to_char(v_dia,'YYYY-MM-DD'),
    'totalCargas',v_tot_cargas,'totalCargadores',v_tot_cargadores,
    'promedio',v_prom,'cargadores',v_cargadores));
end; $function$;

grant execute on function wh.cargadores_ticket_dia(jsonb) to anon, authenticated, service_role;
