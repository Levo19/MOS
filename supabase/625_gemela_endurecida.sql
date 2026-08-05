CREATE OR REPLACE FUNCTION wh.vencer_listas_sombra()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row record; v_disp int := 0; v_uso int := 0; v_auto int := 0; v_avis int := 0; v_lib int := 0;
  v_esc numeric; v_esc_items int; v_det jsonb; v_res jsonb; v_guia text; v_twin text;
  v_cand int := 0;      -- [625] cuántas guías compiten por ser la gemela
  v_faltan int := 0;    -- [625] líneas escaneadas que no resuelven su código de barra
  v_nota_extra text := '';
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
      -- [625] ventana ACOTADA por arriba (antes sólo tenía piso: cualquier guía futura
      -- casaba), sin anuladas (no descontaron) y sin las GLSC_ de otras sombras.
      select count(*), min(g.id_guia) into v_cand, v_twin
        from wh.guias g
       where upper(coalesce(g.id_zona,'')) = upper(coalesce(v_row.zona,''))
         and g.tipo like 'SALIDA%'
         and g.fecha >= v_row.fecha_creacion - interval '1 hour'
         and g.fecha <= v_row.fecha_creacion + interval '26 hours'
         and upper(coalesce(g.estado,'')) <> 'ANULADA'
         and g.id_guia not like 'GLSC\_%'
         and abs(coalesce((select sum(gd.cant_recibida) from wh.guia_detalle gd where gd.id_guia = g.id_guia), 0) - v_esc) < 0.01
         and abs(coalesce((select count(*) from wh.guia_detalle gd where gd.id_guia = g.id_guia), 0) - v_esc_items) <= 2;
      if v_cand = 0 then v_twin := null; end if;

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

      -- [625] líneas escaneadas que se caerían de la guía por no resolver su canónico.
      -- Emitir la guía igual dejaría un descuento PARCIAL con la sombra cerrada como
      -- completa: preferimos no emitir y que quede constancia para revisión.
      select count(*) into v_faltan
        from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) it
       where wh._num(coalesce(it->>'cantidadEscaneada','0')) > 0
         and coalesce(btrim(it->>'skuBase'),'') <> ''
         and not exists (select 1 from mos.productos p
                          where p.sku_base = it->>'skuBase'
                            and coalesce(btrim(p.codigo_producto_base),'') = ''
                            and coalesce(p.factor_conversion, 1) = 1
                            and coalesce(btrim(p.codigo_barra),'') <> '');

      if v_twin is not null then
        v_det := '[]'::jsonb;   -- gemela detectada → sin guía nueva (solo contabilidad)
        if v_cand > 1 then
          v_nota_extra := v_nota_extra || ' · AMBIGUO: ' || v_cand || ' guías posibles, no se emitió guía (revisar)';
          begin
            insert into wh.ops_log (id_op, id_guia, tipo, payload, estado, usuario, fecha_creado, error)
            values ('GEM-AMB-'||v_row.id_lista||'-'||(extract(epoch from now())*1000)::bigint,
                    v_row.id_lista, 'SOMBRA_GEMELA_AMBIGUA',
                    jsonb_build_object('idLista',v_row.id_lista,'zona',v_row.zona,'candidatas',v_cand,
                                       'elegida',v_twin,'uds',v_esc),
                    'REVISAR', coalesce(v_row.usuario_tomada, v_row.usuario_creador,'sistema'), now(),
                    v_cand||' guías compiten como gemela; no se emitió guía para no descontar dos veces');
          exception when others then null; end;
        end if;
      elsif v_faltan > 0 then
        v_det := '[]'::jsonb;   -- guía saldría incompleta → no emitir
        v_nota_extra := v_nota_extra || ' · ' || v_faltan || ' líneas sin código de barra: NO se emitió guía (descuento pendiente)';
        begin
          insert into wh.ops_log (id_op, id_guia, tipo, payload, estado, usuario, fecha_creado, error)
          values ('GEM-PARC-'||v_row.id_lista||'-'||(extract(epoch from now())*1000)::bigint,
                  v_row.id_lista, 'SOMBRA_GUIA_PARCIAL',
                  jsonb_build_object('idLista',v_row.id_lista,'zona',v_row.zona,'lineasSinCodigo',v_faltan,'uds',v_esc),
                  'REVISAR', coalesce(v_row.usuario_tomada, v_row.usuario_creador,'sistema'), now(),
                  v_faltan||' líneas escaneadas no resuelven código de barra: la guía habría descontado de menos');
        exception when others then null; end;
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
                         else '' end || v_nota_extra || ']'
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
$function$
