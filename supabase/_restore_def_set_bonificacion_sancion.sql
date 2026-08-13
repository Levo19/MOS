create or replace function mos.set_bonificacion_sancion(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_solo    text := nullif(lower(btrim(coalesce(p->>'soloTipo',''))), '');
  v_id_dia  text;
  v_fecha   timestamptz;
  v_now     timestamptz := clock_timestamp();
  v_nowiso  text;
  v_bon_new numeric := coalesce(mos._numn(p->>'bonificacion'), 0);
  v_san_new numeric := coalesce(mos._numn(p->>'sancion'), 0);
  v_bonmot_new text := coalesce(p->>'bonificacionMotivo','');
  v_sanmot_new text := coalesce(p->>'sancionMotivo','');
  -- existentes
  v_exists  boolean;
  v_base numeric; v_env numeric; v_meta numeric;
  v_bon_pre numeric; v_san_pre numeric; v_bonmot_pre text; v_sanmot_pre text;
  -- finales
  v_bon_fin numeric; v_san_fin numeric; v_bonmot_fin text; v_sanmot_fin text;
  v_total numeric;
begin
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_idp is null or v_fecha_s is null then
    return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos');
  end if;
  if v_solo is not null and v_solo not in ('bonificacion','sancion') then
    return jsonb_build_object('ok',false,'error','soloTipo inválido');
  end if;

  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
  begin v_fecha := (v_fecha_s || 'T00:00:00-05:00')::timestamptz; exception when others then v_fecha := v_now; end;  -- medianoche Lima (= _mosDate GAS)
  v_nowiso := to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

  select true, coalesce(monto_base,0), coalesce(pago_envasado,0), coalesce(bono_meta,0),
         coalesce(bonificacion,0), coalesce(sancion,0),
         coalesce(bonificacion_motivo,''), coalesce(sancion_motivo,'')
    into v_exists, v_base, v_env, v_meta, v_bon_pre, v_san_pre, v_bonmot_pre, v_sanmot_pre
    from mos.liquidaciones_dia
   where id_dia = v_id_dia
   for update;

  -- Resolver finales según soloTipo (espeja _liqDiaSetBonSan).
  v_bon_fin := v_bon_new; v_san_fin := v_san_new;
  v_bonmot_fin := v_bonmot_new; v_sanmot_fin := v_sanmot_new;
  if v_solo = 'sancion' then
    v_bon_fin := coalesce(v_bon_pre,0); v_bonmot_fin := coalesce(v_bonmot_pre,'');
  elsif v_solo = 'bonificacion' then
    v_san_fin := coalesce(v_san_pre,0); v_sanmot_fin := coalesce(v_sanmot_pre,'');
  end if;

  if v_exists then
    v_total := mos._liqdia_total(v_base, v_env, v_meta, v_bon_fin, v_san_fin);
    update mos.liquidaciones_dia set
        bonificacion        = v_bon_fin,
        sancion             = v_san_fin,
        bonificacion_motivo = v_bonmot_fin,
        sancion_motivo      = v_sanmot_fin,
        total_dia           = v_total,
        ts_actualizado      = v_now
      where id_dia = v_id_dia;
    return jsonb_build_object('ok',true,'created',false,'data',
      jsonb_build_object('idDia',v_id_dia,'bonificacion',v_bon_fin,'sancion',v_san_fin,'totalDia',v_total));
  end if;

  -- No existe: crear fila MÍNIMA (autos en 0). soloTipo sobre fila nueva → el "otro" queda en 0.
  if v_solo = 'sancion' then v_bon_fin := 0; v_bonmot_fin := ''; end if;
  if v_solo = 'bonificacion' then v_san_fin := 0; v_sanmot_fin := ''; end if;
  v_total := mos._liqdia_total(0, 0, 0, v_bon_fin, v_san_fin);
  insert into mos.liquidaciones_dia (
    id_dia, fecha, id_personal, nombre, rol, app_origen, virtual,
    monto_base, pago_envasado, bono_meta, bonificacion, sancion,
    bonificacion_motivo, sancion_motivo, total_dia, auditado,
    evaluaciones_count, score_final, tarifa_envasado, presente, estado, id_pago,
    ts_creado, ts_actualizado
  ) values (
    v_id_dia, v_fecha, v_idp,
    coalesce(nullif(btrim(coalesce(p->>'nombre','')),''),''),
    upper(coalesce(p->>'rol','')),
    coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''),''),
    case when v_idp like 'MEX:%' then 'true' else 'false' end,
    0, 0, 0, v_bon_fin, v_san_fin, v_bonmot_fin, v_sanmot_fin, v_total, false,
    0, 0, 0, true, 'PENDIENTE', '',
    v_now, v_now
  )
  on conflict (id_dia) do nothing;

  return jsonb_build_object('ok',true,'created',true,'data',
    jsonb_build_object('idDia',v_id_dia,'bonificacion',v_bon_fin,'sancion',v_san_fin,'totalDia',v_total));
end;
$fn$;