-- 876 · El parser contra la PRIMERA notificación real de Yape (19-ago, ZONA-02):
--   "Confirmación de Pago Javier Vas* te envió un pago por S/ 0.1. El cód. de seguridad es: 144"
-- Sacaba el monto (0.10) pero NO el nombre: Yape abrevia el apellido con "*" y la regex del
-- nombre solo aceptaba letras; además "Confirmación de Pago" quedaba pegado adelante.
-- Ahora: el nombre admite "*" y dígitos (Yape abrevia "Javier Vas*"), se recortan los
-- encabezados de Yape ("Confirmación de Pago", "Yape", "¡Recibiste un pago!"), y se limpia el
-- "*" final para la voz ("de Javier Vas").
begin;
create or replace function mos._yape_parse(p_texto text)
returns jsonb
language plpgsql
immutable
set search_path to ''
as $$
declare
  t text := regexp_replace(coalesce(p_texto,''), '[[:space:]]+', ' ', 'g');
  m text[]; v_monto numeric; v_nom text;
begin
  if t ~* '(le yapeaste|yapeaste a|enviaste|tu yapeo fue|pago enviado|pagaste a)' then
    return jsonb_build_object('monto', null, 'pagador', null, 'ok', false, 'motivo', 'SALIENTE');
  end if;

  m := regexp_match(t, 'S/\.?[[:space:]]*([0-9]+(?:[.,][0-9]{1,2})?)');
  if m is not null then
    begin v_monto := replace(m[1], ',', '.')::numeric; exception when others then v_monto := null; end;
  end if;
  if v_monto is null or v_monto <= 0 then
    return jsonb_build_object('monto', null, 'pagador', null, 'ok', false, 'motivo', 'SIN_MONTO');
  end if;

  -- quitar los encabezados que Yape pone delante (el APK manda título + cuerpo en un solo texto)
  t := regexp_replace(t, '^(.*[!¡][[:space:]]*)', '');
  t := regexp_replace(t, '^((yape|confirmaci[oó]n de pago|pago recibido|recibiste un pago|recibiste)[[:space:]:·-]*)+', '', 'i');

  -- "<NOMBRE> te envió / te ha yapeado / te yapeó …". El nombre admite letras, puntos, espacios,
  -- dígitos y el "*" con que Yape abrevia ("Javier Vas*").
  m := regexp_match(t, '([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ0-9.* ]{1,60}?)[[:space:]]te[[:space:]](?:envió|envio|ha[[:space:]]yapeado|yapeó|yapeo)');
  if m is not null then v_nom := btrim(m[1]); end if;
  if v_nom is null then
    m := regexp_match(t, '[[:space:]]de[[:space:]]([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ0-9.* ]{1,60}?)[[:space:]]*(?:$|[.!¡,]|por[[:space:]]|el[[:space:]]|a[[:space:]]las[[:space:]])');
    if m is not null then v_nom := btrim(m[1]); end if;
  end if;
  if v_nom is not null then
    v_nom := btrim(regexp_replace(v_nom, '^(el|la|los|las|sr\.?|sra\.?)[[:space:]]+', '', 'i'));
    v_nom := btrim(regexp_replace(v_nom, '[[:space:]]*(te|le)$', '', 'i'));
    v_nom := btrim(regexp_replace(v_nom, '\*+$', ''));      -- "Javier Vas*" → "Javier Vas" (para la voz)
    if length(v_nom) < 2 then v_nom := null; end if;
  end if;

  return jsonb_build_object('monto', v_monto, 'pagador', v_nom, 'ok', true);
end $$;
commit;

-- y se re-parsea el Yape real que quedó sin nombre
update mos.yapes_entrantes y
   set pagador = (mos._yape_parse(y.raw)->>'pagador')
 where y.pagador is null and y.monto is not null
   and (mos._yape_parse(y.raw)->>'pagador') is not null;
select id, monto, pagador from mos.yapes_entrantes order by id desc limit 3;
