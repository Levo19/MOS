-- 105_mos_personal_dia_lista.sql — [Optimización MOS · lectura directa "Personal del día"]
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- getPersonalDiaFast (Liquidaciones.gs:1204) lee la hoja LIQUIDACIONES_DIA filtrando por fecha y la
-- mapea a un shape camelCase. Esa hoja YA tiene sombra fresca en Supabase (mos.liquidaciones_dia,
-- materializada por Fase D + cron + sync). Esta RPC la lee DIRECTO con paridad EXACTA de shape, para
-- que "Personal del día" cargue instantáneo en vez de esperar a GAS.
--
-- Shape (paridad fiel con getPersonalDiaFast): { ok, data:[{idPersonal,nombre,rol,appOrigen,virtual,
--   fecha,presente,auditado,evaluacionesCount,scoreFinal,montoBase,pagoEnvasado,bonoMeta,bonificacion,
--   sancion,bonificacionMotivo,sancionMotivo,totalDia,tarifaEnvasado,unidadesEnvasadas,liqEstado,vetada,
--   idPago,kpis(stub),manual(stub)}], fast:true, fecha } + frescura (_fresh/_heartbeat).
-- Orden: cajeros/vendedores → almaceneros/envasadores → otros, luego alfabético (= _clasiRol del GAS).
-- DINERO (jornales): gate _claim_ok + frescura (el front cae a GAS si _fresh=false, no sirve dato viejo).

create or replace function mos.personal_dia_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
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
        'unidadesEnvasadas',  coalesce(d.pago_envasado, 0) / coalesce(nullif(d.tarifa_envasado, 0), 0.1),
        'liqEstado',          upper(coalesce(d.estado, 'PENDIENTE')),
        'vetada',             (upper(coalesce(d.estado, '')) = 'VETADA'),
        'idPago',             coalesce(d.id_pago, ''),
        'kpis',   jsonb_build_object('ventasReales',0,'ventasPct',0,'auditoriasHechas',0,'envasados',0,'guias',0),
        'manual', jsonb_build_object('limpiezaPct',0,'limpiezaProfPct',0,'checksAcum',jsonb_build_object(),
                                     'checkCount',0,'checkTotal',0,'controlPct',0,'comentarios','')
      ) as obj
    from mos.liquidaciones_dia d
    where (d.fecha at time zone 'America/Lima')::date = v_fecha::date
  ) s;

  return jsonb_build_object('ok', true, 'data', v_arr, 'fast', true, 'fecha', v_fecha) || v_fr;
end;
$fn$;
revoke all on function mos.personal_dia_lista(jsonb) from public;
grant execute on function mos.personal_dia_lista(jsonb) to anon, authenticated, service_role;
