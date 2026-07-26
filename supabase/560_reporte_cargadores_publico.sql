-- ════════════════════════════════════════════════════════════════════
-- 560 — Reporte PÚBLICO de cargadores del día (para el link de WhatsApp a la jefa).
-- Página cargadores.html lo consume con la anon key (sin sesión), refresca cada 60s
-- y muestra termómetro + fotos. Baja sensibilidad (nombre + nivel + fotos públicas).
-- Mismo patrón que public.radio_productos (GET público del radio SmartTV).
-- ════════════════════════════════════════════════════════════════════

create or replace function public.reporte_cargadores_dia(p_fecha text default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_dia date := wh._carg_dia(p_fecha);
  v_cargs jsonb; v_total int; v_avg numeric;
begin
  with activos as (
    select id_cargador,
           max(nombre) filter (where coalesce(nombre,'') <> '') as nombre,
           (array_agg(nivel order by ts desc nulls last, id_log desc))[1] as nivel,
           (array_agg(coalesce(fotos,'[]'::jsonb) order by ts desc nulls last, id_log desc))[1] as fotos,
           max(ts) as ts
      from wh.cargadores_log
     where upper(coalesce(estado,'')) = 'ACTIVO'
       and (fecha at time zone 'America/Lima')::date = v_dia
     group by id_cargador
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', coalesce(nullif(btrim(nombre),''), id_cargador),
           'nivel', coalesce(nivel,0),
           'fotos', coalesce(fotos,'[]'::jsonb))
           order by nivel desc, nombre), '[]'::jsonb),
         coalesce(count(*),0)::int,
         coalesce(round(avg(coalesce(nivel,0))),0)
    into v_cargs, v_total, v_avg
    from activos;
  return jsonb_build_object('ok', true,
    'fecha', to_char(v_dia,'YYYY-MM-DD'),
    'total', v_total,
    'promedio', v_avg,
    'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
    'cargadores', v_cargs);
end; $function$;

grant execute on function public.reporte_cargadores_dia(text) to anon, authenticated, service_role;

-- ── Datos del ticket ESC/POS del día (cargadores_log) — para recablear imprimirCargadoresDia. ──
create or replace function wh.cargadores_ticket_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v_dia date := wh._carg_dia(p->>'fecha'); v jsonb; v_total int; v_prom numeric;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with activos as (
    select id_cargador, max(nombre) filter (where coalesce(nombre,'')<>'') nombre,
           (array_agg(nivel order by ts desc nulls last, id_log desc))[1] nivel,
           jsonb_array_length((array_agg(coalesce(fotos,'[]'::jsonb) order by ts desc nulls last, id_log desc))[1]) nfotos
      from wh.cargadores_log
     where upper(coalesce(estado,''))='ACTIVO' and (fecha at time zone 'America/Lima')::date=v_dia
     group by id_cargador)
  select coalesce(jsonb_agg(jsonb_build_object('nombre',coalesce(nullif(btrim(nombre),''),id_cargador),
           'nivel',coalesce(nivel,0),'fotos',coalesce(nfotos,0)) order by nivel desc, nombre),'[]'::jsonb),
         coalesce(count(*),0)::int, coalesce(round(avg(coalesce(nivel,0))),0)
    into v, v_total, v_prom from activos;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'fecha',to_char(v_dia,'YYYY-MM-DD'),'total',v_total,'promedio',v_prom,'cargadores',v));
end; $function$;

grant execute on function wh.cargadores_ticket_dia(jsonb) to anon, authenticated, service_role;
