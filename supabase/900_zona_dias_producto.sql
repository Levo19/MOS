-- [900] mos.zona_dias_producto — detalle DIARIO (4 semanas ISO × 7 días) de un producto en una zona,
-- para el minigráfico "¿por qué esta cantidad?": mostrar cada día, resaltar el pico (día más fuerte)
-- de cada semana, y cuál se usa (el de la última semana). Reusa me._riz_ventas_base (misma fuente que
-- el pico/esperado del panel → 100% consistente). Devuelve los 28 días (incluidos los de venta 0).
create or replace function mos.zona_dias_producto(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_sku   text := btrim(coalesce(p->>'sku',''));
  v_lunes date := date_trunc('week', (now() at time zone 'America/Lima'))::date;   -- lunes ISO de esta semana
  v_desde date := v_lunes - 28;   -- 4 semanas ISO cerradas (igual que _riz_picos)
  v_hasta date := v_lunes - 1;
  v_arr jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_sku = '' then return jsonb_build_object('ok', false, 'error', 'falta sku'); end if;

  with base as (
    select dia, sum(unidades_base) as u
    from me._riz_ventas_base(v_desde, v_hasta)
    where sku_base = v_sku
      and (v_zona = '' or upper(btrim(zona_id)) = v_zona)
    group by dia
  ),
  dias as (
    select gd::date as d from generate_series(v_desde, v_hasta, interval '1 day') gd
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'dia', to_char(d.d, 'YYYY-MM-DD'),
      'sem', ((d.d - v_desde) / 7)::int,        -- 0..3 (0 = hace 4 sem … 3 = última)
      'dow', extract(isodow from d.d)::int,      -- 1=lun … 7=dom
      'u',   round(coalesce(b.u, 0), 2)
    ) order by d.d), '[]'::jsonb)
  into v_arr
  from dias d
  left join base b on b.dia = d.d;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'dias', v_arr, 'desde', to_char(v_desde, 'YYYY-MM-DD'), 'hasta', to_char(v_hasta, 'YYYY-MM-DD')));
end $function$;
grant execute on function mos.zona_dias_producto(jsonb) to authenticated, anon, service_role;

-- prueba con el Nescafé del ejemplo (sku LEV622) en ZONA-01
select mos.zona_dias_producto('{"zona":"ZONA-01","sku":"LEV622"}'::jsonb);
