-- ════════════════════════════════════════════════════════════════════════════
-- 243 · Fix asimetría del validador de adhesivos en numéricos-string (revisión 500x)
-- ════════════════════════════════════════════════════════════════════════════
-- El validador 235 usaba `jsonb_typeof(c->'X')='number'`, que diverge del GAS `_adhValidar`
-- (isFinite()/parseInt() COERCIONAN strings):
--   • GAS rechaza font:"9" / tamano_dots:"500"; el SQL los SALTEABA (no validaba rango).
--   • GAS acepta x_mm:"2" (isFinite); el SQL lo RECHAZABA ("no numéricos").
-- Fix: coercionador tolerante `_adh_num` (number o numeric-string → numeric; resto → null) y usarlo en
-- TODOS los chequeos numéricos → mismo comportamiento que el GAS (acepta/valida lo mismo).
-- Impacto real bajo (el editor emite números) pero cierra la divergencia de defensa-en-profundidad.
-- ════════════════════════════════════════════════════════════════════════════

-- número tolerante: imita isFinite/parseFloat del GAS sobre un valor jsonb (number o string numérico).
create or replace function mos._adh_num(v jsonb)
returns numeric language sql immutable set search_path = '' as $$
  select case
    when v is not null and (v #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (v #>> '{}')::numeric
    else null
  end
$$;

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
  v_x numeric; v_y numeric; v_n numeric;
begin
  if p_json is null or jsonb_typeof(p_json) <> 'object' then
    return array['JSON inválido'];
  end if;
  -- tamaño (isFinite ⇒ number o string numérico)
  v_ancho := mos._adh_num(p_json#>'{tamano,ancho_mm}');
  v_alto  := mos._adh_num(p_json#>'{tamano,alto_mm}');
  if (p_json->'tamano') is null or v_ancho is null or v_alto is null then
    v_err := v_err || 'Falta o inválido tamano.ancho_mm / alto_mm';
  end if;
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
    v_x := mos._adh_num(c->'x_mm');
    v_y := mos._adh_num(c->'y_mm');
    if v_x is null or v_y is null then
      v_err := v_err || (v_pref || ' x_mm/y_mm no numéricos'); continue;
    end if;
    if v_x < -1 or v_y < -1 then v_err := v_err || (v_pref || ' posición negativa'); end if;
    if v_ancho is not null and v_x > v_ancho then v_err := v_err || (v_pref || ' X fuera del lienzo'); end if;
    if v_alto  is not null and v_y > v_alto  then v_err := v_err || (v_pref || ' Y fuera del lienzo'); end if;

    if v_tipo = 'texto' then
      if coalesce(btrim(c->>'texto'),'') = '' then v_err := v_err || (v_pref || ' texto vacío'); end if;
      v_n := mos._adh_num(c->'font');
      if (c->'font') is not null and (v_n is null or not (v_n = any(array[1,2,3,4,5]::numeric[]))) then
        v_err := v_err || (v_pref || ' font inválida'); end if;
      if (c->'rotacion') is not null and jsonb_typeof(c->'rotacion') <> 'null' then
        v_n := mos._adh_num(c->'rotacion');
        if v_n is null or not (v_n = any(array[0,90,180,270]::numeric[])) then
          v_err := v_err || (v_pref || ' rotacion debe ser 0/90/180/270'); end if;
      end if;
    elsif v_tipo = 'icono' then
      if coalesce(c->>'idIcono','') = '' then v_err := v_err || (v_pref || ' falta idIcono'); end if;
      v_n := mos._adh_num(c->'tamano_dots');
      if v_n is not null and (v_n < 16 or v_n > 192) then
        v_err := v_err || (v_pref || ' tamano_dots fuera de rango (16-192)'); end if;
    elsif v_tipo = 'barcode' then
      if coalesce(c->>'codigo','') = '' then v_err := v_err || (v_pref || ' falta código'); end if;
      v_n := mos._adh_num(c->'alto_dots');
      if v_n is not null and (v_n < 16 or v_n > 200) then
        v_err := v_err || (v_pref || ' alto_dots fuera de rango (16-200)'); end if;
      v_n := mos._adh_num(c->'narrow');
      if v_n is not null and (v_n < 1 or v_n > 5) then
        v_err := v_err || (v_pref || ' narrow fuera de rango (1-5)'); end if;
    elsif v_tipo = 'qr' then
      if coalesce(c->>'codigo','') = '' then v_err := v_err || (v_pref || ' falta contenido QR'); end if;
      v_n := mos._adh_num(c->'tamano_dots');
      if v_n is not null and (v_n < 16 or v_n > 200) then
        v_err := v_err || (v_pref || ' tamano_dots QR fuera de rango (16-200)'); end if;
    elsif v_tipo in ('linea','rectangulo') then
      -- GAS: isFinite(c.ancho_mm) acepta number o string numérico; rechaza no-numérico no-null
      if (c->'ancho_mm') is not null and jsonb_typeof(c->'ancho_mm') <> 'null' and mos._adh_num(c->'ancho_mm') is null then
        v_err := v_err || (v_pref || ' ancho_mm inválido'); end if;
      if (c->'alto_mm') is not null and jsonb_typeof(c->'alto_mm') <> 'null' and mos._adh_num(c->'alto_mm') is null then
        v_err := v_err || (v_pref || ' alto_mm inválido'); end if;
    end if;
  end loop;
  return v_err;
end;
$fn$;

revoke all on function mos._adh_num(jsonb) from public;
grant execute on function mos._adh_num(jsonb) to authenticated, service_role;
notify pgrst, 'reload schema';
