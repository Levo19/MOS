-- ═══════════════════════════════════════════════════════════════════════════
-- 573 · liquidaciones_pendientes + envasadoColaboradores por día
-- ═══════════════════════════════════════════════════════════════════════════
-- Agrega a cada día el array 'envasadoColaboradores' (nombres con quien la persona
-- envasó en colaboración ese día, desde wh.envasados). Front: 🤝 + "compartido con X".
-- Base = def viva parcheada (lateral colab + campo + key jsonb). Sin cambios de dinero.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION mos.liquidaciones_pendientes(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_hasta text := coalesce(nullif(btrim(coalesce(p->>'hasta','')), ''),
                           to_char((now() at time zone 'America/Lima')::date, 'YYYY-MM-DD'));
  v_desde text;
  v_arr   jsonb;
  v_fr    jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  v_desde := coalesce(nullif(btrim(coalesce(p->>'desde','')), ''),
                      to_char(v_hasta::date - 29, 'YYYY-MM-DD'));
  v_fr := mos._frescura_sombra();

  with filtrado as (
    select
      coalesce(d.id_personal,'')                                       as id_personal,
      coalesce(d.nombre,'')                                            as nombre,
      upper(coalesce(d.rol,''))                                        as rol,
      coalesce(d.app_origen,'')                                        as app_origen,
      (lower(coalesce(d.virtual,'false')) = 'true'
        or coalesce(d.id_personal,'') like 'MEX:%')                    as virtual,
      to_char((d.fecha at time zone 'America/Lima')::date, 'YYYY-MM-DD') as f,
      coalesce(d.auditado, false)                                      as auditado,
      coalesce(d.monto_base, 0)                                        as monto_base,
      coalesce(d.pago_envasado, 0)                                     as pago_envasado,
      coalesce(d.bono_meta, 0)                                         as bono_meta,
      coalesce(d.bonificacion, 0)                                      as bonificacion,
      coalesce(d.sancion, 0)                                           as sancion,
      coalesce(d.total_dia, 0)                                         as total_dia,
      coalesce(d.score_final, 0)                                       as score_final,
      coalesce(d.evaluaciones_count, 0)::int                           as evaluaciones_count,
      coalesce(d.auditorias_hechas, 0)::int                            as auditorias_hechas,
      coalesce(d.meta_auditorias, 0)::int                             as meta_auditorias,
      coalesce(d.cumplio_auditorias, false)                           as cumplio_auditorias,
      coalesce(d.tarifa_envasado, 0)                                   as tarifa_envasado,
      coalesce(d.bonificacion_motivo,'')                               as bonificacion_motivo,
      coalesce(d.sancion_motivo,'')                                    as sancion_motivo,
      coalesce(d.productos_envasados, 0)                               as productos_envasados,
      coalesce(d.envasados_colab, 0)                                   as envasados_colab,
      coalesce(d.pago_envasado_colab, 0)                               as pago_envasado_colab,
      -- [422] consumo a crédito de ESE día (deuda viva de esa fecha, doc exacto)
      coalesce(cdia.total, 0)                                          as consumo_total,
      coalesce(cdia.n, 0)                                              as consumo_n,
      coalesce(colab.nombres, '{}'::text[]) as envasado_colaboradores
    from mos.liquidaciones_dia d
    left join mos.personal per on per.id_personal = d.id_personal
    left join lateral (
      select round(coalesce(sum(v.total),0)::numeric,2) as total, count(*)::int as n
        from me.ventas v
       where btrim(coalesce(per.documento,'')) <> ''
         and upper(v.forma_pago) = 'CREDITO'
         and btrim(coalesce(v.cliente_doc,'')) = btrim(per.documento)
         and (v.fecha at time zone 'America/Lima')::date = (d.fecha at time zone 'America/Lima')::date
    ) cdia on true
    left join lateral (
      select array_agg(distinct nm) as nombres from (
        select case when lower(btrim(e.usuario)) = lower(btrim(coalesce(d.nombre,''))) then e.colaborador else e.usuario end as nm
          from wh.envasados e
         where (e.fecha at time zone 'America/Lima')::date = (d.fecha at time zone 'America/Lima')::date
           and coalesce(btrim(e.colaborador),'') <> ''
           and lower(btrim(e.usuario)) <> lower(btrim(e.colaborador))
           and (lower(btrim(e.usuario)) = lower(btrim(coalesce(d.nombre,''))) or lower(btrim(e.colaborador)) = lower(btrim(coalesce(d.nombre,''))))
      ) s where coalesce(btrim(nm),'') <> ''
    ) colab on true
    where upper(coalesce(d.estado,'')) = 'PENDIENTE'
      and to_char((d.fecha at time zone 'America/Lima')::date, 'YYYY-MM-DD') between v_desde and v_hasta
  ),
  por_persona as (
    select
      id_personal,
      max(nombre)     filter (where true) as nombre,
      max(rol)        as rol,
      max(app_origen) as app_origen,
      bool_or(virtual) as virtual,
      jsonb_agg(
        jsonb_build_object(
          'fecha',             f,
          'presente',          true,
          'auditado',          auditado,
          'montoBase',         monto_base,
          'pagoEnvasado',      pago_envasado,
          'bonoMeta',          bono_meta,
          'bonificacion',      bonificacion,
          'sancion',           sancion,
          'totalDia',          total_dia,
          'scoreFinal',        score_final,
          'evaluacionesCount', evaluaciones_count,
          'auditoriasHechas',   auditorias_hechas,
          'metaAuditorias',     meta_auditorias,
          'cumplioAuditorias',  cumplio_auditorias,
          'tarifaEnvasado',    tarifa_envasado,
          'bonificacionMotivo', bonificacion_motivo,
          'sancionMotivo',      sancion_motivo,
          'productosEnvasados', productos_envasados,
          'envasadosColab',     envasados_colab,
          'pagoEnvasadoColab',  pago_envasado_colab,
          'envasadoColaboradores', to_jsonb(envasado_colaboradores),
          'consumoDia',         jsonb_build_object('total', consumo_total, 'n', consumo_n)
        ) order by f
      )                                                  as dias,
      round(sum(total_dia)::numeric, 2)                  as total,
      round(sum(consumo_total)::numeric, 2)              as consumo_total,
      count(*)::int                                      as cantidad_dias
    from filtrado
    group by id_personal
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idPersonal',   id_personal,
             'nombre',       nombre,
             'rol',          rol,
             'appOrigen',    app_origen,
             'virtual',      virtual,
             'dias',         dias,
             'total',        total,
             'consumoTotal', consumo_total,
             'cantidadDias', cantidad_dias
           )
           order by total desc, nombre asc
         ), '[]'::jsonb)
    into v_arr
  from por_persona
  where cantidad_dias > 0;

  return jsonb_build_object(
           'ok',    true,
           'data',  v_arr,
           'rango', jsonb_build_object('desde', v_desde, 'hasta', v_hasta),
           'fast',  true
         ) || v_fr;
end;
$function$;

notify pgrst, 'reload schema';
