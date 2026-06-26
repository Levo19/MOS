-- ════════════════════════════════════════════════════════════════════════════
-- 235 · #5 Editor de Adhesivos/Avisos → Supabase (Stage 1: capa de datos, CRUD)
-- ════════════════════════════════════════════════════════════════════════════
-- Port de AdhesivosPersonalizados.gs (CRUD de plantillas) a Supabase. Espejo EXACTO
-- de las hojas ADHESIVOS_PLANTILLAS (idPlantilla|nombre|descripcion|tamanoCanvas|
-- json|creadoPor|fechaCreado|fechaUltMod|activo) + ICONOS_BITMAPS_ADH (idIcono|
-- tamano_dots|hex). Las RPCs devuelven el MISMO shape que el GAS (mismas keys camelCase)
-- para que el front (assets/editor-adhesivos/) sea drop-in.
--
-- INERTE: estas RPCs no las llama nadie todavía (el front sigue por GAS hasta el
-- cutover gateado de Stage 3). La impresión (TSPL2+PrintNode) va en Stage 2 (Edge).
-- ════════════════════════════════════════════════════════════════════════════

-- ── Tablas ──────────────────────────────────────────────────────────────────
create table if not exists mos.adhesivo_plantillas (
  id_plantilla   text primary key,
  nombre         text not null,
  descripcion    text not null default '',
  tamano_canvas  text not null default '',
  json           jsonb not null,
  creado_por     text not null default 'ADMIN',
  fecha_creado   timestamptz not null default now(),
  fecha_ult_mod  timestamptz not null default now(),
  activo         boolean not null default true
);
create index if not exists adhesivo_plantillas_activo_idx on mos.adhesivo_plantillas (activo) where activo;
-- nombre único entre ACTIVAS, case-insensitive (espeja el guard del GAS guardarAdhesivoPlantilla)
create unique index if not exists adhesivo_plantillas_nombre_activo_uq
  on mos.adhesivo_plantillas (lower(nombre)) where activo;

create table if not exists mos.adhesivo_iconos (
  id_icono     text not null,
  tamano_dots  int  not null,
  hex          text not null default '',
  primary key (id_icono, tamano_dots)
);

-- ── Validador: port EXACTO de _adhValidar (AdhesivosPersonalizados.gs:547). Devuelve
--    text[] de errores (vacío = válido). Mismas reglas: tamaño, capas (1..20), por-capa
--    tipo/posición/rango. Defensa server-side igual que el GAS (el editor ya manda JSON válido).
create or replace function mos._adh_validar(p_json jsonb)
returns text[] language plpgsql immutable set search_path = '' as $fn$
declare
  v_err   text[] := array[]::text[];
  v_capas jsonb;
  v_ancho numeric; v_alto numeric;
  c       jsonb;
  i       int := 0;
  v_pref  text;
  v_tipo  text;
  v_tipos text[] := array['texto','icono','linea','rectangulo','barcode','qr'];
  v_rot   numeric;
begin
  if p_json is null or jsonb_typeof(p_json) <> 'object' then
    return array['JSON inválido'];
  end if;
  -- tamaño — jsonb_typeof='number' = el isFinite del GAS sin riesgo de cast que lance (JSON no codifica NaN/Inf)
  if jsonb_typeof(p_json#>'{tamano,ancho_mm}') = 'number' and jsonb_typeof(p_json#>'{tamano,alto_mm}') = 'number' then
    v_ancho := (p_json#>>'{tamano,ancho_mm}')::numeric;
    v_alto  := (p_json#>>'{tamano,alto_mm}')::numeric;
  else
    v_err := v_err || 'Falta o inválido tamano.ancho_mm / alto_mm';
  end if;
  -- capas[]
  v_capas := p_json->'capas';
  if v_capas is null or jsonb_typeof(v_capas) <> 'array' then
    return v_err || 'Falta capas[]';
  end if;
  if jsonb_array_length(v_capas) = 0 then v_err := v_err || 'Plantilla sin capas'; end if;
  if jsonb_array_length(v_capas) > 20 then
    v_err := v_err || ('Demasiadas capas (' || jsonb_array_length(v_capas) || ' > 20)');
  end if;

  for c in select * from jsonb_array_elements(v_capas) loop
    i := i + 1;
    v_tipo := c->>'tipo';
    v_pref := '[Capa ' || i || ' ' || coalesce(v_tipo,'?') || ']';
    if jsonb_typeof(c) <> 'object' then v_err := v_err || (v_pref || ' no es objeto'); continue; end if;
    if v_tipo is null or not (v_tipo = any(v_tipos)) then
      v_err := v_err || (v_pref || ' tipo desconocido: ' || coalesce(v_tipo,'(null)')); continue;
    end if;
    if jsonb_typeof(c->'x_mm') <> 'number' or jsonb_typeof(c->'y_mm') <> 'number' then
      v_err := v_err || (v_pref || ' x_mm/y_mm no numéricos'); continue;
    end if;
    if (c->>'x_mm')::numeric < -1 or (c->>'y_mm')::numeric < -1 then v_err := v_err || (v_pref || ' posición negativa'); end if;
    if v_ancho is not null and (c->>'x_mm')::numeric > v_ancho then v_err := v_err || (v_pref || ' X fuera del lienzo'); end if;
    if v_alto  is not null and (c->>'y_mm')::numeric > v_alto  then v_err := v_err || (v_pref || ' Y fuera del lienzo'); end if;

    if v_tipo = 'texto' then
      if coalesce(btrim(c->>'texto'),'') = '' then v_err := v_err || (v_pref || ' texto vacío'); end if;
      if jsonb_typeof(c->'font') = 'number' and not ((c->>'font')::numeric = any(array[1,2,3,4,5]::numeric[])) then
        v_err := v_err || (v_pref || ' font inválida'); end if;
      if (c->'rotacion') is not null and jsonb_typeof(c->'rotacion') <> 'null' then
        if jsonb_typeof(c->'rotacion') <> 'number'
           or not ((c->>'rotacion')::numeric = any(array[0,90,180,270]::numeric[])) then
          v_err := v_err || (v_pref || ' rotacion debe ser 0/90/180/270'); end if;
      end if;
    elsif v_tipo = 'icono' then
      if coalesce(c->>'idIcono','') = '' then v_err := v_err || (v_pref || ' falta idIcono'); end if;
      if jsonb_typeof(c->'tamano_dots') = 'number' and ((c->>'tamano_dots')::numeric < 16 or (c->>'tamano_dots')::numeric > 192) then
        v_err := v_err || (v_pref || ' tamano_dots fuera de rango (16-192)'); end if;
    elsif v_tipo = 'barcode' then
      if coalesce(c->>'codigo','') = '' then v_err := v_err || (v_pref || ' falta código'); end if;
      if jsonb_typeof(c->'alto_dots') = 'number' and ((c->>'alto_dots')::numeric < 16 or (c->>'alto_dots')::numeric > 200) then
        v_err := v_err || (v_pref || ' alto_dots fuera de rango (16-200)'); end if;
      if jsonb_typeof(c->'narrow') = 'number' and ((c->>'narrow')::numeric < 1 or (c->>'narrow')::numeric > 5) then
        v_err := v_err || (v_pref || ' narrow fuera de rango (1-5)'); end if;
    elsif v_tipo = 'qr' then
      if coalesce(c->>'codigo','') = '' then v_err := v_err || (v_pref || ' falta contenido QR'); end if;
      if jsonb_typeof(c->'tamano_dots') = 'number' and ((c->>'tamano_dots')::numeric < 16 or (c->>'tamano_dots')::numeric > 200) then
        v_err := v_err || (v_pref || ' tamano_dots QR fuera de rango (16-200)'); end if;
    elsif v_tipo in ('linea','rectangulo') then
      if (c->'ancho_mm') is not null and jsonb_typeof(c->'ancho_mm') not in ('number','null') then v_err := v_err || (v_pref || ' ancho_mm inválido'); end if;
      if (c->'alto_mm')  is not null and jsonb_typeof(c->'alto_mm')  not in ('number','null') then v_err := v_err || (v_pref || ' alto_mm inválido'); end if;
    end if;
  end loop;
  return v_err;
end;
$fn$;

-- ── listar: activas, json YA parseado (jsonb), shape camelCase idéntico al GAS _adhListarPlantillas ──
create or replace function mos.adhesivo_plantillas_listar()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select jsonb_build_object('ok', true, 'plantillas', coalesce((
    select jsonb_agg(jsonb_build_object(
      'idPlantilla', id_plantilla, 'nombre', nombre, 'descripcion', descripcion,
      'tamanoCanvas', tamano_canvas, 'json', json, 'jsonCorrupto', false,
      'creadoPor', creado_por, 'fechaCreado', fecha_creado, 'fechaUltMod', fecha_ult_mod, 'activo', true
    ) order by fecha_ult_mod desc)
    from mos.adhesivo_plantillas where activo
  ), '[]'::jsonb));
$fn$;

-- ── guardar: insert (genera ADH-xxxxxxxx) o update por idPlantilla. Valida + uniqueness ──
--    p = {nombre, descripcion?, json (object|string), idPlantilla?, creadoPor?}
create or replace function mos.adhesivo_plantilla_guardar(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nombre text := btrim(coalesce(p->>'nombre',''));
  v_desc   text := coalesce(p->>'descripcion','');
  v_creador text := coalesce(nullif(p->>'creadoPor',''),'ADMIN');
  v_id     text := nullif(p->>'idPlantilla','');
  v_json   jsonb;
  v_err    text[];
  v_tam    text;
  v_existe boolean;
begin
  if v_nombre = '' then return jsonb_build_object('ok', false, 'error', 'nombre requerido'); end if;
  if length(v_nombre) > 50 then return jsonb_build_object('ok', false, 'error', 'nombre muy largo (máx 50)'); end if;
  -- json puede venir como objeto jsonb o como string JSON
  begin
    v_json := case when jsonb_typeof(p->'json') is not null then p->'json' else (p->>'json')::jsonb end;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'JSON inválido');
  end;
  if v_json is null then return jsonb_build_object('ok', false, 'error', 'JSON inválido'); end if;
  v_err := mos._adh_validar(v_json);
  if array_length(v_err, 1) > 0 then
    return jsonb_build_object('ok', false, 'error', 'Plantilla inválida', 'detalles', to_jsonb(v_err));
  end if;
  v_tam := coalesce(v_json#>>'{tamano,ancho_mm}','50') || 'x' || coalesce(v_json#>>'{tamano,alto_mm}','25');

  if v_id is not null then
    update mos.adhesivo_plantillas
       set nombre = v_nombre, descripcion = v_desc, tamano_canvas = v_tam, json = v_json, fecha_ult_mod = now()
     where id_plantilla = v_id;
    if not found then return jsonb_build_object('ok', false, 'error', 'idPlantilla no encontrada: ' || v_id); end if;
    return jsonb_build_object('ok', true, 'idPlantilla', v_id, 'actualizado', true);
  else
    select exists(select 1 from mos.adhesivo_plantillas where activo and lower(nombre) = lower(v_nombre)) into v_existe;
    if v_existe then return jsonb_build_object('ok', false, 'error', 'Ya existe plantilla activa con nombre "' || v_nombre || '"'); end if;
    v_id := 'ADH-' || upper(substring(replace(gen_random_uuid()::text, '-', '') for 8));
    insert into mos.adhesivo_plantillas (id_plantilla, nombre, descripcion, tamano_canvas, json, creado_por)
    values (v_id, v_nombre, v_desc, v_tam, v_json, v_creador);
    return jsonb_build_object('ok', true, 'idPlantilla', v_id, 'creado', true);
  end if;
end;
$fn$;

-- ── eliminar: soft-delete (activo=false), espeja eliminarAdhesivoPlantilla ──
create or replace function mos.adhesivo_plantilla_eliminar(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(p->>'idPlantilla','');
begin
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idPlantilla requerido'); end if;
  update mos.adhesivo_plantillas set activo = false where id_plantilla = v_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no encontrada: ' || v_id); end if;
  return jsonb_build_object('ok', true, 'eliminado', v_id);
end;
$fn$;

-- ── iconos (para el Stage 2 de impresión + el render del editor): listar mapa ──
create or replace function mos.adhesivo_iconos_listar()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select jsonb_build_object('ok', true, 'iconos', coalesce((
    select jsonb_agg(jsonb_build_object('idIcono', id_icono, 'tamano_dots', tamano_dots, 'hex', hex))
    from mos.adhesivo_iconos
  ), '[]'::jsonb));
$fn$;

-- ── Grants: el editor lo usa un admin autenticado (token app=MOS). NO anon (no es catálogo público).
revoke all on function mos._adh_validar(jsonb)              from public;
revoke all on function mos.adhesivo_plantillas_listar()     from public;
revoke all on function mos.adhesivo_plantilla_guardar(jsonb) from public;
revoke all on function mos.adhesivo_plantilla_eliminar(jsonb) from public;
revoke all on function mos.adhesivo_iconos_listar()         from public;
grant execute on function mos._adh_validar(jsonb)              to authenticated, service_role;
grant execute on function mos.adhesivo_plantillas_listar()     to authenticated, service_role;
grant execute on function mos.adhesivo_plantilla_guardar(jsonb) to authenticated, service_role;
grant execute on function mos.adhesivo_plantilla_eliminar(jsonb) to authenticated, service_role;
grant execute on function mos.adhesivo_iconos_listar()         to authenticated, service_role;

notify pgrst, 'reload schema';
