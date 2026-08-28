-- [977] #5 · Push de considerados a mosExpress FOCALIZADO POR ZONA. Antes se mandaba UN push a apps:['mosExpress']
--  (TODOS los vendedores) con la lista GLOBAL (mezclaba zona1+zona2) → el vendedor de una zona veía productos
--  de otra. Ahora: por cada zona con considerados, se arma SU lista y se envía SOLO a los usuarios presentes en
--  esa zona (me.presencia). push_tokens_para acepta `usuarios`. Admin y WH siguen recibiendo el global (ellos
--  despachan a todas). NO cambia stock ni nada de dinero.
create or replace function mos.cron_considerados_avisar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_dry boolean := coalesce((p->>'dry')::boolean, false);
  v_nombres text[]; v_n int; v_nwin int; v_win int; v_slice text[]; v_cuerpo text;
  v_z text; v_znames text[]; v_zn int; v_zusers text[]; v_zcuerpo text; v_zenv int := 0;
begin
  perform wh.considerados_reconciliar();   -- estados frescos (atendido/imposible)

  with cm as (
    select c.id, coalesce(nullif(btrim(c.nombre),''), c.sku_base) nombre,
           coalesce((select sum((zz->>'pend')::numeric) from jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz),0) deuda,
           wh._alm_stock_sku(c.sku_base) stock,
           greatest(0, extract(epoch from (now()-c.creado))/86400.0) dias
      from wh.considerados c where c.estado='ACTIVO'
  ), mx as (select greatest(max(deuda),1) d, greatest(max(stock),1) s, greatest(max(dias),1) di from cm)
  select array_agg(upper(nombre) order by (deuda/mx.d + stock/mx.s + dias/mx.di) desc, nombre), count(*)
    into v_nombres, v_n
    from cm cross join mx;

  if coalesce(v_n,0) = 0 then return jsonb_build_object('ok', true, 'enviado', false); end if;

  v_nwin := greatest(1, ceil(least(v_n, 24) / 3.0)::int);
  v_win  := (extract(doy from (now() at time zone 'America/Lima'))::int * 2
             + case when extract(hour from (now() at time zone 'America/Lima')) >= 18 then 1 else 0 end) % v_nwin;
  v_slice := v_nombres[v_win*3 + 1 : v_win*3 + 3];
  v_cuerpo := array_to_string(v_slice, ', ') || case when v_n > 3 then '… y ' || (v_n - 3) || ' más' else '' end;

  if v_dry then
    -- en dry devolvemos también el desglose por zona (para verificar la focalización sin enviar)
    return jsonb_build_object('ok', true, 'dry', true, 'total', v_n, 'ventana', v_win, 'ventanas', v_nwin, 'cuerpo', v_cuerpo,
      'top', to_jsonb(v_nombres[1:6]),
      'porZona', (select jsonb_agg(jsonb_build_object('zona', g.z, 'items', g.cnt,
          'presentes', (select count(distinct upper(btrim(pr.nombre))) from me.presencia pr
                          where upper(btrim(pr.zona)) = g.z and pr.last_seen > now()-interval '18 hours')))
        from (
          select upper(btrim(zz->>'zona')) z, count(*) cnt
            from wh.considerados c, lateral jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz
           where c.estado='ACTIVO' and coalesce((zz->>'pend')::numeric,0)>0
           group by 1) g));
  end if;

  -- Admins (global, verifican todo).
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN','ASCENDIDO')),
    'titulo', '📦 Considerados por despachar',
    'cuerpo', v_n || ' pendientes (por prioridad): ' || v_cuerpo || ' — verifica que se envíen.',
    'data', jsonb_build_object('tipo','considerados')));

  -- Almaceneros WH (global, despachan a todas las zonas).
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('apps', jsonb_build_array('warehouseMos')),
    'titulo', '🚚 Considera enviar (prioridad)',
    'cuerpo', 'Despacha por prioridad: ' || v_cuerpo || '.',
    'data', jsonb_build_object('tipo','considerados')));

  -- ME · FOCALIZADO: por cada zona con considerados, su lista → SOLO a los presentes en esa zona.
  for v_z in
    select distinct upper(btrim(zz->>'zona')) z
      from wh.considerados c, lateral jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz
     where c.estado='ACTIVO' and coalesce((zz->>'pend')::numeric,0) > 0 and nullif(btrim(zz->>'zona'),'') is not null
  loop
    with cmz as (
      select coalesce(nullif(btrim(c.nombre),''), c.sku_base) nombre,
             coalesce((zz->>'pend')::numeric,0) deuda,
             wh._alm_stock_sku(c.sku_base) stock,
             greatest(0, extract(epoch from (now()-c.creado))/86400.0) dias
        from wh.considerados c, lateral jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz
       where c.estado='ACTIVO' and upper(btrim(zz->>'zona'))=v_z and coalesce((zz->>'pend')::numeric,0) > 0
    ), mxz as (select greatest(max(deuda),1) d, greatest(max(stock),1) s, greatest(max(dias),1) di from cmz)
    select array_agg(upper(nombre) order by (deuda/mxz.d + stock/mxz.s + dias/mxz.di) desc, nombre), count(*)
      into v_znames, v_zn from cmz cross join mxz;
    if coalesce(v_zn,0) = 0 then continue; end if;

    -- vendedores/cajeros PRESENTES en esa zona (vistos en las últimas 18h).
    select array_agg(distinct upper(btrim(nombre))) into v_zusers
      from me.presencia
     where upper(btrim(zona)) = v_z and nullif(btrim(nombre),'') is not null and last_seen > now() - interval '18 hours';
    if v_zusers is null or coalesce(array_length(v_zusers,1),0) = 0 then continue; end if;

    v_zcuerpo := array_to_string((v_znames)[1:3], ', ') || case when v_zn > 3 then '… y ' || (v_zn - 3) || ' más' else '' end;
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('usuarios', to_jsonb(v_zusers)),
      'titulo', '🎁 Llegó lo que faltaba en tu zona',
      'cuerpo', 'Para ' || v_z || ': ' || v_zcuerpo || ' (deuda de semanas pasadas).',
      'data', jsonb_build_object('tipo','considerados','zona',v_z)));
    v_zenv := v_zenv + 1;
  end loop;

  return jsonb_build_object('ok', true, 'enviado', true, 'total', v_n, 'ventana', v_win, 'cuerpo', v_cuerpo, 'zonasEnviadas', v_zenv);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

select '977 considerados push por zona listo' as ok;
