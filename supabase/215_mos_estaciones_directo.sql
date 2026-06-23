-- 215_mos_estaciones_directo.sql — Escritura DIRECTA de estaciones a Supabase (100% Supabase, sin GAS).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- Cierra el último caso del patrón "el dato no aterriza": estaciones era la única tabla del catálogo cuya
-- escritura iba por GAS→Hoja y dependía del sync batch (que muere). Ahora MOS escribe directo a
-- mos.estaciones (igual que mos.crear_proveedor). El trigger de versión (200) ya cubre mos.estaciones →
-- al escribir, bumpea catalogo_version → WH/ME refrescan. Gate: MOS_CATALOGO_DIRECTO (ya ON) + claim.
-- Idempotente (dedup por local_id y por PK). actualizar = patch PARCIAL (el front manda solo activo / solo
-- adminPin / etc.). Money-safe: estaciones no es dinero; additivo; no toca otras tablas.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;
-- local_id para idempotencia de gesto (additivo, no rompe filas existentes)
alter table mos.estaciones add column if not exists local_id text;

-- ── CREAR ──
create or replace function mos.crear_estacion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_local  text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id     text := nullif(btrim(coalesce(p->>'idEstacion','')), '');
  v_nombre text := nullif(btrim(coalesce(p->>'nombre','')), '');
  v_existe text; v_inserted int;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nombre is null then return jsonb_build_object('ok',false,'error','Requiere nombre'); end if;

  if v_local is not null then
    select id_estacion into v_existe from mos.estaciones where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEstacion', v_existe)); end if;
  end if;
  if v_id is not null and exists (select 1 from mos.estaciones where id_estacion = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEstacion', v_id));
  end if;

  v_id := coalesce(v_id, 'ES'||(extract(epoch from clock_timestamp())*1000)::bigint::text);
  insert into mos.estaciones (id_estacion, id_zona, nombre, tipo, app_origen, admin_pin, activo, descripcion, local_id)
  values (
    v_id,
    nullif(btrim(coalesce(p->>'idZona','')),''),
    v_nombre,
    coalesce(nullif(btrim(coalesce(p->>'tipo','')),''),'CAJA'),
    coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''),'mosExpress'),
    nullif(btrim(coalesce(p->>'adminPin','')),''),
    true,
    nullif(btrim(coalesce(p->>'descripcion','')),''),
    v_local
  )
  on conflict (id_estacion) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEstacion', v_id));
  end if;
  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idEstacion', v_id));
exception when unique_violation then
  return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEstacion', v_id));
end;
$fn$;

-- ── ACTUALIZAR (patch PARCIAL: solo las claves presentes en p) ──
create or replace function mos.actualizar_estacion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idEstacion','')), ''); v_n int;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idEstacion'); end if;

  update mos.estaciones set
    id_zona     = case when p ? 'idZona'      then nullif(btrim(p->>'idZona'),'')                              else id_zona end,
    nombre      = case when p ? 'nombre'       then coalesce(nullif(btrim(p->>'nombre'),''), nombre)            else nombre end,
    tipo        = case when p ? 'tipo'         then coalesce(nullif(btrim(p->>'tipo'),''), tipo)                else tipo end,
    app_origen  = case when p ? 'appOrigen'    then coalesce(nullif(btrim(p->>'appOrigen'),''), app_origen)     else app_origen end,
    admin_pin   = case when p ? 'adminPin'     then nullif(btrim(p->>'adminPin'),'')                            else admin_pin end,
    activo      = case when p ? 'activo'       then (lower(coalesce(p->>'activo','')) in ('1','true','t','si','sí','y','yes')) else activo end,
    descripcion = case when p ? 'descripcion'  then nullif(btrim(p->>'descripcion'),'')                         else descripcion end
  where id_estacion = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','Estación no encontrada: '||v_id); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

revoke all on function mos.crear_estacion(jsonb)      from public;
revoke all on function mos.actualizar_estacion(jsonb) from public;
grant execute on function mos.crear_estacion(jsonb)      to authenticated;
grant execute on function mos.actualizar_estacion(jsonb) to authenticated;
