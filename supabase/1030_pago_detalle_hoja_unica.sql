-- 1030 · pago_detalle devuelve el MISMO detalle por día que la liquidación pendiente (bonificación+motivo,
-- envasado propio/colab, unidades, auditorías) → el comprobante impreso, el que se ve en "Pagadas" y la
-- reimpresión se arman con UNA sola función del front sobre estos datos (pedido dueño 21-sep-2026).
-- Base: pg_get_functiondef vivo (ya incluye consumos/neto de 1029).
CREATE OR REPLACE FUNCTION mos.pago_detalle(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idpago text := nullif(btrim(coalesce(p->>'idPago','')), '');
  v_idpers text;
  v_head   record;
  v_dias   jsonb;
  v_total  numeric;
  v_cant   int;
  v_fr     jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_idpago is null then return jsonb_build_object('ok', false, 'error', 'Requiere idPago'); end if;
  v_fr := mos._frescura_sombra();

  -- ¿existe el pago? (paridad: si no hay filas → 'idPago no encontrado')
  if not exists (select 1 from mos.liquidaciones_pagos g where coalesce(g.id_pago,'') = v_idpago) then
    return jsonb_build_object('ok', false, 'error', 'idPago no encontrado');
  end if;

  -- cabecera = 1ª fila del pago. Orden estable por ctid para emular "rows[0]" del GAS.
  select g.id_pago, g.id_personal, g.nombre, g.rol, g.pagado_por,
         coalesce(to_char(g.pagado_ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),'') as pagado_ts,
         g.estado, g.ticket_job_id, g.id_gasto_generado, g.comentario
    into v_head
  from mos.liquidaciones_pagos g
  where coalesce(g.id_pago,'') = v_idpago
  order by g.ctid
  limit 1;

  v_idpers := coalesce(v_head.id_personal,'');

  -- motivo sanción por fecha: última eval (ctid desc) con sancion>0 para v_idpers (key idPersonal|fecha)
  with sanmot as (
    select distinct on (fdia)
      to_char((e.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD') as fdia,
      coalesce(nullif(e.sancion_motivo,''), 'sin motivo registrado')    as motivo
    from mos.evaluaciones e
    where coalesce(e.id_personal,'') = v_idpers
      and coalesce(e.sancion,0) > 0
    order by fdia, e.ctid desc
  )
  select jsonb_agg(
           jsonb_build_object(
             'fecha',             f,
             'montoBase',         monto_base,
             'pagoEnvasado',      pago_env,
             'bonoMeta',          bono_meta,
             'sancion',           sancion,
             'totalDia',          total_dia,
             'auditado',          auditado,
             'scoreFinal',        score_final,
             'evaluacionesCount', evaluaciones_count,
             'tarifaEnvasado',    tarifa,
             'unidadesEnvasadas', uds,
             'sancionMotivo',     sancion_motivo,
             -- [1030] mismo detalle que la liquidación pendiente → una sola hoja (impresa = vista = reimpresa)
             'bonificacion',       bonif,
             'bonificacionMotivo', bonif_motivo,
             'productosEnvasados', prod_env,
             'pagoEnvasadoColab',  env_colab,
             'envasadosColab',     uds_colab,
             'auditoriasHechas',   aud_h,
             'metaAuditorias',     aud_m,
             'cumplioAuditorias',  aud_ok
           ) order by ord
         ),
         round(sum(total_dia)::numeric, 2),
         count(*)::int
    into v_dias, v_total, v_cant
  from (
    select
      to_char((g.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD') as f,
      coalesce(g.monto_base, 0)                                         as monto_base,
      coalesce(g.pago_envasado, 0)                                      as pago_env,
      coalesce(g.bono_meta, 0)                                          as bono_meta,
      coalesce(g.sancion, 0)                                            as sancion,
      coalesce(g.total_dia, 0)                                          as total_dia,
      coalesce(d.auditado, false)                                       as auditado,
      coalesce(d.score_final, 0)                                        as score_final,
      coalesce(d.evaluaciones_count, 0)::int                            as evaluaciones_count,
      coalesce(d.tarifa_envasado, 0)                                    as tarifa,
      case when coalesce(d.tarifa_envasado,0) > 0
           then round((coalesce(g.pago_envasado,0) / d.tarifa_envasado))::int
           else 0 end                                                   as uds,
      coalesce(nullif(sm.motivo,''), nullif(d.sancion_motivo,''), '')   as sancion_motivo,
      coalesce(d.bonificacion, 0)                                       as bonif,
      coalesce(d.bonificacion_motivo, '')                               as bonif_motivo,
      coalesce(d.productos_envasados, 0)                                as prod_env,
      coalesce(d.pago_envasado_colab, 0)                                as env_colab,
      coalesce(d.envasados_colab, 0)                                    as uds_colab,
      coalesce(d.auditorias_hechas, 0)                                  as aud_h,
      coalesce(d.meta_auditorias, 0)                                    as aud_m,
      coalesce(d.cumplio_auditorias, false)                             as aud_ok,
      g.ctid                                                            as ord
    from mos.liquidaciones_pagos g
    -- cruce ldia por idPersonal|fecha (idPers = cabecera, NO g.id_personal — paridad L537)
    left join mos.liquidaciones_dia d
      on coalesce(d.id_personal,'') = v_idpers
     and to_char((d.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD')
       = to_char((g.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD')
    left join sanmot sm
      on sm.fdia = to_char((g.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD')
    where coalesce(g.id_pago,'') = v_idpago
  ) z;

  return jsonb_build_object(
           'ok',   true,
           'data', jsonb_build_object(
             'idPago',          coalesce(v_head.id_pago,''),
             'idPersonal',      coalesce(v_head.id_personal,''),
             'nombre',          coalesce(v_head.nombre,''),
             'rol',             coalesce(v_head.rol,''),
             'pagadoPor',       coalesce(v_head.pagado_por,''),
             'pagadoTs',        coalesce(v_head.pagado_ts,''),
             'estado',          coalesce(v_head.estado,''),
             'ticketJobId',     coalesce(v_head.ticket_job_id,''),
             'idGastoGenerado', coalesce(v_head.id_gasto_generado,''),
             'comentario',      coalesce(v_head.comentario,''),
             'ticketEscPos',    coalesce((select ticket_escpos from mos.ticket_pago_snapshot where id_pago = v_idpago),''),
             'dias',            coalesce(v_dias, '[]'::jsonb),
             'total',           coalesce(v_total, 0),
             'cantidadDias',    coalesce(v_cant, 0),
             -- [1029 R5] consumos descontados en este pago + neto
             'consumos',        coalesce((select jsonb_agg(jsonb_build_object(
                                   'correlativo', cp.correlativo, 'monto', cp.monto,
                                   'fecha', to_char(cp.fecha_venta at time zone 'America/Lima','YYYY-MM-DD'))
                                   order by cp.fecha_venta)
                                 from mos.creditos_planilla cp
                                where cp.id_pago = v_idpago and cp.estado = 'DESCONTADO'), '[]'::jsonb),
             'descuentoConsumos', coalesce((select mos._r2(sum(cp.monto)) from mos.creditos_planilla cp
                                where cp.id_pago = v_idpago and cp.estado = 'DESCONTADO'), 0),
             'neto',            mos._r2(coalesce(v_total,0) - coalesce((select sum(cp.monto) from mos.creditos_planilla cp
                                where cp.id_pago = v_idpago and cp.estado = 'DESCONTADO'), 0))
           )
         ) || v_fr;
end;
$function$
;
