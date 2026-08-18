-- 854c: "JUAN P. te ha yapeado S/12.50" perdía el nombre — el patrón cortaba en el punto de la
-- inicial del apellido. Los nombres peruanos abreviados con punto son la norma en Yape.
create or replace function mos._yape_parse(p_texto text)
returns jsonb language plpgsql immutable set search_path to '' as $fn$
declare
  t text := regexp_replace(coalesce(p_texto,''), '[[:space:]]+', ' ', 'g');
  m text[]; v_monto numeric; v_nom text;
begin
  m := regexp_match(t, 'S/\.?[[:space:]]*([0-9]+(?:[.,][0-9]{1,2})?)');
  if m is not null then
    begin v_monto := replace(m[1], ',', '.')::numeric; exception when others then v_monto := null; end;
  end if;

  -- "<NOMBRE> te envió / te ha yapeado / te yapeó" — el nombre puede traer puntos (JUAN P.)
  m := regexp_match(t, '([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ. ]{1,60}?)[[:space:]]te[[:space:]](?:envió|envio|ha[[:space:]]yapeado|yapeó|yapeo)');
  if m is not null then v_nom := btrim(m[1]); end if;
  -- "…de <NOMBRE>" al final o antes de una preposición
  if v_nom is null then
    m := regexp_match(t, '[[:space:]]de[[:space:]]([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ. ]{1,60}?)[[:space:]]*(?:$|[.!¡,]|por[[:space:]]|el[[:space:]]|a[[:space:]]las[[:space:]])');
    if m is not null then v_nom := btrim(m[1]); end if;
  end if;
  if v_nom is not null then
    v_nom := btrim(regexp_replace(v_nom, '^(el|la|los|las|sr\.?|sra\.?)[[:space:]]+', '', 'i'));
    v_nom := btrim(regexp_replace(v_nom, '[[:space:]]*(te|le)$', '', 'i'));
    if length(v_nom) < 2 then v_nom := null; end if;
  end if;

  return jsonb_build_object('monto', v_monto, 'pagador', v_nom, 'ok', (v_monto is not null));
end $fn$;
