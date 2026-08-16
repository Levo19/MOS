-- 814_guia_foto_rotacion.sql — [DUEÑO] "en el modal donde aparece la imagen, ¿existe forma de que
-- por un botón la foto gire 90 grados, y varias veces gira 90 más? A veces me dan la foto de
-- cabeza y debo corregirlo… y si roto la imagen acá debe cambiarse para siempre, o sea en la guía
-- de WH también."
--
-- PREGUNTA DEL DUEÑO SOBRE EL OCR: "¿cuando lee una imagen de cabeza igual detecta el IGV? Si lo
-- detecta, rotar no debe contar como cambio de imagen, solo cosmético. Si no, hay que forzarlo."
--
-- COMPROBADO CON UNA FACTURA REAL SUYA (Ajinomoto F003-0001243, guía 296sxuomh2): se descargó la
-- foto, se rotó 180° y se leyó de cabeza. Los números salen idénticos a los que el OCR ya tenía
-- guardados: Operación Gravada 1,316.75 · I.G.V. 237.01 · Importe Total 1,553.76. Un modelo de
-- visión lee un comprobante invertido sin problema. (El OCR corre con claude-haiku vía la Edge
-- `ocr-guia`; la prueba se hizo con el mismo tipo de lectura, no con la Edge en producción.)
--
-- DECISIÓN DE DISEÑO — la rotación es COSMÉTICA y no toca el archivo ni el OCR:
--   · se guarda como metadato (`wh.guias.foto_rot`, grados 0/90/180/270);
--   · el archivo en Storage NO se re-sube ni cambia de URL;
--   · `ocr_estado` NO se toca: el OCR ya leyó bien el original, no hay nada que releer.
-- Esto responde las dos ramas de la pregunta a la vez: como el archivo no cambia, da igual si el
-- modelo lee o no rotado — lo que analizó sigue siendo válido. Y como es metadato de la guía,
-- la rotación queda para SIEMPRE y la ve cualquier app que muestre esa foto (MOS y WH).

alter table wh.guias add column if not exists foto_rot smallint not null default 0;

comment on column wh.guias.foto_rot is
  '[814] Grados de rotación (0/90/180/270) con que se MUESTRA la foto del comprobante. Es cosmético: el archivo no se altera y el OCR no se re-dispara.';

create or replace function mos.guia_rotar_foto(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_paso int  := coalesce((p->>'grados')::int, 90);
  v_rot  int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_guia is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;
  -- solo múltiplos de 90; cualquier otra cosa se normaliza a un cuarto de vuelta
  if v_paso % 90 <> 0 then v_paso := 90; end if;

  update wh.guias
     set foto_rot = ((coalesce(foto_rot,0) + v_paso) % 360 + 360) % 360
   where id_guia = v_guia
   returning foto_rot into v_rot;

  if v_rot is null then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('idGuia', v_guia, 'rot', v_rot));
end;
$function$;

grant execute on function mos.guia_rotar_foto(jsonb) to anon, authenticated, service_role;

-- ── Quien devuelva la foto, debe devolver también cómo se muestra ──
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'curva_guia_detalle' order by p.oid limit 1;
  if position($a$'foto',   coalesce(nullif(btrim(v_g.foto),''), ''),$a$ in v_def) = 0 then
    raise exception '[814] no encontré la clave foto en curva_guia_detalle';
  end if;
  v_new := replace(v_def,
    $a$'foto',   coalesce(nullif(btrim(v_g.foto),''), ''),$a$,
    $b$'foto',   coalesce(nullif(btrim(v_g.foto),''), ''),
    'fotoRot', coalesce(v_g.foto_rot, 0),$b$);
  execute v_new;
end $$;
