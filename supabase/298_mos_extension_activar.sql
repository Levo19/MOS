-- ============================================================================
-- 298_mos_extension_activar.sql — FASE 7: flip de identidad + printer + ACTIVACIÓN
-- ----------------------------------------------------------------------------
-- Requiere: 287/288/289 re-aplicados (identidad MEX:NOMBRE|ZONA + registro de device
-- principal + recompute usa r.zona) y 297 (tablas/RPCs de extensión).
-- Seguro ahora: nadie usando la app (confirmado por el dueño).
-- ============================================================================

-- ── impresora del device (para el ruteo cross-app al PRINCIPAL) ──────────────
alter table mos.accesos_dispositivos add column if not exists printer_id text default '';

-- ── resolver: impresora del PRINCIPAL de una persona hoy ─────────────────────
-- Devuelve {ok, deviceId, printerId} del equipo principal ACTIVO de esa identidad/día.
-- Lo usa MOS (enviar a cobrar) y WH (guardar preingreso) para imprimir en el equipo fijo.
create or replace function mos.printer_principal(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_idp   text := btrim(coalesce(p->>'idPersonal',''));
  v_fecha text := coalesce(nullif(btrim(p->>'fecha',''),''), to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD'));
  v_iddia text;
  v_dev   text; v_pr text;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp = '' then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  v_iddia := mos._liqdia_key(v_idp, v_fecha);
  select device_id, coalesce(nullif(printer_id,''),'')
    into v_dev, v_pr
    from mos.accesos_dispositivos
   where id_dia = v_iddia and es_principal and upper(coalesce(estado,''))='ACTIVA'
   order by hora_ingreso limit 1;
  if v_dev is null then
    -- fallback: el device_id de la fila (compat con sesiones sin tabla de devices)
    select device_id into v_dev from mos.liquidaciones_dia where id_dia = v_iddia;
  end if;
  return jsonb_build_object('ok', v_dev is not null, 'deviceId', coalesce(v_dev,''), 'printerId', coalesce(v_pr,''));
end;
$fn$;
revoke all on function mos.printer_principal(jsonb) from public;
grant execute on function mos.printer_principal(jsonb) to authenticated, service_role;

-- ── RPC: registrar la impresora de un device (lo llama el frontend al elegirla) ──
create or replace function mos.registrar_printer_device(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_dia   text := btrim(coalesce(p->>'idDia',''));
  v_dev   text := btrim(coalesce(p->>'deviceId',''));
  v_pr    text := btrim(coalesce(p->>'printerId',''));
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dia = '' or v_dev = '' then return jsonb_build_object('ok',false,'error','idDia y deviceId requeridos'); end if;
  update mos.accesos_dispositivos set printer_id = v_pr, ultima_conexion = now()
   where id_dia = v_dia and device_id = v_dev;
  return jsonb_build_object('ok', found);
end;
$fn$;
revoke all on function mos.registrar_printer_device(jsonb) from public;
grant execute on function mos.registrar_printer_device(jsonb) to authenticated, service_role;

-- ── MIGRACIÓN de HOY: re-llavear filas viejas MEX:<nombre> → MEX:<NOMBRE>|<ZONA> ──
-- Solo HOY, solo temporales (MEX: sin '|'), NO PAGADAS, con zona conocida, y solo si el
-- nuevo id no colisiona. Las filas de días pasados quedan en formato viejo (inertes).
do $mig$
declare
  r record;
  v_newidp text; v_newid text;
begin
  for r in
    select id_dia, id_personal, nombre, coalesce(zona,'') zona, device_id, rol
      from mos.liquidaciones_dia
     where (fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
       and id_personal like 'MEX:%' and position('|' in id_personal) = 0
       and upper(coalesce(estado,'')) <> 'PAGADA'
       and btrim(coalesce(zona,'')) <> ''
  loop
    v_newidp := mos._identidad_persona(null, r.nombre, r.zona, true);
    v_newid  := mos._liqdia_key(v_newidp, to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD'));
    if v_newidp <> r.id_personal
       and not exists(select 1 from mos.liquidaciones_dia where id_dia = v_newid) then
      update mos.liquidaciones_dia set id_personal = v_newidp, id_dia = v_newid where id_dia = r.id_dia;
      -- mover devices atados (si los hubiera) al nuevo id_dia
      update mos.accesos_dispositivos set id_dia = v_newid where id_dia = r.id_dia;
      -- sembrar el device principal si venía en la fila y no está en la tabla
      if btrim(coalesce(r.device_id,'')) <> '' then
        insert into mos.accesos_dispositivos (id_dia, device_id, rol, es_principal, estado)
        values (v_newid, r.device_id, r.rol, true, 'ACTIVA')
        on conflict (id_dia, device_id) do nothing;
      end if;
    end if;
  end loop;
end;
$mig$;

-- ── ACTIVAR ──────────────────────────────────────────────────────────────────
update mos.config set valor='1' where clave='MOS_EXTENSION_DIRECTO';
