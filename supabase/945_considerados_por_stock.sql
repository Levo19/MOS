-- [945] Considerados también por STOCK (no solo al ingresar). El dueño: "soda tiene 26 en el almacén,
-- se le debe a zonas de semanas atrás y nunca se despachó → debe entrar a considerados igual, aunque hoy
-- no ingrese nada". Definición del dueño: considerado = producto que INGRESA **o HAY** en almacén, que se
-- debió en las últimas 4 semanas (rezagado) y que NO está en el acumulado de ESTA semana (no es priorizado).
-- El trigger de ingreso (790) cubre el "ingresa"; esto cubre el "hay stock". Money-safe, aditivo.

create or replace function wh.considerados_barrer_stock() returns jsonb
language plpgsql security definer set search_path to '' as $function$
declare
  v_bucket date := wh._bucket_dom((now() at time zone 'America/Lima')::date);
  v_bstr text := to_char(v_bucket, 'YYYY-MM-DD');
  v_ins int := 0;
begin
  with alm as (   -- lo que HAY en el almacén, por sku (canónico + equivalentes)
    select coalesce(pr.sku_base, eq.sku_base) as sku, sum(greatest(0, coalesce(s.cantidad_disponible,0))) as alm
      from wh.stock s
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
     where coalesce(pr.sku_base, eq.sku_base) is not null
     group by 1
    having sum(greatest(0, coalesce(s.cantidad_disponible,0))) > 0
  ),
  hoy as (   -- se debe ESTA semana (acumulado vivo) → es PRIORIZADO, NO considerado
    select distinct it->>'skuBase' as sku
      from wh.pickups pk cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
     where pk.fuente = 'ACUMULADO_SEMANAL' and pk.id_pickup like 'PCK-ACU-%-' || v_bstr
       and wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')) > 0
  ),
  rez as (   -- quedó debiendo en los REZAGADOS de las últimas 4 semanas
    select coalesce(pk.id_zona,'') as zona, right(pk.id_pickup,10) as bucket, it->>'skuBase' as sku,
           wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')) as pend,
           it->>'nombre' as nombre
      from wh.pickups pk cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
     where pk.fuente = 'ACUMULADO_SEMANAL' and upper(coalesce(pk.estado,'')) = 'REZAGADO'
       and right(pk.id_pickup,10) ~ '^\d{4}-\d{2}-\d{2}$'
       and to_date(right(pk.id_pickup,10),'YYYY-MM-DD') >= v_bucket - 28
       and to_date(right(pk.id_pickup,10),'YYYY-MM-DD') <  v_bucket
       and wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')) > 0
  ),
  cand as (
    select a.sku as sku_base, max(r.nombre) as nombre, max(a.alm) as alm,
           jsonb_agg(jsonb_build_object('zona', r.zona, 'bucket', r.bucket, 'pend', r.pend) order by r.bucket desc) as zonas
      from alm a
      join rez r on r.sku = a.sku
     where not exists (select 1 from hoy h where h.sku = a.sku)                       -- no priorizado esta semana
       and a.sku not in (select sku_base from wh.considerados where estado = 'ACTIVO') -- no duplicar
     group by a.sku
  )
  insert into wh.considerados (sku_base, nombre, id_guia, guia_tipo, cod_ingreso, cant_ingresada, zonas)
  select sku_base, coalesce(nullif(btrim(nombre),''), sku_base), null, 'STOCK', null, alm, zonas
    from cand
  on conflict (sku_base) where estado = 'ACTIVO' do nothing;
  get diagnostics v_ins = row_count;
  return jsonb_build_object('ok', true, 'insertados', v_ins);
end $function$;
grant execute on function wh.considerados_barrer_stock() to authenticated, anon, service_role;

-- throttle para llamarlo perezosamente al abrir la lista (máx 1 vez cada 10 min)
create table if not exists wh.considerados_barrer_run (ultima timestamptz);
insert into wh.considerados_barrer_run select now() - interval '1 hour'
  where not exists (select 1 from wh.considerados_barrer_run);

-- cron cada 2 horas (además del trigger de ingreso y del barrido perezoso de la lista)
select cron.schedule('wh-considerados-stock', '7 */2 * * *', 'select wh.considerados_barrer_stock();')
where not exists (select 1 from cron.job where jobname = 'wh-considerados-stock');

-- corre una vez ya para poblar lo existente
select wh.considerados_barrer_stock() as barrido;
