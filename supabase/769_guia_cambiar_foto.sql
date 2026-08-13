-- 769 · Cambiar el comprobante de una guía desde el Paso 1 de MOS (13-ago-2026).
-- El dueño: "al cambiar la foto aquí debe cambiar la foto de la guía directamente y el
-- OCR debe reconocer el cambio para jalar el IGV a favor del módulo tributos".
-- La cadena ya existe: el trigger [762] wh._tg_guia_foto_ocr marca ocr_estado=PENDIENTE
-- ante CUALQUIER cambio de wh.guias.foto, y el cron OCR la procesa en ≤10 min.
-- Solo faltaba una vía de escritura autorizada desde el panel MOS.
--
-- BONUS (bug cazado de paso): wh.reencolar_ocr_guia/mes [762] usaban wh._claim_ok(),
-- que solo acepta app warehouseMos — llamadas desde el panel MOS (app=MOS) devolvían
-- APP_NO_AUTORIZADA. Se corrigen con la misma lista de apps.

create or replace function wh.guia_set_foto(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id  text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_url text := nullif(btrim(coalesce(p->>'url','')),'');
  v_usr text := coalesce(p->>'usuario','');
begin
  if coalesce(me.jwt_app(),'') not in ('','MOS','warehouseMos') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  -- cambiar el comprobante mueve datos tributarios (OCR → IGV a favor): solo admin/master
  if not mos._rol_precio_ok(v_usr) then
    return jsonb_build_object('ok',false,'error','ROL_NO_AUTORIZADO');
  end if;
  if v_id is null or v_url is null then
    return jsonb_build_object('ok',false,'error','FALTAN_DATOS');
  end if;

  -- el trigger [762] tg_guia_foto_ocr (BEFORE UPDATE OF foto) marca ocr_estado=PENDIENTE solo
  update wh.guias
     set foto = v_url,
         ultima_actividad = now()
   where id_guia = v_id;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'idGuia', v_id, 'foto', v_url, 'ocr', 'PENDIENTE',
    'nota', 'el OCR relee el comprobante en ~10 min'));
end;
$function$;

-- ═══ fix guards [762]: el panel MOS también puede reencolar OCR ═══════════════
create or replace function wh.reencolar_ocr_guia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v_id text := nullif(btrim(coalesce(p->>'idGuia', p->>'id_guia','')),'');
begin
  if coalesce(me.jwt_app(),'') not in ('','MOS','warehouseMos') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;
  update wh.guias set ocr_estado = 'PENDIENTE' where id_guia = v_id and coalesce(foto,'') <> '';
  if not found then return jsonb_build_object('ok',false,'error','Guía sin foto (sube el comprobante primero)'); end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('encolada',true,'nota','el OCR corre en ~10 min'));
end;
$function$;

create or replace function wh.reencolar_ocr_mes(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_mes  int := coalesce((p->>'mes')::int, extract(month from now() at time zone 'America/Lima')::int);
  v_anio int := coalesce((p->>'anio')::int, extract(year  from now() at time zone 'America/Lima')::int);
  v_solo boolean := coalesce((p->>'soloSinProcesar')::boolean, true);
  v_n int;
begin
  if coalesce(me.jwt_app(),'') not in ('','MOS','warehouseMos') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  update wh.guias set ocr_estado = 'PENDIENTE'
   where coalesce(foto,'') <> ''
     and tipo like 'INGRESO%' and tipo <> 'INGRESO_DEVOLUCION_ZONA'
     and extract(month from (fecha at time zone 'America/Lima')) = v_mes
     and extract(year  from (fecha at time zone 'America/Lima')) = v_anio
     and (not v_solo or ocr_estado is null or ocr_estado in ('PENDIENTE','ILEGIBLE'));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('encoladas',v_n,'nota','el cron procesa 3 cada 10 min'));
end;
$function$;

revoke all on function wh.guia_set_foto(jsonb) from public;
grant execute on function wh.guia_set_foto(jsonb) to authenticated, service_role;
