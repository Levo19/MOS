-- [1000] FIX 409 en wh.considerados_listar → wh.considerados_reconciliar.
--  ux_wh_considerados_activo = UNIQUE(sku_base) WHERE estado='ACTIVO' (un solo ACTIVO por sku). El paso 3
--  (reactivar IMPOSIBLE→ACTIVO cuando vuelve el stock) NO verificaba que (a) no exista ya un ACTIVO del mismo
--  sku, ni (b) que no se reactiven DOS IMPOSIBLE del mismo sku a la vez → duplicate key (23505) → PostgREST 409
--  en CADA llamada a considerados_listar (que corre reconciliar). Reproducido: 1 sola llamada ya fallaba.
--  Fix: reactivar SOLO UNO por sku_base (row_number) y SOLO si no hay ya un ACTIVO. Pasos 1/2 no cambian
--  (ACTIVO→ATENDIDO / ACTIVO→IMPOSIBLE quitan de ACTIVO, sin riesgo de duplicado). Salida: ahora SÍ reactiva
--  (antes erroraba y no reactivaba nada).
create or replace function wh.considerados_reconciliar()
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  perform wh._cons_prep();
  drop table if exists _rc;
  create temporary table _rc on commit drop as
    select c.id, (zz->>'zona') zona,
           exists (select 1 from _sal s where s.sku = c.sku_base and s.zona = (zz->>'zona') and s.ts >= c.creado) hit
      from wh.considerados c
      cross join lateral jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz
     where c.estado in ('ACTIVO','IMPOSIBLE');

  -- 1) ATENDIDO: todas las zonas debidas ya despachadas
  update wh.considerados c set estado='ATENDIDO', atendido_ts=coalesce(atendido_ts, now()), resuelto_ts=coalesce(resuelto_ts, now())
   where c.estado='ACTIVO' and c.id in (select id from _rc group by id having bool_and(hit) and count(*) > 0);
  -- 2) IMPOSIBLE: ACTIVO sin stock en almacén
  update wh.considerados c set estado='IMPOSIBLE'
   where c.estado='ACTIVO' and coalesce((select stock from _alm a where a.sku=c.sku_base),0) <= 0;
  -- 3) reactivar: IMPOSIBLE que volvió a tener stock y aún no despachado a todo.
  --    [FIX 409] SOLO UNO por sku_base (row_number) y SOLO si no hay ya un ACTIVO del mismo sku → jamás viola
  --    ux_wh_considerados_activo (único ACTIVO por sku).
  update wh.considerados c set estado='ACTIVO'
   where c.id in (
     select id from (
       select c2.id,
              row_number() over (partition by c2.sku_base order by c2.creado, c2.id) rn
         from wh.considerados c2
        where c2.estado='IMPOSIBLE'
          and coalesce((select stock from _alm a where a.sku=c2.sku_base),0) > 0
          and c2.id not in (select id from _rc group by id having bool_and(hit) and count(*) > 0)
          and not exists (select 1 from wh.considerados a2 where a2.sku_base = c2.sku_base and a2.estado='ACTIVO')
     ) t where t.rn = 1
   );
end $function$;

select '1000 considerados_reconciliar 409 fix listo' as ok;
