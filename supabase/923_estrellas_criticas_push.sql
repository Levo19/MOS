-- [923] Push proactivo de ESTRELLAS CRÍTICAS (pedido del dueño, #9-A).
-- "En Zona 1 faltará Comino 1kg, considera cargar." Un producto ESTRELLA (lo que MÁS mueve la zona)
-- que está por agotarse EN LA ZONA y que SÍ hay en almacén (accionable = se puede cargar) debe avisar
-- a admins/ascendidos por MOS. Mismo emisor que precios (mos.emitir_push) + dedup por (zona,sku,día)
-- para NO spamear. Estrella agotada pero SIN stock en almacén = problema de compra (otro carril, fuera).
--
-- CRÍTICO = bcg ESTRELLA (me.zona_esperado, refrescado por riz-recompute-diario) · esperado>=2 ·
--           stock efectivo en zona <= 20% de la meta (negativo por código = 0, regla I-01) ·
--           stock de almacén (wh.stock) > 0 (hay qué cargar).

-- 1) Bitácora de dedup: un aviso por estrella/zona/día.
create table if not exists mos.notif_estrella_log (
  zona_id  text not null,
  sku_base text not null,
  dia      date not null,
  ts       timestamptz not null default now(),
  primary key (zona_id, sku_base, dia)
);
grant select, insert on mos.notif_estrella_log to service_role;

-- 2) El cron.
create or replace function mos.cron_avisar_estrellas_criticas()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_dia   date := (now() at time zone 'America/Lima')::date;
  v_sent  int  := 0;
  v_zonas int  := 0;
  rec     record;
  v_cuerpo text;
  v_zlbl   text;
begin
  -- Nombre canónico legible por sku (factor=1 activo, sin codigoProductoBase preferido).
  create temp table _crit on commit drop as
  with eff as (   -- stock efectivo por (zona, sku): suma de POSITIVOS por código (I-01)
    select coalesce(pr.sku_base, eq.sku_base) as sku_base,
           sz.zona_id,
           sum(greatest(0, coalesce(sz.cantidad,0))) as eff
      from me.stock_zonas sz
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(sz.cod_barras,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(sz.cod_barras,''))
     where coalesce(pr.sku_base, eq.sku_base) is not null
     group by 1, 2
  ),
  alm as (        -- stock de almacén por sku (hay qué cargar)
    select coalesce(pr.sku_base, eq.sku_base) as sku_base,
           sum(greatest(0, coalesce(s.cantidad_disponible,0))) as alm
      from wh.stock s
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
     where coalesce(pr.sku_base, eq.sku_base) is not null
     group by 1
  ),
  nom as (        -- nombre canónico por sku
    select upper(btrim(sku_base)) as k,
           (array_agg(descripcion order by (case when codigo_producto_base is null then 0 else 1 end),
                                            length(coalesce(descripcion,'')) desc))[1] as nombre
      from mos.productos
     where coalesce(factor_conversion,1) = 1
       and coalesce(estado, true) = true
       and nullif(btrim(coalesce(descripcion,'')),'') is not null
       and nullif(btrim(coalesce(sku_base,'')),'') is not null
     group by 1
  )
  select ze.zona_id,
         ze.sku_base,
         coalesce(nom.nombre, ze.sku_base) as nombre,
         coalesce(e.eff, 0) as eff,
         ze.esperado
    from me.zona_esperado ze
    left join eff e   on e.zona_id = ze.zona_id and e.sku_base = ze.sku_base
    left join alm a   on a.sku_base = ze.sku_base
    left join nom     on nom.k = upper(btrim(ze.sku_base))
   where upper(coalesce(ze.bcg,'')) = 'ESTRELLA'
     and upper(coalesce(ze.zona_id,'')) not like '%ALMAC%'   -- solo zonas retail
     and coalesce(ze.esperado,0) >= 2
     and coalesce(e.eff,0) <= coalesce(ze.esperado,0) * 0.20  -- por agotarse
     and coalesce(a.alm,0) > 0;                               -- hay qué cargar (accionable)

  -- Solo lo NUEVO de hoy (no re-avisado).
  create temp table _new on commit drop as
    select c.* from _crit c
     where not exists (select 1 from mos.notif_estrella_log l
                        where l.zona_id = c.zona_id and l.sku_base = c.sku_base and l.dia = v_dia);

  if not exists (select 1 from _new) then
    return jsonb_build_object('ok', true, 'enviado', false, 'nuevos', 0);
  end if;

  insert into mos.notif_estrella_log(zona_id, sku_base, dia)
    select zona_id, sku_base, v_dia from _new
    on conflict (zona_id, sku_base, dia) do nothing;

  -- Un push AGRUPADO por zona (texto estilo precios: "A, B, C… y N más").
  for rec in
    select zona_id,
           count(*)::int as n,
           (array_agg(nombre order by (esperado - eff) desc, nombre))[1:3] as top3
      from _new
     group by zona_id
     order by count(*) desc
  loop
    v_zlbl := replace(replace(upper(rec.zona_id), 'ZONA-', ''), 'ZONA', '');
    v_zlbl := case when v_zlbl ~ '^[0-9]+$' then 'Zona ' || ltrim(v_zlbl, '0') else rec.zona_id end;
    if v_zlbl = 'Zona ' then v_zlbl := rec.zona_id; end if;
    v_cuerpo := array_to_string(rec.top3, ', ')
      || case when rec.n > 3 then '… y ' || (rec.n - 3) || ' más' else '' end
      || ' — considera cargar';
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
      'titulo', '⭐ ' || v_zlbl || ': estrellas por agotarse',
      'cuerpo', v_cuerpo,
      'data', jsonb_build_object('tipo','riz_estrella','zona', rec.zona_id)));
    v_sent  := v_sent + rec.n;
    v_zonas := v_zonas + 1;
  end loop;

  return jsonb_build_object('ok', true, 'enviado', true, 'zonas', v_zonas, 'estrellas', v_sent);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$function$;
grant execute on function mos.cron_avisar_estrellas_criticas() to service_role;

-- 3) Agenda: cron.job corre en UTC (ver me-cierre-cajas-11pm = '1 4 * * *' = 23:00 Lima). Lima 10/13/16/19h
--    → UTC 15/18/21/0. Escalonado en :20 para no chocar con otros crones.
select cron.schedule('mos-estrellas-criticas', '20 15,18,21,0 * * *',
                     'select mos.cron_avisar_estrellas_criticas();');
