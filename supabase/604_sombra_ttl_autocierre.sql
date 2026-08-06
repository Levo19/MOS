-- 604_sombra_ttl_autocierre.sql — [WH · SOMBRA VENCIDA CON ESCANEOS = AUTO-CIERRE COMPLETO]
-- Decisión del dueño (2026-08-01): una sombra escaneada a medias y abandonada NO muere al
-- vencer el TTL de 24h — lo escaneado ES despacho real: (1) se genera la GUÍA de salida por lo
-- escaneado (id determinista GLSC_<lista> → un reintento del cron jamás duplica stock),
-- (2) la contabilidad entra al acumulado con la fórmula 540 (deuda = max(0, deuda + pedido −
-- despachado)) vía cerrar_lista_sombra (idempotente, PCK-LSC). Las sombras con CERO escaneos
-- siguen anulándose sin acumular (subida/escaneo errado — regla del 22/07, intacta).
-- Si la GUÍA falla (p.ej. catálogo no resuelve), la lista NO se toca: reintenta el próximo
-- ciclo del cron (cada hora) y sigue visible para que un humano la cierre.

CREATE OR REPLACE FUNCTION wh.vencer_listas_sombra()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row record; v_disp int := 0; v_uso int := 0; v_auto int := 0; v_avis int := 0;
  v_esc numeric; v_esc_items int; v_det jsonb; v_res jsonb; v_guia text; v_twin text;
begin
  -- [604] ALERTA DE PRE-VENCIMIENTO (pedido del dueño): sombra viva con 20-24h → push a WH+admins
  -- ("por vencer") UNA sola vez (marca [aviso-ttl] en la nota). Da 4h de ventana humana antes del TTL.
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
    exception when others then null;   -- el aviso jamás rompe el cron
    end;
  end loop;

  for v_row in
    select * from wh.listas_sombra
     where (upper(coalesce(estado,'')) = 'DISPONIBLE' and fecha_creacion < now() - interval '24 hours')
        or (upper(coalesce(estado,'')) = 'EN_USO' and coalesce(fecha_tomada, fecha_creacion) < now() - interval '24 hours')
     for update skip locked
  loop
    select coalesce(sum(wh._num(coalesce(it->>'cantidadEscaneada','0'))), 0) into v_esc
      from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) it;

    if v_esc > 0 then
      -- [604b] GUÍA GEMELA (caso real LS1785522660160/G_L1785526158074): el operador escaneó la sombra
      -- y despachó por el flujo normal (guía YA emitida) pero el cierre contable nunca llegó. Si existe
      -- una SALIDA a la MISMA zona, posterior a la creación de la sombra, con el MISMO total de unidades
      -- (±0.01) y ±2 líneas → NO crear otra guía (sería doble descuento); solo contabilizar.
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

  return jsonb_build_object('ok', true, 'vencidasDisponibles', v_disp, 'vencidasEnUso', v_uso, 'autoCerradas', v_auto, 'avisadas', v_avis);
end;
$function$;
