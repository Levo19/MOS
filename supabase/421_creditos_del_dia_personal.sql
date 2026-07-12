-- ════════════════════════════════════════════════════════════════════════════
-- 421 · Personal del día: créditos DEL DÍA detallados (feedback del dueño)
-- ════════════════════════════════════════════════════════════════════════════
-- "Personal del día / Auditar son DEL DÍA: debe verse lo que ganó ese día Y lo
--  que consumió ese día (tickets a crédito de ESE día, detallados). El acumulado
--  no debe mezclarse en la vista diaria — ese se descuenta al liquidar."
--
-- personal_dia_lista v3 (base = versión 419 con colab/creditosPend):
--   + creditosDia: { total, n, tickets:[{idVenta, correlativo, total}] } — SOLO
--     los tickets CREDITO emitidos EL DÍA CONSULTADO con el documento del
--     empleado (máx 15 detallados; n/total siempre completos del día).
--   · creditosPend (acumulado vivo) SE MANTIENE — la card lo muestra como
--     "deuda total" y el modal de liquidación lo usa para el descuento.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function mos.personal_dia_lista(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_fecha text := coalesce(nullif(btrim(coalesce(p->>'fecha','')), ''),
                           to_char((now() at time zone 'America/Lima')::date, 'YYYY-MM-DD'));
  v_arr jsonb;
  v_fr  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();

  select coalesce(jsonb_agg(obj order by clasi, nombre_ord), '[]'::jsonb) into v_arr
  from (
    select
      case when upper(coalesce(d.rol,'')) in ('CAJERO','VENDEDOR') then 1
           when upper(coalesce(d.rol,'')) in ('ALMACENERO','ENVASADOR') then 2
           else 3 end                                   as clasi,
      coalesce(d.nombre,'')                              as nombre_ord,
      jsonb_build_object(
        'idPersonal',         coalesce(d.id_personal,''),
        'nombre',             coalesce(d.nombre,''),
        'rol',                upper(coalesce(d.rol,'')),
        'appOrigen',          coalesce(d.app_origen,''),
        'virtual',            (lower(coalesce(d.virtual,'false')) = 'true'),
        'fecha',              v_fecha,
        'presente',           true,
        'horaIngreso',        d.hora_ingreso,
        'ultimaConexion',     d.ultima_conexion,
        'horaSalida',         d.hora_salida,
        'estadoSesion',       coalesce(d.estado_sesion,''),
        'minutosActivos',     coalesce(d.minutos_activos,0)::int,
        'reconexiones',       coalesce(d.reconexiones,0)::int,
        'zonaSesion',         coalesce(d.zona,''),
        'deviceId',           coalesce(d.device_id,''),
        'auditado',           coalesce(d.auditado, false),
        'evaluacionesCount',  coalesce(d.evaluaciones_count, 0)::int,
        'scoreFinal',         coalesce(d.score_final, 0),
        'montoBase',          coalesce(d.monto_base, 0),
        'pagoEnvasado',       coalesce(d.pago_envasado, 0),
        'bonoMeta',           coalesce(d.bono_meta, 0),
        'bonificacion',       coalesce(d.bonificacion, 0),
        'sancion',            coalesce(d.sancion, 0),
        'bonificacionMotivo', coalesce(d.bonificacion_motivo, ''),
        'sancionMotivo',      coalesce(d.sancion_motivo, ''),
        'totalDia',           coalesce(d.total_dia, 0),
        'tarifaEnvasado',     coalesce(nullif(d.tarifa_envasado, 0), 0.1),
        'unidadesEnvasadas',  coalesce(nullif(d.productos_envasados, 0),
                                       case when coalesce(d.pago_envasado_colab, 0) > 0 then 0
                                            else round(coalesce(d.pago_envasado, 0) / coalesce(nullif(d.tarifa_envasado, 0), 0.1)) end),
        -- [418] 🤝 colaborativo (unidades + S/ de mitades, informativo)
        'envasadosColab',     coalesce(d.envasados_colab, 0),
        'pagoEnvasadoColab',  coalesce(d.pago_envasado_colab, 0),
        -- [419] 🧾 deuda ACUMULADA viva (referencia + descuento al liquidar)
        'creditosPend',       coalesce(cred.obj, jsonb_build_object('total',0,'n',0)),
        -- [421] 🧾 tickets a crédito DEL DÍA consultado, DETALLADOS (lo que consumió ese día)
        'creditosDia',        coalesce(cdia.obj, jsonb_build_object('total',0,'n',0,'tickets','[]'::jsonb)),
        'documento',          coalesce(per.documento,''),
        'liqEstado',          upper(coalesce(d.estado, 'PENDIENTE')),
        'vetada',             (upper(coalesce(d.estado, '')) = 'VETADA'),
        'idPago',             coalesce(d.id_pago, ''),
        -- [v2.43.384 · mega tabla = única fuente] KPIs reales desde las columnas de
        -- liquidaciones_dia (poblados por mos.recomputar_dia), NO stubs en 0. Así el
        -- modal de Auditar muestra ventas/meta/comisión/envasados consistentes (cero GAS).
        'kpis',   jsonb_build_object(
                    'ventasReales',     coalesce(d.venta_cobrada, 0),
                    'ventaZona',        coalesce(d.venta_zona, 0),
                    'ventasPct',        coalesce(d.progreso_venta_pct, 0),
                    'metaVenta',        coalesce(d.meta_zona, 0),
                    'zonaPrincipal',    coalesce(nullif(d.zona, ''), ''),
                    'auditoriasHechas', coalesce(d.auditorias_hechas, 0)::int,
                    'auditMeta',        coalesce(nullif(d.meta_auditorias, 0), 0)::int,
                    'auditPct',         case when coalesce(d.meta_auditorias, 0) > 0
                                             then round(coalesce(d.auditorias_hechas, 0)::numeric / d.meta_auditorias * 100, 1)
                                             else 0 end,
                    'envasados',        coalesce(d.productos_envasados, 0),
                    'comision',         coalesce(d.bono_meta, 0),
                    'guias', 0),
        'manual', jsonb_build_object('limpiezaPct',0,'limpiezaProfPct',0,'checksAcum',jsonb_build_object(),
                                     'checkCount',0,'checkTotal',0,'controlPct',0,'comentarios','')
      ) as obj
    from mos.liquidaciones_dia d
    left join mos.personal per on per.id_personal = d.id_personal
    left join lateral (
      select jsonb_build_object('total', round(coalesce(sum(v.total),0)::numeric,2), 'n', count(*)::int) as obj
        from me.ventas v
       where btrim(coalesce(per.documento,'')) <> ''
         and upper(v.forma_pago) = 'CREDITO'
         and btrim(coalesce(v.cliente_doc,'')) = btrim(per.documento)
    ) cred on true
    left join lateral (
      select jsonb_build_object(
               'total', round(coalesce(sum(v.total),0)::numeric,2),
               'n', count(*)::int,
               'tickets', coalesce(jsonb_agg(jsonb_build_object(
                            'idVenta', v.id_venta,
                            'correlativo', coalesce(v.correlativo,''),
                            'total', coalesce(v.total,0))
                          order by v.fecha) filter (where v.id_venta is not null), '[]'::jsonb)
             ) as obj
        from (select vv.id_venta, vv.correlativo, vv.total, vv.fecha
                from me.ventas vv
               where btrim(coalesce(per.documento,'')) <> ''
                 and upper(vv.forma_pago) = 'CREDITO'
                 and btrim(coalesce(vv.cliente_doc,'')) = btrim(per.documento)
                 and (vv.fecha at time zone 'America/Lima')::date = v_fecha::date
               order by vv.fecha limit 15) v
    ) cdia on true
    where (d.fecha at time zone 'America/Lima')::date = v_fecha::date
  ) s;

  return jsonb_build_object('ok', true, 'data', v_arr, 'fast', true, 'fecha', v_fecha) || v_fr;
end;
$function$;

revoke all on function mos.personal_dia_lista(jsonb) from public;
grant execute on function mos.personal_dia_lista(jsonb) to authenticated;

notify pgrst, 'reload schema';
