-- ============================================================================
-- 305_mos_nota_sesion.sql — Nota compartida de sesión (companion)
-- ----------------------------------------------------------------------------
-- Los equipos atados a la MISMA sesión (mismo id_dia = MEX:NOMBRE|ZONA del día)
-- comparten una nota corta en vivo: principal y companion la ven y editan.
-- 100% Supabase (cero-GAS). Gated por mos._ext_app_ok() (mosExpress/MOS) y por
-- la MISMA bandera MOS_EXTENSION_DIRECTO que todo el companion.
--
-- Se guarda en la propia fila de la sesión (mos.liquidaciones_dia) → 1 nota por
-- sesión, sin tabla nueva. Versionada por timestamp: last-write-wins con aviso
-- (el cliente descarta su tipeo si el server tiene una versión más nueva de OTRO
--  equipo). set NO crea la fila: solo pega sobre una sesión ACTIVA existente.
-- ============================================================================

alter table mos.liquidaciones_dia
  add column if not exists nota_sesion    text        default '',
  add column if not exists nota_sesion_ts timestamptz;

-- id_dia derivado igual que pedir_extension (identidad temporal por nombre|zona)
create or replace function mos._nota_iddia(p jsonb)
returns text language plpgsql stable set search_path = '' as $fn$
declare
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_fecha  text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_dia    date; v_idp text;
begin
  begin v_dia := coalesce(v_fecha::date, (now() at time zone 'America/Lima')::date);
  exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;
  v_idp := mos._identidad_persona(null, v_nombre, v_zona, true);
  return mos._liqdia_key(v_idp, to_char(v_dia,'YYYY-MM-DD'));
end;
$fn$;
revoke all on function mos._nota_iddia(jsonb) from public;
grant execute on function mos._nota_iddia(jsonb) to authenticated, service_role;

-- [500x-HIGH IDOR] el device debe estar ATADO a esa sesión para leer/escribir la nota:
--   principal (= liquidaciones_dia.device_id) o companion ACTIVO (accesos_dispositivos).
--   Sin esto, cualquier token ME podría leer/pisar la nota de CUALQUIER persona iterando
--   nombre|zona. Espeja el gate de aprobar_extension / registrar_printer_device.
create or replace function mos._nota_puede(p_iddia text, p_dev text)
returns boolean language sql stable set search_path = '' as $fn$
  select coalesce(nullif(btrim(p_dev),''),'') <> '' and (
    exists(select 1 from mos.liquidaciones_dia where id_dia = p_iddia and device_id = btrim(p_dev))
    or exists(select 1 from mos.accesos_dispositivos
               where id_dia = p_iddia and device_id = btrim(p_dev) and upper(coalesce(estado,''))='ACTIVA')
  );
$fn$;
revoke all on function mos._nota_puede(text,text) from public;
grant execute on function mos._nota_puede(text,text) to authenticated, service_role;

-- LEER: {nombre, zona, fecha} → {ok, nota, ts(epoch ms)}
create or replace function mos.nota_sesion_get(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_iddia text; v_dev text := btrim(coalesce(p->>'deviceId','')); v_nota text; v_ts timestamptz; v_act boolean := false; v_comp int := 0;
begin
  if not mos._ext_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF');
  end if;
  v_iddia := mos._nota_iddia(p);
  -- [HIGH IDOR] solo un device atado a la sesión ve la nota (principal o companion)
  if not mos._nota_puede(v_iddia, v_dev) then return jsonb_build_object('ok',false,'error','NO_ATADO'); end if;
  select coalesce(nota_sesion,''), nota_sesion_ts, upper(coalesce(estado_sesion,''))='ACTIVA'
    into v_nota, v_ts, v_act
    from mos.liquidaciones_dia where id_dia = v_iddia limit 1;
  -- companions atados hoy (rows en accesos_dispositivos ACTIVAS): el FAB de nota
  -- solo tiene sentido cuando hay ≥1 equipo extra (o ya existe una nota).
  select count(*) into v_comp from mos.accesos_dispositivos
   where id_dia = v_iddia and upper(coalesce(estado,''))='ACTIVA';
  return jsonb_build_object('ok', true, 'activa', coalesce(v_act,false),
    'companions', coalesce(v_comp,0), 'nota', coalesce(v_nota,''),
    'ts', case when v_ts is null then 0 else (extract(epoch from v_ts)*1000000)::bigint end);
end;
$fn$;
revoke all on function mos.nota_sesion_get(jsonb) from public;
grant execute on function mos.nota_sesion_get(jsonb) to authenticated, service_role;

-- ESCRIBIR: {nombre, zona, fecha, nota, baseTs?} → {ok, nota, ts, conflict?}
-- baseTs = ts que el cliente creía vigente. Si el server ya avanzó (otro equipo
--   escribió después) → conflict:true y NO se pisa (el cliente re-lee y decide).
create or replace function mos.nota_sesion_set(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_iddia text; v_dev text := btrim(coalesce(p->>'deviceId',''));
  v_nota text := left(coalesce(p->>'nota',''), 280);
  v_base  bigint := coalesce((p->>'baseTs')::bigint, 0);
  v_new   bigint; v_cn text;
begin
  if not mos._ext_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF');
  end if;
  v_iddia := mos._nota_iddia(p);
  -- [HIGH IDOR] solo un device atado a la sesión escribe la nota
  if not mos._nota_puede(v_iddia, v_dev) then return jsonb_build_object('ok',false,'error','NO_ATADO'); end if;
  -- solo sesión ACTIVA es editable (no una cerrada del mismo día)
  perform 1 from mos.liquidaciones_dia where id_dia = v_iddia and upper(coalesce(estado_sesion,''))='ACTIVA';
  if not found then return jsonb_build_object('ok',false,'error','SESION_NO_ACTIVA'); end if;
  -- [MED] escritura ATÓMICA de 1 statement (sin FOR UPDATE): el WHERE con el guard de
  -- ts (µs) sólo pega si el server NO es más nuevo que la base del cliente. Bajo
  -- contención, EvalPlanQual re-evalúa el WHERE tras liberar el lock → si otro equipo
  -- ya avanzó, esta escritura NO matchea → conflict. Minimiza el lock sobre la fila.
  update mos.liquidaciones_dia set nota_sesion = v_nota, nota_sesion_ts = now()
   where id_dia = v_iddia
     and upper(coalesce(estado_sesion,''))='ACTIVA'
     and (nota_sesion_ts is null or (extract(epoch from nota_sesion_ts)*1000000)::bigint <= v_base)
   returning (extract(epoch from nota_sesion_ts)*1000000)::bigint into v_new;
  if v_new is not null then
    return jsonb_build_object('ok',true,'conflict',false,'nota',v_nota,'ts',v_new);
  end if;
  -- no pegó → otro equipo escribió después: devolver lo vigente (last-write-wins con aviso)
  select coalesce(nota_sesion,''), (extract(epoch from nota_sesion_ts)*1000000)::bigint
    into v_cn, v_new from mos.liquidaciones_dia where id_dia = v_iddia;
  return jsonb_build_object('ok',true,'conflict',true,'nota',coalesce(v_cn,''),'ts',coalesce(v_new,0));
end;
$fn$;
revoke all on function mos.nota_sesion_set(jsonb) from public;
grant execute on function mos.nota_sesion_set(jsonb) to authenticated, service_role;
