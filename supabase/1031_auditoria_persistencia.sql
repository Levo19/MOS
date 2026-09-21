-- 1031 · Auditorías que "no se guardaban" (21-sep-2026). Base: pg_get_functiondef vivo de mos.crear_evaluacion.
-- (1) El personal de ME (MEX:*) nunca quedaba "auditado": materializar/resumen_dia lo excluye por diseño; el
--     bono/descuento SÍ se aplicaba pero auditado/evaluaciones_count quedaban false/0 → el admin re-auditaba.
--     Ahora crear_evaluacion marca auditado + conteo para TODOS.
-- (2) Los hooks de dinero ya no fallan en silencio: data.hooksOk / data.hookError → el front avisa.
-- (3) statement_timeout 30s (el rol authenticated tiene 8s; materializar el día entero con locks lo superaba
--     al auditar varios días seguidos → rollback total de la auditoría). Igual que resumen_todos_dia (726).
CREATE OR REPLACE FUNCTION mos.crear_evaluacion(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_local  text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id     text := nullif(btrim(coalesce(p->>'idEval','')), '');
  v_pers   text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_rol    text := nullif(btrim(coalesce(p->>'rol','')), '');
  v_fecha  timestamptz;
  v_fecha_s text;
  v_checks jsonb;
  v_inserted int;
  v_existe text;
  v_dedup boolean := false;
  -- hooks DINERO
  v_bon_new numeric := greatest(0, coalesce(mos._numn(p->>'bonificacion'),0));
  v_san_new numeric := greatest(0, coalesce(mos._numn(p->>'sancion'),0));
  v_ajuste_tocado boolean;
  v_ajuste_tipo text := nullif(lower(btrim(coalesce(p->>'ajusteTipo',''))), '');
  v_solo text;
  v_bonmot_fin text := coalesce(p->>'bonificacionMotivo','');
  v_sanmot_fin text := coalesce(p->>'sancionMotivo','');
  v_tmp text;
  v_hook_err text := '';      -- [1031] fallos de hooks que antes se tragaban en silencio
  v_bs jsonb;
  v_nact int;
begin
  if coalesce((select valor from mos.config where clave='MOS_EVAL_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_EVAL_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_pers is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  if v_rol  is null then return jsonb_build_object('ok',false,'error','rol requerido'); end if;

  -- control_checks (idéntico a 82)
  if (p ? 'controlChecks') and jsonb_typeof(p->'controlChecks') in ('object','array') then
    v_checks := p->'controlChecks';
  else
    begin
      v_checks := coalesce(nullif(btrim(coalesce(p->>'controlChecks','')),'')::jsonb, '{}'::jsonb);
    exception when others then v_checks := '{}'::jsonb;
    end;
  end if;

  -- fecha: SOLO-fecha 'YYYY-MM-DD' → ancla a MEDIANOCHE LIMA (Perú UTC-5 fijo), igual que _mosDate de GAS y
  -- que set_bonificacion_sancion/materializar (85/96). Sin esto, '2026-06-13' se parsea como UTC-midnight →
  -- (at time zone Lima)::date = 2026-06-12 → materializaría/llavearía el DÍA ANTERIOR (bug date-only 40x).
  -- ISO con offset/hora explícita → se respeta tal cual.
  v_tmp := nullif(btrim(coalesce(p->>'fecha','')),'');
  begin
    if v_tmp is not null and v_tmp ~ '^\d{4}-\d{2}-\d{2}$' then
      v_fecha := (v_tmp || 'T00:00:00-05:00')::timestamptz;       -- medianoche Lima
    else
      v_fecha := v_tmp::timestamptz;
    end if;
  exception when others then v_fecha := null;
  end;
  v_fecha := coalesce(v_fecha, now());
  -- fecha 'YYYY-MM-DD' en DÍA DE NEGOCIO Lima (para los hooks que llavean por fecha-Lima, = _hoy() del GAS).
  v_fecha_s := to_char((v_fecha at time zone 'America/Lima')::date, 'YYYY-MM-DD');

  -- IDEMPOTENCIA por local_id (gesto)
  if v_local is not null then
    select id_eval into v_existe from mos.evaluaciones where local_id = v_local limit 1;
    if found then v_dedup := true; v_id := v_existe; end if;
  end if;
  -- IDEMPOTENCIA por PK
  if not v_dedup and v_id is not null and exists (select 1 from mos.evaluaciones where id_eval = v_id) then
    v_dedup := true;
  end if;

  if not v_dedup then
    v_id := coalesce(v_id, 'EV'||(extract(epoch from clock_timestamp())*1000)::bigint::text);
    begin
      insert into mos.evaluaciones (
        id_eval, fecha, id_personal, rol, hora,
        limpieza_pct, limpieza_prof_pct, control_checks, comentario, evaluado_por,
        aplica_comision, aplica_bono_meta, activo,
        sancion, sancion_motivo, bonificacion, bonificacion_motivo, local_id
      ) values (
        v_id, v_fecha, v_pers, v_rol,
        coalesce(nullif(btrim(coalesce(p->>'hora','')),''), to_char(clock_timestamp(),'HH24:MI:SS')),
        coalesce(mos._numn(p->>'limpiezaPct'),0),
        coalesce(mos._numn(p->>'limpiezaProfPct'),0),
        v_checks,
        coalesce(nullif(btrim(coalesce(p->>'comentario','')),''),''),
        coalesce(nullif(btrim(coalesce(p->>'evaluadoPor','')),''),''),
        case when (p ? 'aplicaComision') and (p->>'aplicaComision') in ('false','f','0') then false else true end,
        case when (p ? 'aplicaBonoMeta') and (p->>'aplicaBonoMeta') in ('false','f','0') then false else true end,
        true,
        v_san_new,
        coalesce(nullif(btrim(coalesce(p->>'sancionMotivo','')),''),''),
        v_bon_new,
        coalesce(nullif(btrim(coalesce(p->>'bonificacionMotivo','')),''),''),
        v_local
      )
      on conflict (id_eval) do nothing;
      get diagnostics v_inserted = row_count;
      if v_inserted = 0 then v_dedup := true; end if;
    exception when unique_violation then
      v_dedup := true;
      if v_local is not null then
        select id_eval into v_existe from mos.evaluaciones where local_id = v_local limit 1;
        if found then v_id := v_existe; end if;
      end if;
    end;
  end if;

  -- ── HOOKS DINERO (réplica gas/Evaluaciones.gs:116-187) — solo si LIQDIA directo está ON ──
  -- 1) materializar AUTO del día (idempotente; forzar=true → el día de la eval es fresco por definición).
  -- 2) set bon/san con soloTipo + fusión de motivos, si _ajusteTocado || bon>0 || san>0.
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') = '1' then
    -- soloTipo: explícito ('sancion'|'bonificacion') o derivado (bon>0&san=0→bonif; san>0&bon=0→sanción).
    -- [v2.43.373] soloTipo SOLO si el frontend lo manda explícito (compat con el toggle
    -- viejo). El frontend nuevo manda ajusteTipo=null → soloTipo=null → REEMPLAZA AMBOS
    -- con lo enviado (los dos campos son la fuente de verdad; limpiar uno lo pone en 0).
    v_solo := case when v_ajuste_tipo in ('sancion','bonificacion') then v_ajuste_tipo else null end;
    v_ajuste_tocado := (p->>'_ajusteTocado' in ('true','t','1'))
                    or (p->>'_resetBonSan'  in ('true','t','1'))
                    or v_bon_new > 0 or v_san_new > 0;

    -- (1) materializar AUTO. NUNCA aborta la eval por un fallo del hook (la fila cruda YA está commiteada).
    begin
      perform mos.materializar_liquidacion_dia(jsonb_build_object('fecha', v_fecha_s, 'forzar', true));
    exception when others then v_hook_err := v_hook_err || 'materializar: ' || SQLERRM || '. ';   -- [1031]
    end;

    -- (2) set bon/san (reemplazo). [v2.43.373] SIN fusión de motivos: el motivo es el
    -- comentario LIMPIO que mandó el admin (v_bonmot_fin/v_sanmot_fin ya = p->>'...Motivo').
    -- Antes se concatenaban todos los motivos del día (' · ') → texto largo y duplicado.
    -- Si el monto del concepto es 0, su motivo se limpia.
    if v_ajuste_tocado then
      begin
        if v_bon_new = 0 then v_bonmot_fin := ''; end if;
        if v_san_new = 0 then v_sanmot_fin := ''; end if;

        v_bs := mos.set_bonificacion_sancion(jsonb_build_object(
          'idPersonal', v_pers,
          'fecha',      v_fecha_s,
          'bonificacion', v_bon_new,
          'sancion',      v_san_new,
          'bonificacionMotivo', v_bonmot_fin,
          'sancionMotivo',      v_sanmot_fin,
          'soloTipo',   v_solo,
          'rol',        v_rol
        ));
        -- [1031] un ok:false de set_bonificacion_sancion ya no se pierde
        if v_bs is not null and not coalesce((v_bs->>'ok')::boolean, true) then
          v_hook_err := v_hook_err || 'bono/descuento: ' || coalesce(v_bs->>'error', v_bs::text) || '. ';
        end if;
      exception when others then
        v_hook_err := v_hook_err || 'bono/descuento: ' || SQLERRM || '. ';  -- [1031] antes: null (silencio)
      end;
    end if;
  end if;

  -- [1031] marcar el día como AUDITADO + conteo, para TODOS (también personal de ME "MEX:*", que
  -- materializar/resumen_dia excluye por diseño → antes quedaban "sin auditar" para siempre aunque el
  -- bono/descuento sí se aplicara, y el admin re-auditaba creyendo que no se guardó).
  begin
    select count(*)::int into v_nact from mos.evaluaciones
     where id_personal = v_pers and coalesce(activo, true)
       and (fecha at time zone 'America/Lima')::date = v_fecha_s::date;
    update mos.liquidaciones_dia
       set auditado = (v_nact > 0), evaluaciones_count = v_nact, ts_actualizado = now()
     where id_dia = mos._liqdia_resolver(v_pers, v_fecha_s)
       and (auditado is distinct from (v_nact > 0) or evaluaciones_count is distinct from v_nact);
  exception when others then v_hook_err := v_hook_err || 'auditado: ' || SQLERRM || '. ';
  end;

  -- LATIDO: mantener viva la frescura de la sombra sin depender del sync-que-lee-Sheet.
  perform mos._tocar_latido_sync();

  if v_dedup then
    return jsonb_build_object('ok',true,'dedup',true,'data',
      jsonb_build_object('idEval', v_id, 'bonificacion', v_bon_new, 'sancion', v_san_new,
                         'hooksOk', v_hook_err = '', 'hookError', nullif(v_hook_err,'')));
  end if;
  return jsonb_build_object('ok',true,'dedup',false,'data',
    jsonb_build_object('idEval', v_id, 'bonificacion', v_bon_new, 'sancion', v_san_new,
                       'hooksOk', v_hook_err = '', 'hookError', nullif(v_hook_err,'')));
end;
$function$
;

alter function mos.crear_evaluacion(jsonb) set statement_timeout = '30s';

-- Backfill: días con auditorías activas que quedaron "sin auditar" / con conteo incorrecto (sobre todo MEX:*)
with ev as (
  select id_personal, (fecha at time zone 'America/Lima')::date d, count(*)::int n
    from mos.evaluaciones where coalesce(activo,true) group by 1,2
)
update mos.liquidaciones_dia l
   set auditado = true, evaluaciones_count = ev.n, ts_actualizado = now()
  from ev
 where l.id_personal = ev.id_personal and (l.fecha at time zone 'America/Lima')::date = ev.d
   and (coalesce(l.auditado,false) = false or coalesce(l.evaluaciones_count,0) <> ev.n);
