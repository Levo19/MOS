-- 605_sombra_antisecuestro_30min.sql — [WH · SOMBRA JALADA SIN ESCANEAR 30 MIN = SE SUELTA SOLA]
-- Pedido del dueño (2026-08-01, tras el candado de Sergio 23h en 0/62): una sombra EN_USO sin
-- ACTIVIDAD (actividad = último escaneo guardado) por más de 30 minutos vuelve a DISPONIBLE
-- automáticamente — el candado no puede secuestrar la lista (misma filosofía que el
-- anti-secuestro 539 de pickups). Los escaneos hechos SE CONSERVAN (el siguiente operador
-- continúa donde quedó; y si el original vuelve, la re-toma normal).
-- El reloj: ultima_actividad (nueva columna) se sella al TOMAR y en CADA guardado de progreso.
-- El cron wh-sombras-vencer pasa de cada hora a CADA 10 MIN para que la regla muerda a los
-- ~30-40 min reales (el TTL 24h y el auto-cierre 604 son idempotentes — correr seguido no daña).

alter table wh.listas_sombra add column if not exists ultima_actividad timestamptz;

-- sellar actividad en cada guardado de progreso (cada escaneo sincronizado)
CREATE OR REPLACE FUNCTION wh.actualizar_progreso_lista_sombra(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id text := nullif(btrim(coalesce(p->>'idLista','')), ''); v_items jsonb := p->'items'; v_n int;
begin
  -- [538] items string → parsear
  if v_items is not null and jsonb_typeof(v_items) = 'string' then
    begin v_items := (p->>'items')::jsonb; exception when others then v_items := null; end;
  end if;
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idLista requerido'); end if;
  if v_items is null or jsonb_typeof(v_items) <> 'array' then return jsonb_build_object('ok',false,'error','items debe ser array'); end if;
  update wh.listas_sombra set items = v_items, ultima_actividad = now() where id_lista = v_id;   -- [605] sella actividad
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok',true);
end;
$function$;

-- sellar actividad al tomar (arranca el reloj de 30 min)
CREATE OR REPLACE FUNCTION wh.tomar_lista_sombra(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id text := nullif(btrim(coalesce(p->>'idLista','')), '');
  v_user text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_forzar boolean := coalesce((p->>'forzar')::boolean, false);
  v_row wh.listas_sombra%rowtype;
begin
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_user is null then return jsonb_build_object('ok',false,'error','idLista y usuario requeridos'); end if;
  select * into v_row from wh.listas_sombra where id_lista = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if upper(coalesce(v_row.estado,'')) = 'COMPLETADA' then return jsonb_build_object('ok',false,'error','YA_COMPLETADA'); end if;
  if upper(coalesce(v_row.estado,'')) = 'EN_USO' and coalesce(btrim(v_row.usuario_tomada),'') <> ''
     and btrim(v_row.usuario_tomada) <> v_user and not v_forzar then
    return jsonb_build_object('ok',false,'error','EN_USO_POR_OTRO','mensaje','Tomada por: '||v_row.usuario_tomada); end if;
  update wh.listas_sombra set estado='EN_USO', usuario_tomada=v_user, fecha_tomada=now(), ultima_actividad=now()   -- [605]
   where id_lista = v_id;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idLista', v_id, 'items', coalesce(v_row.items,'[]'::jsonb), 'dueno', v_user));
end;
$function$;

-- el cron ahora también libera candados fríos (>30 min sin escaneo)
CREATE OR REPLACE FUNCTION wh.vencer_listas_sombra()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row record; v_disp int := 0; v_uso int := 0; v_auto int := 0; v_avis int := 0; v_lib int := 0;
  v_esc numeric; v_esc_items int; v_det jsonb; v_res jsonb; v_guia text; v_twin text;
begin
  -- [605] ANTI-SECUESTRO: EN_USO sin actividad (último escaneo) por 30+ min → DISPONIBLE.
  -- Los escaneos se conservan; solo se suelta el candado. NO aplica a las ya vencidas de 24h
  -- (esas las procesa el bloque TTL de abajo en esta misma corrida).
  update wh.listas_sombra
     set estado = 'DISPONIBLE', usuario_tomada = null, fecha_tomada = null,
         nota = coalesce(nota,'') || ' [605: candado liberado · 30min sin escanear]'
   where upper(coalesce(estado,'')) = 'EN_USO'
     and coalesce(ultima_actividad, fecha_tomada, fecha_creacion) < now() - interval '30 minutes'
     and coalesce(fecha_tomada, fecha_creacion) >= now() - interval '24 hours';
  get diagnostics v_lib = row_count;

  -- [604] ALERTA DE PRE-VENCIMIENTO: sombra viva con 20-24h → push a WH+admins UNA vez.
  for v_row in
    select * from wh.listas_sombra
     where upper(coalesce(estado,'')) in ('DISPONIBLE','EN_USO')
       and coalesce(nota,'') not like '%[aviso-ttl]%'
       and ( (upper(coalesce(estado,'')) = 'DISPONIBLE' and fecha_creacion < now() - interval '20 hours' and fecha_creacion >= now() - interval '24 hours')
          or (upper(coalesce(estado,'')) = 'EN_USO' and coalesce(fecha_tomada, fecha_creacion) < now() - interval '20 hours'
              and coalesce(fecha_tomada, fecha_creacion) >= now() - interval '24 hours') )
     for update skip locked
  loop
    begin
      select coalesce(sum(wh._num(coalesce(it->>'cantidadEscaneada','0'))), 0) into v_esc
        from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) it;
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('apps', jsonb_build_array('warehouseMos'), 'roles', jsonb_build_array('ADMIN','ADMINISTRADOR','MASTER')),
        'titulo', '⏳ Lista sombra por vencer (' || coalesce(v_row.zona,'sin zona') || ')',
        'cuerpo', jsonb_array_length(coalesce(v_row.items,'[]'::jsonb)) || ' productos de ' || coalesce(v_row.usuario_creador,'?') ||
                  case when v_esc > 0 then ' · ' || v_esc || ' uds YA escaneadas (se auto-cerrará con guía)'
                       else ' · sin despachar (se eliminará en ~4h si nadie la atiende)' end,
        'data', jsonb_build_object('tipo','sombra_por_vencer','idLista', v_row.id_lista)));
      update wh.listas_sombra set nota = coalesce(nota,'') || ' [aviso-ttl]' where id_lista = v_row.id_lista;
      v_avis := v_avis + 1;
    exception when others then null;
    end;
  end loop;

  -- [604] TTL 24h
  for v_row in
    select * from wh.listas_sombra
     where (upper(coalesce(estado,'')) = 'DISPONIBLE' and fecha_creacion < now() - interval '24 hours')
        or (upper(coalesce(estado,'')) = 'EN_USO' and coalesce(fecha_tomada, fecha_creacion) < now() - interval '24 hours')
     for update skip locked
  loop
    select coalesce(sum(wh._num(coalesce(it->>'cantidadEscaneada','0'))), 0) into v_esc
      from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) it;

    if v_esc > 0 then
      -- [604b] GUÍA GEMELA: misma zona, posterior a la sombra, mismo total (±0.01) y ±2 líneas → sin guía nueva.
      select count(*) into v_esc_items
        from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) it
       where wh._num(coalesce(it->>'cantidadEscaneada','0')) > 0;
      select g.id_guia into v_twin
        from wh.guias g
       where upper(coalesce(g.id_zona,'')) = upper(coalesce(v_row.zona,''))
         and g.tipo like 'SALIDA%'
         and g.fecha >= v_row.fecha_creacion - interval '1 hour'
         and abs(coalesce((select sum(gd.cant_recibida) from wh.guia_detalle gd where gd.id_guia = g.id_guia), 0) - v_esc) < 0.01
         and abs(coalesce((select count(*) from wh.guia_detalle gd where gd.id_guia = g.id_guia), 0) - v_esc_items) <= 2
       order by g.fecha limit 1;

      -- [604] AUTO-CIERRE COMPLETO — 1) GUÍA por lo escaneado (codigo_barra del canónico por sku_base)
      select coalesce(jsonb_agg(jsonb_build_object(
               'codigo_barra', pr.codigo_barra,
               'cantidad',     wh._num(coalesce(it->>'cantidadEscaneada','0')))), '[]'::jsonb)
        into v_det
        from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) it
        join lateral (
          select p.codigo_barra from mos.productos p
           where p.sku_base = it->>'skuBase'
             and coalesce(btrim(p.codigo_producto_base),'') = ''
             and coalesce(p.factor_conversion, 1) = 1
             and coalesce(btrim(p.codigo_barra),'') <> ''
           order by p.id_producto limit 1) pr on true
       where wh._num(coalesce(it->>'cantidadEscaneada','0')) > 0
         and coalesce(btrim(it->>'skuBase'),'') <> '';

      if v_twin is not null then
        v_det := '[]'::jsonb;   -- gemela detectada → sin guía nueva (solo contabilidad)
      end if;
      if v_det is not null and jsonb_array_length(v_det) > 0 then
        v_guia := 'GLSC_' || v_row.id_lista;
        v_res := wh.crear_despacho_rapido(jsonb_build_object(
          'id_guia',    v_guia,
          'tipo',       'SALIDA_ZONA',
          'id_zona',    coalesce(v_row.zona, ''),
          'usuario',    coalesce(nullif(v_row.usuario_tomada,''), nullif(v_row.usuario_creador,''), 'sistema'),
          'comentario', '[sombra:' || v_row.id_lista || '] auto-cierre TTL (escaneada sin cerrar despacho)',
          'items',      v_det));
        if coalesce((v_res->>'ok'), 'false') <> 'true' then
          continue;   -- guía falló → NO tocar la lista; reintenta el próximo ciclo, sigue visible
        end if;
      end if;

      -- 2) contabilidad al acumulado (misma RPC del cierre normal; usa los items guardados)
      v_res := wh.cerrar_lista_sombra(jsonb_build_object('idLista', v_row.id_lista));
      update wh.listas_sombra
         set nota = coalesce(nota,'') || ' [604: auto-cierre TTL · ' || v_esc || ' uds escaneadas' ||
                    case when v_twin is not null then ' · guía gemela detectada ' || v_twin || ' (sin guía nueva)'
                         when v_det is not null and jsonb_array_length(v_det) > 0 then ' · guía GLSC_' || v_row.id_lista
                         else '' end || ']'
       where id_lista = v_row.id_lista;
      v_auto := v_auto + 1;
    else
      update wh.listas_sombra
         set estado = 'ANULADA', fecha_completada = now(),
             nota = coalesce(nota,'') || case when upper(coalesce(v_row.estado,'')) = 'DISPONIBLE'
                    then ' [vencida: 24h sin despachar]' else ' [vencida: 24h jalada sin cerrar]' end
       where id_lista = v_row.id_lista;
      if upper(coalesce(v_row.estado,'')) = 'DISPONIBLE' then v_disp := v_disp + 1; else v_uso := v_uso + 1; end if;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'vencidasDisponibles', v_disp, 'vencidasEnUso', v_uso,
                            'autoCerradas', v_auto, 'avisadas', v_avis, 'candadosLiberados', v_lib);
end;
$function$;

-- cron cada 10 min (antes cada hora al minuto 20) — la regla de 30 min muerde a los ~30-40 min reales
select cron.unschedule('wh-sombras-vencer') where exists (select 1 from cron.job where jobname='wh-sombras-vencer');
select cron.schedule('wh-sombras-vencer', '*/10 * * * *', $$ select wh.vencer_listas_sombra(); $$);
