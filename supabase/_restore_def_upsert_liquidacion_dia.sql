create or replace function mos.upsert_liquidacion_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_rol     text := upper(coalesce(p->>'rol',''));
  v_id_dia  text;
  v_fecha   timestamptz;
  v_now     timestamptz := clock_timestamp();
  v_nowiso  text;
  v_virtual text;
  -- auto (recomputados por el cliente)
  v_base numeric := mos._numn(p->>'montoBase');
  v_env  numeric := mos._numn(p->>'pagoEnvasado');
  v_meta numeric := mos._numn(p->>'bonoMeta');
  -- existentes (preservados)
  v_exists  boolean;
  v_bon_pre numeric;
  v_san_pre numeric;
  v_bonmot_pre text;
  v_sanmot_pre text;
  v_estado_pre text;
  v_idpago_pre text;
  v_tscre_pre  timestamptz;
  -- finales
  v_bon_fin numeric;
  v_san_fin numeric;
  v_total   numeric;
  v_n int;
begin
  -- KILL-SWITCH antes del gate (paridad lote).
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_idp is null or v_fecha_s is null then
    return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos');
  end if;
  -- paridad _liqDiaUpsertRow: solo persiste presentes y NO bloqueados (admin/master no liquidan jornal)
  if coalesce((p->>'presente')::boolean, false) is not true then
    return jsonb_build_object('ok',false,'error','NO_PRESENTE','skipped',true);
  end if;
  if v_rol in ('MASTER','ADMIN','ADMINISTRADOR') then
    return jsonb_build_object('ok',false,'error','ROL_BLOQUEADO','skipped',true);
  end if;

  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
  begin v_fecha := (v_fecha_s || 'T00:00:00-05:00')::timestamptz; exception when others then v_fecha := v_now; end;  -- medianoche Lima (= _mosDate GAS)
  v_nowiso := to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_virtual := case when v_idp like 'MEX:%' then 'true' else 'false' end;

  -- Leer fila existente CON LOCK (read-then-write seguro; evita carrera con set_bonificacion/veto).
  select true, coalesce(bonificacion,0), coalesce(sancion,0),
         coalesce(bonificacion_motivo,''), coalesce(sancion_motivo,''),
         coalesce(estado,'PENDIENTE'), coalesce(id_pago,''), coalesce(ts_creado, v_now)
    into v_exists, v_bon_pre, v_san_pre, v_bonmot_pre, v_sanmot_pre, v_estado_pre, v_idpago_pre, v_tscre_pre
    from mos.liquidaciones_dia
   where id_dia = v_id_dia
   for update;

  if v_exists then
    -- PRESERVAR manual + estado/id_pago (incl. PAGADA). Solo recomponer auto + total_dia.
    v_bon_fin := v_bon_pre;
    v_san_fin := v_san_pre;
    v_total   := mos._liqdia_total(v_base, v_env, v_meta, v_bon_fin, v_san_fin);

    update mos.liquidaciones_dia set
        fecha              = v_fecha,
        nombre             = coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), nombre),
        rol                = v_rol,
        app_origen         = coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''), app_origen),
        virtual            = v_virtual,
        monto_base         = v_base,
        pago_envasado      = v_env,
        bono_meta          = v_meta,
        -- bonificacion / sancion / motivos: PRESERVADOS (re-escritos con su propio valor previo)
        bonificacion       = v_bon_fin,
        sancion            = v_san_fin,
        bonificacion_motivo= v_bonmot_pre,
        sancion_motivo     = v_sanmot_pre,
        total_dia          = v_total,
        auditado           = coalesce((p->>'auditado')::boolean, auditado),
        evaluaciones_count = coalesce(mos._numn(p->>'evaluacionesCount'), evaluaciones_count),
        score_final        = coalesce(mos._numn(p->>'scoreFinal'), score_final),
        tarifa_envasado    = coalesce(mos._numn(p->>'tarifaEnvasado'), tarifa_envasado),
        presente           = true,
        -- estado / id_pago / ts_creado: PRESERVADOS (NO se tocan) — protege PAGADA (tanda 3)
        ts_actualizado     = v_now
      where id_dia = v_id_dia;
    get diagnostics v_n = row_count;
    return jsonb_build_object('ok',true,'created',false,'data',
      jsonb_build_object('idDia',v_id_dia,'totalDia',v_total,'estado',v_estado_pre,
                         'bonificacion',v_bon_fin,'sancion',v_san_fin,'idPago',v_idpago_pre));
  end if;

  -- FILA NUEVA: bonificacion/sancion vienen del resumen (rd), estado=PENDIENTE, id_pago=''.
  v_bon_fin := coalesce(mos._numn(p->>'bonificacion'), 0);
  v_san_fin := coalesce(mos._numn(p->>'sancion'), 0);
  v_total   := mos._liqdia_total(v_base, v_env, v_meta, v_bon_fin, v_san_fin);

  insert into mos.liquidaciones_dia (
    id_dia, fecha, id_personal, nombre, rol, app_origen, virtual,
    monto_base, pago_envasado, bono_meta, bonificacion, sancion,
    bonificacion_motivo, sancion_motivo, total_dia, auditado,
    evaluaciones_count, score_final, tarifa_envasado, presente, estado, id_pago,
    ts_creado, ts_actualizado
  ) values (
    v_id_dia, v_fecha, v_idp,
    coalesce(nullif(btrim(coalesce(p->>'nombre','')),''),''),
    v_rol,
    coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''),''),
    v_virtual,
    coalesce(v_base,0), coalesce(v_env,0), coalesce(v_meta,0), v_bon_fin, v_san_fin,
    '', '', v_total,
    coalesce((p->>'auditado')::boolean, false),
    coalesce(mos._numn(p->>'evaluacionesCount'),0),
    coalesce(mos._numn(p->>'scoreFinal'),0),
    coalesce(mos._numn(p->>'tarifaEnvasado'),0),
    true, 'PENDIENTE', '',
    v_now, v_now
  )
  on conflict (id_dia) do nothing;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    -- carrera: otra tx insertó la fila entre el SELECT y el INSERT → reintentar como UPDATE preservando.
    return mos.upsert_liquidacion_dia(p);
  end if;

  return jsonb_build_object('ok',true,'created',true,'data',
    jsonb_build_object('idDia',v_id_dia,'totalDia',v_total,'estado','PENDIENTE',
                       'bonificacion',v_bon_fin,'sancion',v_san_fin,'idPago',''));
end;
$fn$;