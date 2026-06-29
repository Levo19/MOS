-- 114_mos_liquidaciones_lecturas.sql — [Lectura directa MOS · pestañas de Liquidaciones]
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- Porta a Supabase, con PARIDAD EXACTA de shape, los read-paths GAS de Liquidaciones.gs que alimentan
-- las pestañas de liquidaciones/pagos del frontend MOS. Las sombras YA están materializadas en
-- Supabase (mos.liquidaciones_dia, mos.liquidaciones_pagos, mos.evaluaciones) por Fase D + cron + sync.
--
-- Es DINERO (jornales/pagos). Cada RPC:
--   • SECURITY DEFINER · search_path='' (nombres calificados siempre)
--   • gate mos._claim_ok()  → 'APP_NO_AUTORIZADA' si la app no está autorizada
--   • `|| mos._frescura_sombra()` en el éxito → el front cae a GAS si _fresh=false (no sirve dato viejo)
--   • shape camelCase paritario · TZ America/Lima · numéricos coalesce(...,0) · redondeo 2 dec donde el GAS lo hace
--   • bools NATIVOS jsonb (true/false) porque los getters devuelven boolean JS, no '1'/'0' (ver notas)
--   • revoke from public + grant authenticated, service_role
--
-- RPCs:
--   mos.liquidaciones_pendientes(p)  → getLiquidacionesPendientes (=getLiquidacionesPendientesDia, L1109)
--   mos.liquidaciones_pagadas(p)     → getLiquidacionesPagadas / getLiquidacionesEmitidas (L429)
--   mos.liquidaciones_vetadas(p)     → getLiquidacionesVetadas (L1466)
--   mos.pago_detalle(p)              → getPagoDetalle (L504)
--   mos.liq_dia_bon_san(p)           → getLiqDiaBonSan (L1054)
--
-- NOTA bools: en GAS estos getters devuelven `true`/`false` JS reales (no strings '1'/'0'). Se portan
-- como booleanos nativos jsonb (paridad fiel). Si en el futuro el front comparara contra '1'/'0',
-- habría que castear a texto — hoy NO lo hace (compara como boolean / truthy).
-- ════════════════════════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.liquidaciones_pendientes(p) → getLiquidacionesPendientesDia (L1109)
--   Filtra LIQUIDACIONES_DIA por estado=PENDIENTE y fecha ∈ [desde,hasta]; agrupa por idPersonal.
--   Default rango: hasta=hoy(Lima), desde=hasta-29 (L1112).
--   dias[] ordenado por fecha asc; total=Σ totalDia (round 2); cantidadDias=len; filtra cantidadDias>0.
--   Orden personas: total desc, luego nombre asc.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.liquidaciones_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
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
      -- virtual: bool si el campo lo es; si no, 'true' string, o prefijo MEX: (L1140-1142)
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
      coalesce(d.tarifa_envasado, 0)                                   as tarifa_envasado,
      coalesce(d.bonificacion_motivo,'')                               as bonificacion_motivo,
      coalesce(d.sancion_motivo,'')                                    as sancion_motivo,
      coalesce(d.productos_envasados, 0)                               as productos_envasados
    from mos.liquidaciones_dia d
    where upper(coalesce(d.estado,'')) = 'PENDIENTE'
      and to_char((d.fecha at time zone 'America/Lima')::date, 'YYYY-MM-DD') between v_desde and v_hasta
  ),
  por_persona as (
    select
      id_personal,
      max(nombre)     filter (where true) as nombre,   -- 1ª aparición en GAS; aquí estable por idPersonal
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
          'tarifaEnvasado',    tarifa_envasado,
          'bonificacionMotivo', bonificacion_motivo,
          'sancionMotivo',      sancion_motivo,
          'productosEnvasados', productos_envasados
        ) order by f
      )                                                  as dias,
      round(sum(total_dia)::numeric, 2)                  as total,
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
$fn$;
revoke all on function mos.liquidaciones_pendientes(jsonb) from public;
grant execute on function mos.liquidaciones_pendientes(jsonb) to authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.liquidaciones_pagadas(p) → getLiquidacionesPagadas (L429) / getLiquidacionesEmitidas (alias)
--   Lee LIQUIDACIONES_PAGOS, oculta estado=ANULADA, filtra por fecha-de-pago (pagadoTs) ∈ [desde,hasta]
--   (L452-456). Agrupa por idPago en batches. dias[] (orden de aparición de las filas), total=Σ totalDia
--   (round 2), cantidadDias=len. Orden batches: pagadoTs desc (string compare, L492).
--   Default rango: hasta=hoy(Lima), desde=hasta-29.
--   pagadoTs/fecha como STRING crudo (el GAS hace String(r.pagadoTs)); se porta el timestamptz como texto ISO.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.liquidaciones_pagadas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
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
      coalesce(g.id_pago,'')                                            as id_pago,
      -- pagadoTs/fecha como string crudo: el GAS hace String(r.pagadoTs). El front muestra/parsea.
      coalesce(p_ord.pagado_ts_txt,'')                                  as pagado_ts,
      coalesce(g.pagado_por,'')                                         as pagado_por,
      coalesce(g.id_personal,'')                                        as id_personal,
      coalesce(g.nombre,'')                                             as nombre,
      coalesce(g.rol,'')                                                as rol,            -- NO upper (paridad L466)
      coalesce(g.ticket_job_id,'')                                      as ticket_job_id,
      coalesce(g.id_gasto_generado,'')                                  as id_gasto_generado,
      coalesce(g.comentario,'')                                         as comentario,
      to_char((g.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD') as f,
      coalesce(g.monto_base, 0)                                         as monto_base,
      coalesce(g.pago_envasado, 0)                                      as pago_envasado,
      coalesce(g.bono_meta, 0)                                          as bono_meta,
      coalesce(g.sancion, 0)                                            as sancion,
      coalesce(g.total_dia, 0)                                          as total_dia,
      g.ctid                                                            as ord
    from mos.liquidaciones_pagos g
    cross join lateral (
      -- pagadoTs como texto ISO (paridad con String(r.pagadoTs)) + fecha-de-pago para filtrar
      select
        coalesce(to_char(g.pagado_ts at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI:SS'), '') as pagado_ts_txt,
        to_char((g.pagado_ts at time zone 'America/Lima')::date, 'YYYY-MM-DD')                    as fecha_pago
    ) p_ord
    where upper(coalesce(g.estado,'')) <> 'ANULADA'
      and p_ord.fecha_pago between v_desde and v_hasta
      and coalesce(g.id_pago,'') <> ''
  ),
  por_batch as (
    select
      id_pago,
      max(pagado_ts)         as pagado_ts,
      max(pagado_por)        as pagado_por,
      max(id_personal)       as id_personal,
      max(nombre)            as nombre,
      max(rol)               as rol,
      max(ticket_job_id)     as ticket_job_id,
      max(id_gasto_generado) as id_gasto_generado,
      max(comentario)        as comentario,
      jsonb_agg(
        jsonb_build_object(
          'fecha',        f,
          'montoBase',    monto_base,
          'pagoEnvasado', pago_envasado,
          'bonoMeta',     bono_meta,
          'sancion',      sancion,
          'totalDia',     total_dia
        ) order by ord
      )                                       as dias,
      round(sum(total_dia)::numeric, 2)       as total,
      count(*)::int                           as cantidad_dias
    from filtrado
    group by id_pago
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idPago',          id_pago,
             'pagadoTs',        pagado_ts,
             'pagadoPor',       pagado_por,
             'idPersonal',      id_personal,
             'nombre',          nombre,
             'rol',             rol,
             'dias',            dias,
             'total',           total,
             'ticketJobId',     ticket_job_id,
             'idGastoGenerado', id_gasto_generado,
             'comentario',      comentario,
             'cantidadDias',    cantidad_dias
           )
           order by pagado_ts desc
         ), '[]'::jsonb)
    into v_arr
  from por_batch;

  return jsonb_build_object(
           'ok',    true,
           'data',  v_arr,
           'rango', jsonb_build_object('desde', v_desde, 'hasta', v_hasta)
         ) || v_fr;
end;
$fn$;
revoke all on function mos.liquidaciones_pagadas(jsonb) from public;
grant execute on function mos.liquidaciones_pagadas(jsonb) to authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.liquidaciones_vetadas(p) → getLiquidacionesVetadas (L1466)
--   LIQUIDACIONES_DIA estado=VETADA, fecha ∈ [desde,hasta]; lista plana (no agrupa).
--   Orden: fecha desc, luego nombre asc (L1496-1499). Default rango: hasta=hoy(Lima), desde=hasta-29.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.liquidaciones_vetadas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
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

  select coalesce(jsonb_agg(obj order by f desc, nombre_ord asc), '[]'::jsonb)
    into v_arr
  from (
    select
      to_char((d.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD') as f,
      coalesce(d.nombre,'')                                            as nombre_ord,
      jsonb_build_object(
        'idPersonal',     coalesce(d.id_personal,''),
        'nombre',         coalesce(d.nombre,''),
        'rol',            upper(coalesce(d.rol,'')),
        'appOrigen',      coalesce(d.app_origen,''),
        'fecha',          to_char((d.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD'),
        'montoBase',      coalesce(d.monto_base, 0),
        'pagoEnvasado',   coalesce(d.pago_envasado, 0),
        'totalDia',       coalesce(d.total_dia, 0),
        -- ts_actualizado como string crudo (paridad con String(r.ts_actualizado))
        'ts_actualizado', coalesce(to_char(d.ts_actualizado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'), '')
      ) as obj
    from mos.liquidaciones_dia d
    where upper(coalesce(d.estado,'')) = 'VETADA'
      and to_char((d.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD') between v_desde and v_hasta
  ) s;

  return jsonb_build_object(
           'ok',    true,
           'data',  v_arr,
           'rango', jsonb_build_object('desde', v_desde, 'hasta', v_hasta)
         ) || v_fr;
end;
$fn$;
revoke all on function mos.liquidaciones_vetadas(jsonb) from public;
grant execute on function mos.liquidaciones_vetadas(jsonb) to authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.pago_detalle(p) → getPagoDetalle (L504)
--   Detalle de UN batch: todas las filas LIQUIDACIONES_PAGOS con idPago = p.idPago.
--   Enriquece cada día con LIQUIDACIONES_DIA (auditado, scoreFinal, evaluacionesCount, tarifaEnvasado)
--   y con EVALUACIONES (sancionMotivo = última eval con sancion>0 para idPersonal|fecha).
--   unidadesEnvasadas = round(pagoEnvasado / tarifaEnvasado) si tarifa>0, else 0 (L540-541).
--   Errores GAS: sin idPago → {ok:false,'Requiere idPago'}; idPago inexistente → {ok:false,'idPago no encontrado'}.
--   La key de cruce es idPersonal|fecha; idPers = idPersonal de la 1ª fila del pago (L534).
--   total=Σ totalDia (round 2). dias[] en orden de aparición de las filas del pago.
--   OJO: NO filtra por estado=ANULADA (a diferencia de pagadas) — devuelve el batch tal cual exista.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.pago_detalle(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
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
             'sancionMotivo',     sancion_motivo
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
      coalesce(sm.motivo, '')                                           as sancion_motivo,
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
             'dias',            coalesce(v_dias, '[]'::jsonb),
             'total',           coalesce(v_total, 0),
             'cantidadDias',    coalesce(v_cant, 0)
           )
         ) || v_fr;
end;
$fn$;
revoke all on function mos.pago_detalle(jsonb) from public;
grant execute on function mos.pago_detalle(jsonb) to authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.liq_dia_bon_san(p) → getLiqDiaBonSan (L1054)
--   Lee LA fila de LIQUIDACIONES_DIA por idDia = LDIA-<fechaCompacta>-<idCleanidPersonal> (_liqDiaKey, L870).
--   Devuelve bonificacion/sancion/motivos + existe:bool. Si no existe → ceros + existe:false (L1078).
--   Errores GAS: falta idPersonal o fecha → {ok:false,'idPersonal+fecha requeridos'}.
--   fechaCompacta = fecha sin guiones; idClean = idPersonal con [^a-zA-Z0-9:] → '_'.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.liq_dia_bon_san(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_idpers text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha  text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_iddia  text;
  v_row    record;
  v_fr     jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_idpers is null or v_fecha is null then
    return jsonb_build_object('ok', false, 'error', 'idPersonal+fecha requeridos');
  end if;
  v_fr := mos._frescura_sombra();

  -- _liqDiaKey: 'LDIA-' + fecha.replace(/-/g,'') + '-' + idPersonal.replace(/[^a-zA-Z0-9:]/g,'_')
  v_iddia := 'LDIA-' || replace(v_fecha, '-', '') || '-'
                     || regexp_replace(v_idpers, '[^a-zA-Z0-9:]', '_', 'g');

  select coalesce(d.bonificacion, 0)        as bonificacion,
         coalesce(d.sancion, 0)             as sancion,
         coalesce(d.bonificacion_motivo,'') as bonificacion_motivo,
         coalesce(d.sancion_motivo,'')      as sancion_motivo
    into v_row
  from mos.liquidaciones_dia d
  where d.id_dia = v_iddia
  limit 1;

  if not found then
    return jsonb_build_object(
             'ok', true,
             'data', jsonb_build_object(
               'bonificacion', 0, 'sancion', 0,
               'bonificacionMotivo', '', 'sancionMotivo', '', 'existe', false
             )
           ) || v_fr;
  end if;

  return jsonb_build_object(
           'ok', true,
           'data', jsonb_build_object(
             'bonificacion',       v_row.bonificacion,
             'sancion',            v_row.sancion,
             'bonificacionMotivo', v_row.bonificacion_motivo,
             'sancionMotivo',      v_row.sancion_motivo,
             'existe',             true
           )
         ) || v_fr;
end;
$fn$;
revoke all on function mos.liq_dia_bon_san(jsonb) from public;
grant execute on function mos.liq_dia_bon_san(jsonb) to authenticated, service_role;
