-- 41_wh_get_o_crear_guia_dia.sql — [PASO 4] Pieza de registrar_envasado: reusa la guía del día o crea una.
-- ⚠️ INERTE: flag WH_GET_O_CREAR_GUIA_DIA_DIRECTO. Replica _getOCrearGuiaDia (Envasados.gs): busca guía del
-- tipo con fecha = HOY (TZ Lima, cualquier estado); si no existe, crea una CERRADA sin stock (contenedora).

insert into mos.config (clave, valor, descripcion) values
  ('WH_GET_O_CREAR_GUIA_DIA_DIRECTO','0','WH: get-o-crear guia del dia directo (pieza de registrar_envasado).')
on conflict (clave) do nothing;

create or replace function wh.get_o_crear_guia_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_tipo    text := upper(coalesce(p->>'tipo',''));
  v_usuario text := coalesce(p->>'usuario','');
  v_nuevo   text := nullif(btrim(coalesce(p->>'id_guia_nuevo','')), '');
  v_existe  text;
  v_hoy     date := (now() at time zone 'America/Lima')::date;
begin
  if coalesce((select valor from mos.config where clave='WH_GET_O_CREAR_GUIA_DIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_GET_O_CREAR_GUIA_DIA_DIRECTO_OFF');
  end if;
  if v_tipo not in ('INGRESO_PROVEEDOR','INGRESO_JEFATURA','INGRESO_ENVASADO','INGRESO_DEVOLUCION_ZONA',
                    'SALIDA_DEVOLUCION','SALIDA_ZONA','SALIDA_JEFATURA','SALIDA_ENVASADO','SALIDA_MERMA') then
    return jsonb_build_object('ok',false,'error','TIPO_INVALIDO','tipo',v_tipo);
  end if;

  -- buscar guía del tipo con fecha de HOY (cualquier estado), igual que _getOCrearGuiaDia
  select id_guia into v_existe from wh.guias
   where tipo = v_tipo and (fecha at time zone 'America/Lima')::date = v_hoy
   order by fecha desc limit 1;
  if found then return jsonb_build_object('ok',true,'creada',false,'id_guia',v_existe); end if;

  if v_nuevo is null then return jsonb_build_object('ok',false,'error','FALTA_ID_GUIA_NUEVO'); end if;
  -- crear CERRADA sin stock (contenedora del día; el stock del envasado lo aplican los ajustes aparte)
  insert into wh.guias (id_guia, tipo, fecha, usuario, comentario, monto_total, estado, id_proveedor, id_zona, numero_documento, id_preingreso, foto)
  values (v_nuevo, v_tipo, now(), v_usuario, 'Envasados '||to_char(v_hoy,'YYYY-MM-DD'), 0, 'CERRADA', '', '', '', '', '');
  return jsonb_build_object('ok',true,'creada',true,'id_guia',v_nuevo);
end;
$fn$;

revoke all on function wh.get_o_crear_guia_dia(jsonb) from public;
grant execute on function wh.get_o_crear_guia_dia(jsonb) to service_role;
