-- 378 · kill-GAS (MOS) money jornales — orquestadores puros que reusan los RPC-núcleo.
-- backfillLiquidacionesDia → mos.backfill_liquidaciones_dia (loop recompute en ventana, sella PAGADA/VETADA).
-- importarJornadasDesdeCajas → mos.importar_jornadas_desde_cajas (lee me.cajas + registrar_jornada_auto).
-- Gate mos._claim_ok(). Idempotentes (recompute salta sellados; jornada dedupe nombre+fecha).

-- ── backfill: recompute masivo de las filas EXISTENTES en la ventana de N días ──
-- Réplica fiel del GAS: iterar hoy..hoy-(dias-1) y recomputar. NO crea filas (las crea el flujo
-- de acceso/jornada); recomputar_dia SELLA PAGADA/VETADA (no reescribe dinero pagado/retenido).
-- El cross-check GAS a PAGADA era artefacto de la Hoja (en Supabase el pago ya sella la fila).
create or replace function mos.backfill_liquidaciones_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_dias   int  := greatest(1, least(370, coalesce(mos._numn(p->>'dias'),30)::int));
  v_hoy    date := (now() at time zone 'America/Lima')::date;
  v_desde  date;
  rec      record;
  v_reco   int := 0;
  v_salt   int := 0;
  v_res    jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- recompute masivo: el cap 8s de `authenticated` no basta si la ventana crece → sube el timeout
  -- SOLO para esta tx (SECURITY DEFINER lo permite). El GAS tardaba 60-90s; en Postgres ~1s hoy.
  perform set_config('statement_timeout', '120s', true);
  v_desde := v_hoy - (v_dias - 1);
  for rec in
    select id_personal, (fecha at time zone 'America/Lima')::date as dia
      from mos.liquidaciones_dia
     where (fecha at time zone 'America/Lima')::date between v_desde and v_hoy
       and upper(coalesce(rol,'')) not in ('MASTER','ADMIN','ADMINISTRADOR')
  loop
    v_res := mos.recomputar_dia(jsonb_build_object('idPersonal', rec.id_personal, 'fecha', rec.dia::text));
    if coalesce(v_res->>'skipped','') <> '' then v_salt := v_salt + 1; else v_reco := v_reco + 1; end if;
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'recomputadas', v_reco, 'saltadas', v_salt, 'dias', v_dias, 'desde', v_desde, 'hasta', v_hoy));
end; $fn$;

-- ── importar jornadas desde cajas ME de un día ──
-- Réplica fiel del GAS: por cada caja abierta ese día (me.cajas), si el vendedor no tiene jornada
-- ese día → registrar AUTO_CAJAS. La dedupe nombre+fecha vive en registrar_jornada_auto (idempotente).
create or replace function mos.importar_jornadas_desde_cajas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')),'');
  v_fecha   date;
  v_montoD  numeric := coalesce(mos._numn(p->>'montoDefault'),0);
  v_por     text := coalesce(nullif(btrim(coalesce(p->>'registradoPor','')),''),'AUTO');
  rec       record;
  v_pid     text; v_rol text; v_monto numeric; v_zona text; v_nomfull text;
  v_res     jsonb;
  v_imp     int := 0;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  begin v_fecha := coalesce(v_fecha_s::date, (now() at time zone 'America/Lima')::date);
  exception when others then v_fecha := (now() at time zone 'America/Lima')::date; end;

  for rec in
    select distinct on (lower(btrim(vendedor)))
           btrim(vendedor) as vendedor, coalesce(nullif(btrim(coalesce(zona_id,'')),''), btrim(coalesce(estacion,''))) as zona
      from me.cajas
     where (fecha_apertura at time zone 'America/Lima')::date = v_fecha
       and nullif(btrim(coalesce(vendedor,'')),'') is not null
     order by lower(btrim(vendedor)), fecha_apertura asc
  loop
    -- match a personal por nombre+apellido o solo nombre (case-insensitive)
    select id_personal, coalesce(rol,'VENDEDOR'), coalesce(monto_base, v_montoD)
      into v_pid, v_rol, v_monto
      from mos.personal
     where mos._norm_nom(btrim(nombre||' '||coalesce(apellido,''))) = mos._norm_nom(rec.vendedor)
        or mos._norm_nom(coalesce(nombre,'')) = mos._norm_nom(rec.vendedor)
     order by (mos._norm_nom(btrim(nombre||' '||coalesce(apellido,''))) = mos._norm_nom(rec.vendedor)) desc
     limit 1;
    if not found then v_pid := ''; v_rol := 'VENDEDOR'; v_monto := v_montoD; end if;

    v_res := mos.registrar_jornada_auto(jsonb_build_object(
      'nombre', rec.vendedor, 'fecha', v_fecha::text, 'idPersonal', coalesce(v_pid,''),
      'rol', v_rol, 'appOrigen', 'mosExpress', 'zona', coalesce(rec.zona,''),
      'montoJornal', v_monto, 'fuente', 'AUTO_CAJAS', 'registradoPor', v_por));
    if coalesce((v_res->>'ok')::boolean,false) and not coalesce((v_res->>'dedup')::boolean,false) then
      v_imp := v_imp + 1;
    end if;
  end loop;

  return jsonb_build_object('ok',true,'data',jsonb_build_object('importados', v_imp, 'fecha', v_fecha));
end; $fn$;

revoke all on function mos.backfill_liquidaciones_dia(jsonb), mos.importar_jornadas_desde_cajas(jsonb) from public, anon;
grant execute on function mos.backfill_liquidaciones_dia(jsonb), mos.importar_jornadas_desde_cajas(jsonb) to authenticated, service_role;
