-- [943] Estrellas por agotarse → push RECURRENTE (como Considerados). El dueño: "no veo ninguno".
-- Causa: el 935 dedupeaba por (zona,sku,DÍA) → solo avisaba las estrellas NUEVAS de ese día; disparaba
-- una vez y si te lo perdiste, nada más el resto del día. Ahora es como cron_considerados_avisar: cada
-- corrida re-avisa TODAS las estrellas que SIGUEN críticas (recurrente), agregadas en 1 push por audiencia.
-- Se cae solo lo que ya se despachó/repuso (deja de ser crítico) → no aglomera. Mensajes por nivel más
-- claros: WH operador = acción "cargá/despachá" (es su chamba) · Admin = supervisión "verificá" · ME = su pickup.
-- Mantiene notif_estrella_log SOLO como bitácora (ya no gatea). Misma detección/umbral que 935/936.
create or replace function mos.cron_avisar_estrellas_criticas()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_dia   date := (now() at time zone 'America/Lima')::date;
  v_sent  int  := 0;
  v_zonas int  := 0;
  rec     record;
  v_zlbl   text;
  v_resumen text := '';
begin
  create temp table _crit on commit drop as
  with eff as (
    select coalesce(pr.sku_base, eq.sku_base) as sku_base, sz.zona_id,
           sum(greatest(0, coalesce(sz.cantidad,0))) as eff
      from me.stock_zonas sz
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(sz.cod_barras,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(sz.cod_barras,''))
     where coalesce(pr.sku_base, eq.sku_base) is not null group by 1, 2
  ),
  alm as (
    select coalesce(pr.sku_base, eq.sku_base) as sku_base, sum(greatest(0, coalesce(s.cantidad_disponible,0))) as alm
      from wh.stock s
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
     where coalesce(pr.sku_base, eq.sku_base) is not null group by 1
  ),
  nom as (
    select upper(btrim(sku_base)) as k,
           (array_agg(descripcion order by (case when codigo_producto_base is null then 0 else 1 end), length(coalesce(descripcion,'')) desc))[1] as nombre
      from mos.productos
     where coalesce(factor_conversion,1) = 1 and coalesce(estado, true) = true
       and nullif(btrim(coalesce(descripcion,'')),'') is not null and nullif(btrim(coalesce(sku_base,'')),'') is not null
     group by 1
  )
  select ze.zona_id, ze.sku_base, coalesce(nom.nombre, ze.sku_base) as nombre, coalesce(e.eff, 0) as eff, ze.esperado
    from me.zona_esperado ze
    left join eff e on e.zona_id = ze.zona_id and e.sku_base = ze.sku_base
    left join alm a on a.sku_base = ze.sku_base
    left join nom on nom.k = upper(btrim(ze.sku_base))
   where upper(coalesce(ze.bcg,'')) = 'ESTRELLA'
     and upper(coalesce(ze.zona_id,'')) not like '%ALMAC%'
     and coalesce(ze.esperado,0) >= 2
     and coalesce(e.eff,0) <= coalesce(ze.esperado,0) * 0.20
     and coalesce(a.alm,0) > 0;

  -- ¿hay estrellas críticas AHORA? (recurrente: no importa si ya se avisó hoy)
  if not exists (select 1 from _crit) then return jsonb_build_object('ok', true, 'enviado', false, 'criticas', 0); end if;

  -- bitácora (informativa; ya NO gatea el envío)
  insert into mos.notif_estrella_log(zona_id, sku_base, dia)
    select zona_id, sku_base, v_dia from _crit on conflict (zona_id, sku_base, dia) do nothing;

  -- resumen agregado por zona → 1 push por audiencia (no N)
  for rec in
    select zona_id, count(*)::int as n, (array_agg(nombre order by (esperado - eff) desc, nombre))[1:3] as top3
      from _crit group by zona_id order by count(*) desc
  loop
    v_zlbl := replace(replace(upper(rec.zona_id), 'ZONA-', ''), 'ZONA', '');
    v_zlbl := case when v_zlbl ~ '^[0-9]+$' then 'Zona ' || ltrim(v_zlbl, '0') else rec.zona_id end;
    if v_zlbl = 'Zona ' then v_zlbl := rec.zona_id; end if;
    v_resumen := v_resumen || case when v_resumen = '' then '' else ' · ' end
              || v_zlbl || ': ' || array_to_string(rec.top3, ', ')
              || case when rec.n > 3 then '… +' || (rec.n - 3) else '' end;
    v_sent  := v_sent + rec.n;
    v_zonas := v_zonas + 1;
  end loop;

  -- WH operador (el que despacha): acción directa.
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('apps', jsonb_build_array('warehouseMos')),
    'titulo', '⭐ Cargá estas estrellas (por agotarse)',
    'cuerpo', v_resumen || ' — hay stock en almacén, despachá a la zona.',
    'data', jsonb_build_object('tipo','riz_estrella')));

  -- Admin (MOS): supervisión.
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
    'titulo', '⭐ Estrellas por agotarse (' || v_zonas || ' zona' || case when v_zonas = 1 then '' else 's' end || ')',
    'cuerpo', v_resumen || ' — verificá que se carguen.',
    'data', jsonb_build_object('tipo','riz_estrella')));

  -- ME (por app; su zona la ve en el pickup).
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('apps', jsonb_build_array('mosExpress')),
    'titulo', '⭐ Estrellas por agotarse',
    'cuerpo', v_resumen || ' — revisá tu lista/pickup.',
    'data', jsonb_build_object('tipo','riz_estrella')));

  return jsonb_build_object('ok', true, 'enviado', true, 'zonas', v_zonas, 'estrellas', v_sent);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;
grant execute on function mos.cron_avisar_estrellas_criticas() to service_role;

select 'estrellas push recurrente listo' as ok;
