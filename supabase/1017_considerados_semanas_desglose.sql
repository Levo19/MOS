-- ============================================================================
-- 1017_considerados_semanas_desglose.sql — Considerados: desglose por semana (04-sep)
-- ----------------------------------------------------------------------------
-- El front (WH 2.13.589) muestra en el REVERSO de cada card "cuánto se debe por semana", pero el RPC v3
-- (954) COLAPSABA las zonas por zona sumando el pend y DESCARTABA el `bucket` → el front no tenía el dato
-- semanal → mostraba "sin fecha". El dato SÍ existe: wh.considerados_barrer_stock (945) guarda cada entrada
-- de zona como {zona, bucket:'YYYY-MM-DD', pend}. Este parche redefine considerados_listar para EMITIR,
-- por zona, además del total: `semanas` = [{bucket, pend}] (una línea por semana debida, más reciente 1º).
-- Todo lo demás queda idéntico (prioridad, despacho por zona, atendidos).
-- ============================================================================

create or replace function wh.considerados_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_lim int := greatest(1, least(300, coalesce((p->>'limite')::int, 120)));
  v_pend jsonb; v_atn jsonb;
begin
  perform wh.considerados_reconciliar();   -- deja _sal/_alm listos y estados frescos (ya NO se vence a 7 días)

  drop table if exists _cm;
  create temporary table _cm on commit drop as
    select c.id, c.sku_base, c.nombre, c.cant_ingresada, c.guia_tipo, c.id_guia, c.creado, c.zonas,
           coalesce((select sum((zz->>'pend')::numeric) from jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz),0) deuda,
           coalesce((select stock from _alm a where a.sku=c.sku_base),0) stock,
           greatest(0, extract(epoch from (now()-c.creado))/86400.0) dias
      from wh.considerados c where c.estado='ACTIVO';

  with mx as (select greatest(max(deuda),1) d, greatest(max(stock),1) s, greatest(max(dias),1) di from _cm)
  select coalesce(jsonb_agg(x order by (x->>'prioridad')::numeric desc, (x->>'dias')::numeric desc), '[]'::jsonb) into v_pend
    from (
      select jsonb_build_object(
        'id', m.id, 'skuBase', m.sku_base, 'nombre', m.nombre, 'cant', m.cant_ingresada,
        'guiaTipo', m.guia_tipo, 'idGuia', m.id_guia,
        'foto', (select pr.foto_url from mos.productos pr where pr.sku_base=m.sku_base and nullif(btrim(pr.foto_url),'') is not null limit 1),
        'creado', to_char(m.creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'),
        'dias', round(m.dias::numeric,1), 'deuda', round(m.deuda,2), 'stock', round(m.stock,2),
        'prioridad', round((m.deuda/mx.d + m.stock/mx.s + m.dias/mx.di)::numeric, 3),
        -- zonas por zona: total + DESGLOSE por semana (bucket) para el reverso de la card + despacho por zona
        'zonas', (select coalesce(jsonb_agg(jsonb_build_object(
                             'zona', t.zona, 'pend', round(t.pend,2),
                             'despachado', t.dts is not null, 'despachadoTs', t.dts,
                             'semanas', t.semanas
                           ) order by t.pend desc), '[]'::jsonb)
                    from (
                      select zona, sum(pend) pend, max(dts) dts,
                             coalesce(jsonb_agg(jsonb_build_object('bucket', bucket, 'pend', round(pend,2)) order by bucket desc)
                                      filter (where bucket is not null and pend > 0), '[]'::jsonb) semanas
                        from (
                          select zz->>'zona' zona,
                                 nullif(btrim(zz->>'bucket'),'') bucket,
                                 (zz->>'pend')::numeric pend,
                                 (select to_char(max(s.ts) at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')
                                    from _sal s where s.sku=m.sku_base and s.zona=(zz->>'zona') and s.ts>=m.creado) dts
                            from jsonb_array_elements(case when jsonb_typeof(m.zonas)='array' then m.zonas else '[]'::jsonb end) zz
                        ) e
                       group by zona
                    ) t)
      ) x
      from _cm m cross join mx limit v_lim
    ) q;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'skuBase', c.sku_base, 'nombre', c.nombre,
           'atendidoTs', to_char(c.atendido_ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'),
           'zonas', (select coalesce(jsonb_agg(distinct zz->>'zona'),'[]'::jsonb) from jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz)
         ) order by c.atendido_ts desc), '[]'::jsonb)
    into v_atn from wh.considerados c where c.estado='ATENDIDO';

  return jsonb_build_object('ok', true, 'items', v_pend, 'pendientes', v_pend, 'atendidos', v_atn,
    'total', (select count(*) from wh.considerados where estado='ACTIVO'),
    'totalAtendidos', (select count(*) from wh.considerados where estado='ATENDIDO'));
end $function$;

select '1017 considerados semanas desglose listo' ok;
