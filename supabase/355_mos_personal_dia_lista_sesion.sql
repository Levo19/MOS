-- 355: [FIX tracking personal-del-dia] personal_dia_lista expone campos de sesion de mos.liquidaciones_dia
-- (ultimaConexion/horaIngreso/estadoSesion/minutosActivos/reconexiones/horaSalida/zonaSesion/deviceId).
CREATE OR REPLACE FUNCTION mos.personal_dia_lista(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
                                       round(coalesce(d.pago_envasado, 0) / coalesce(nullif(d.tarifa_envasado, 0), 0.1))),
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
    where (d.fecha at time zone 'America/Lima')::date = v_fecha::date
  ) s;

  return jsonb_build_object('ok', true, 'data', v_arr, 'fast', true, 'fecha', v_fecha) || v_fr;
end;
$function$
