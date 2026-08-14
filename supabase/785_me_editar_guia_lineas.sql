-- 785 · ME: editar LÍNEAS de guía desde el historial (14-ago-2026, pedido del dueño).
-- Cambiar cantidad / eliminar producto / agregar producto en una guía ya registrada,
-- con clave admin verificada server-side. MONEY-SAFE:
--   · El stock se mueve por DELTA contra cantidad_aplicada (el mismo modelo del cierre
--     idempotente), con refs de kardex PROPIAS ('EDIT-GUIA:'||opId||':'||linea) porque
--     re-usar las del cierre ('CIERRE-GUIA:...') haría DEDUP y sellaría sin aplicar.
--   · opId (uuid del cliente por guardado) = idempotencia total: un replay/doble-tap
--     re-usa las mismas refs → dedup → no dobla stock.
--   · Línea jamás aplicada (aplicada=0 en guía ABIERTA): solo se edita cantidad; el
--     cierre posterior aplica con sus propias refs (linea nueva ⇒ ref nueva, sin choque).
--   · Guía CERRADA: los deltas se aplican AQUÍ (nadie la va a re-cerrar).
--   · SALIDA_MOVIMIENTO: espejo IN a zona_destino con ref 'EDIT-GUIA-IN:...' (como el cierre).
--   · FEFO/lotes best-effort igual que el cierre (consume en salida positiva; una
--     reducción no restaura lote — misma tolerancia del sistema, kardex+saldo exactos).
-- BLOQUEADAS: SALIDA_VENTAS (stock va por ventas) y ENTRADA_TRASLADO (espejo: se edita
-- la SALIDA_MOVIMIENTO origen).
begin;

-- 1 · zona_guia_detalle ahora incluye `linea` (clave estable para editar). Aditivo.
create or replace function me.zona_guia_detalle(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_id  text := btrim(coalesce(p->>'idGuia', p->>'id_guia',''));
  v_out jsonb;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'linea',      gd.linea,
      'cod_barras', coalesce(gd.cod_barras,''),
      'cantidad',   coalesce(gd.cantidad, 0)
    ) order by gd.linea), '[]'::jsonb)
  into v_out
  from me.guias_detalle gd
  where gd.id_guia = v_id;
  return jsonb_build_object('ok', true, 'items', v_out);
end;
$function$;

-- 2 · La RPC de edición.
create or replace function me.editar_guia_lineas(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_op     text := nullif(btrim(coalesce(p->>'opId','')),'');
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_clave  text := coalesce(p->>'claveAdmin','');
  v_auth   jsonb;
  v_g      me.guias_cabecera%rowtype;
  v_tipo   text; v_zona text; v_zdest text;
  v_cerrada boolean; v_signo_in boolean; v_es_mov boolean;
  v_e      jsonb;
  v_linea  int; v_cb text; v_nueva numeric(20,3); v_apl numeric(20,3);
  v_delta  numeric(20,3); v_signo numeric(20,3);
  v_kres   jsonb; v_dedup boolean; v_fefo jsonb; v_a jsonb;
  v_max    int;
  v_ed int := 0; v_el int := 0; v_ag int := 0;
begin
  if me.jwt_app() not in ('mosExpress','MOS') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_id is null or v_op is null then
    return jsonb_build_object('ok',false,'error','Requiere idGuia y opId');
  end if;

  -- Clave admin server-side (mismo camino que reabrir/anular).
  v_auth := mos.reverificar_clave_admin(v_clave, 'EDITAR_GUIA_LINEAS', v_id, coalesce(me.jwt_app(),'mosExpress'));
  if v_auth is not null and coalesce((v_auth->>'autorizado')::boolean, (v_auth->>'ok')::boolean, false) = false then
    return jsonb_build_object('ok',false,'error', coalesce(v_auth->>'error','Clave admin inválida'));
  end if;

  select * into v_g from me.guias_cabecera where id_guia = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  v_tipo  := upper(coalesce(v_g.tipo,''));
  v_zona  := upper(btrim(coalesce(v_g.zona_id,'')));
  v_zdest := upper(nullif(btrim(coalesce(v_g.zona_destino,'')),''));
  if v_tipo in ('SALIDA_VENTAS','SALIDA_VENTA') then
    return jsonb_build_object('ok',false,'error','GUIA_VENTAS_NO_EDITABLE');
  end if;
  if v_tipo = 'ENTRADA_TRASLADO' then
    return jsonb_build_object('ok',false,'error','ESPEJO_NO_EDITABLE: edita la guía SALIDA_MOVIMIENTO origen');
  end if;
  v_cerrada  := (upper(coalesce(v_g.estado,'')) = 'CERRADA');
  v_signo_in := (v_tipo like 'ENTRADA%');
  v_es_mov   := (v_tipo = 'SALIDA_MOVIMIENTO' and v_zdest is not null);

  -- ── helper inline (bloques repetidos): aplicar delta de stock de una línea ──
  -- (plpgsql sin lambdas: se repite el patrón en EDITAR/ELIMINAR/AGREGAR)

  -- ── EDITAR cantidades ──────────────────────────────────────────────
  for v_e in select * from jsonb_array_elements(coalesce(p->'editar','[]'::jsonb))
  loop
    v_linea := (v_e->>'linea')::int;
    v_nueva := coalesce((v_e->>'cantidad')::numeric, -1);
    if v_linea is null or v_nueva < 0 then continue; end if;
    select cod_barras, coalesce(cantidad_aplicada,0) into v_cb, v_apl
      from me.guias_detalle where id_guia = v_id and linea = v_linea for update;
    if not found then continue; end if;
    v_cb := nullif(btrim(coalesce(v_cb,'')),'');

    if v_cb is not null and (v_cerrada or v_apl <> 0) then
      v_delta := v_nueva - v_apl;
      if v_delta <> 0 then
        v_signo := case when v_signo_in then v_delta else -v_delta end;
        v_kres := me.zona_kardex_registrar(jsonb_build_object(
          'zona', v_zona, 'codBarra', v_cb,
          'tipo', case when v_signo_in then 'TRASLADO_IN' when v_es_mov then 'TRASLADO_OUT' else 'SALIDA_JEFA' end,
          'delta', v_signo, 'refTipo', 'GUIA', 'refId', 'EDIT-GUIA:'||v_op||':'||v_linea,
          'usuario', coalesce('edit-admin:'||v_user,'edit-admin'), 'origen', 'EDIT-LINEAS'));
        v_dedup := coalesce((v_kres->>'dedup')::boolean, false);
        if not v_dedup then
          insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
            values (v_cb, v_zona, v_signo, coalesce('edit-admin:'||v_user,'edit-admin'), now())
          on conflict (cod_barras, zona_id) do update
            set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_signo, fecha_ultimo_registro = now();
          if not v_signo_in and v_delta > 0 then
            begin
              v_fefo := me.zona_consumir_fefo_cod(v_zona, v_cb, v_delta, 'EDIT-GUIA:'||v_op||':'||v_linea);
              if v_es_mov and coalesce((v_fefo->>'ok')::boolean,false) then
                for v_a in select jsonb_array_elements(coalesce(v_fefo->'aplicados','[]'::jsonb)) loop
                  perform me.zona_recibir_lote(jsonb_build_object(
                    'zona', v_zdest, 'skuBase', v_a->>'skuBase',
                    'codBarra', coalesce(nullif(v_a->>'codBarra',''), v_cb),
                    'idLote', v_a->>'idLote', 'fechaVencimiento', v_a->>'fechaVencimiento',
                    'cantidad', (v_a->>'cantidad')::numeric, 'idGuiaOrigen', v_id));
                end loop;
              end if;
            exception when others then null;
            end;
          end if;
          if v_es_mov then
            v_kres := me.zona_kardex_registrar(jsonb_build_object(
              'zona', v_zdest, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN',
              'delta', v_delta, 'refTipo', 'GUIA', 'refId', 'EDIT-GUIA-IN:'||v_op||':'||v_linea,
              'usuario', coalesce('edit-admin:'||v_user,'edit-admin'), 'origen', 'EDIT-LINEAS'));
            if not coalesce((v_kres->>'dedup')::boolean,false) then
              insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
                values (v_cb, v_zdest, v_delta, coalesce('edit-admin:'||v_user,'edit-admin'), now())
              on conflict (cod_barras, zona_id) do update
                set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_delta, fecha_ultimo_registro = now();
            end if;
          end if;
        end if;
      end if;
      update me.guias_detalle set cantidad = v_nueva, cantidad_aplicada = v_nueva
        where id_guia = v_id and linea = v_linea;
    else
      -- nunca aplicada y guía abierta → solo el número; el cierre aplicará.
      update me.guias_detalle set cantidad = v_nueva where id_guia = v_id and linea = v_linea;
    end if;
    v_ed := v_ed + 1;
  end loop;

  -- ── ELIMINAR líneas ────────────────────────────────────────────────
  for v_e in select * from jsonb_array_elements(coalesce(p->'eliminar','[]'::jsonb))
  loop
    v_linea := (v_e)::text::int;
    if v_linea is null then continue; end if;
    select cod_barras, coalesce(cantidad_aplicada,0) into v_cb, v_apl
      from me.guias_detalle where id_guia = v_id and linea = v_linea for update;
    if not found then continue; end if;
    v_cb := nullif(btrim(coalesce(v_cb,'')),'');
    if v_cb is not null and v_apl <> 0 then
      v_delta := -v_apl;                                          -- reversa total de lo aplicado
      v_signo := case when v_signo_in then v_delta else -v_delta end;
      v_kres := me.zona_kardex_registrar(jsonb_build_object(
        'zona', v_zona, 'codBarra', v_cb,
        'tipo', case when v_signo_in then 'TRASLADO_IN' when v_es_mov then 'TRASLADO_OUT' else 'SALIDA_JEFA' end,
        'delta', v_signo, 'refTipo', 'GUIA', 'refId', 'EDIT-GUIA:'||v_op||':DEL'||v_linea,
        'usuario', coalesce('edit-admin:'||v_user,'edit-admin'), 'origen', 'EDIT-LINEAS'));
      if not coalesce((v_kres->>'dedup')::boolean,false) then
        insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
          values (v_cb, v_zona, v_signo, coalesce('edit-admin:'||v_user,'edit-admin'), now())
        on conflict (cod_barras, zona_id) do update
          set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_signo, fecha_ultimo_registro = now();
        if v_es_mov then
          v_kres := me.zona_kardex_registrar(jsonb_build_object(
            'zona', v_zdest, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN',
            'delta', v_delta, 'refTipo', 'GUIA', 'refId', 'EDIT-GUIA-IN:'||v_op||':DEL'||v_linea,
            'usuario', coalesce('edit-admin:'||v_user,'edit-admin'), 'origen', 'EDIT-LINEAS'));
          if not coalesce((v_kres->>'dedup')::boolean,false) then
            insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
              values (v_cb, v_zdest, v_delta, coalesce('edit-admin:'||v_user,'edit-admin'), now())
            on conflict (cod_barras, zona_id) do update
              set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_delta, fecha_ultimo_registro = now();
          end if;
        end if;
      end if;
    end if;
    delete from me.guias_detalle where id_guia = v_id and linea = v_linea;
    v_el := v_el + 1;
  end loop;

  -- ── AGREGAR productos ─────────────────────────────────────────────
  for v_e in select * from jsonb_array_elements(coalesce(p->'agregar','[]'::jsonb))
  loop
    v_cb    := nullif(btrim(coalesce(v_e->>'codBarras', v_e->>'cod_barras','')),'');
    v_nueva := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb is null or v_nueva <= 0 then continue; end if;
    select coalesce(max(linea),0) + 1 into v_max from me.guias_detalle where id_guia = v_id;
    insert into me.guias_detalle (id_guia, linea, cod_barras, cantidad, cantidad_aplicada)
      values (v_id, v_max, v_cb, v_nueva, 0);
    if v_cerrada then
      v_delta := v_nueva;
      v_signo := case when v_signo_in then v_delta else -v_delta end;
      v_kres := me.zona_kardex_registrar(jsonb_build_object(
        'zona', v_zona, 'codBarra', v_cb,
        'tipo', case when v_signo_in then 'TRASLADO_IN' when v_es_mov then 'TRASLADO_OUT' else 'SALIDA_JEFA' end,
        'delta', v_signo, 'refTipo', 'GUIA', 'refId', 'EDIT-GUIA:'||v_op||':ADD'||v_max,
        'usuario', coalesce('edit-admin:'||v_user,'edit-admin'), 'origen', 'EDIT-LINEAS'));
      if not coalesce((v_kres->>'dedup')::boolean,false) then
        insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
          values (v_cb, v_zona, v_signo, coalesce('edit-admin:'||v_user,'edit-admin'), now())
        on conflict (cod_barras, zona_id) do update
          set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_signo, fecha_ultimo_registro = now();
        if not v_signo_in then
          begin
            v_fefo := me.zona_consumir_fefo_cod(v_zona, v_cb, v_delta, 'EDIT-GUIA:'||v_op||':ADD'||v_max);
            if v_es_mov and coalesce((v_fefo->>'ok')::boolean,false) then
              for v_a in select jsonb_array_elements(coalesce(v_fefo->'aplicados','[]'::jsonb)) loop
                perform me.zona_recibir_lote(jsonb_build_object(
                  'zona', v_zdest, 'skuBase', v_a->>'skuBase',
                  'codBarra', coalesce(nullif(v_a->>'codBarra',''), v_cb),
                  'idLote', v_a->>'idLote', 'fechaVencimiento', v_a->>'fechaVencimiento',
                  'cantidad', (v_a->>'cantidad')::numeric, 'idGuiaOrigen', v_id));
              end loop;
            end if;
          exception when others then null;
          end;
        end if;
        if v_es_mov then
          v_kres := me.zona_kardex_registrar(jsonb_build_object(
            'zona', v_zdest, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN',
            'delta', v_delta, 'refTipo', 'GUIA', 'refId', 'EDIT-GUIA-IN:'||v_op||':ADD'||v_max,
            'usuario', coalesce('edit-admin:'||v_user,'edit-admin'), 'origen', 'EDIT-LINEAS'));
          if not coalesce((v_kres->>'dedup')::boolean,false) then
            insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
              values (v_cb, v_zdest, v_delta, coalesce('edit-admin:'||v_user,'edit-admin'), now())
            on conflict (cod_barras, zona_id) do update
              set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_delta, fecha_ultimo_registro = now();
          end if;
        end if;
      end if;
      update me.guias_detalle set cantidad_aplicada = v_nueva where id_guia = v_id and linea = v_max;
    end if;
    v_ag := v_ag + 1;
  end loop;

  update me.guias_cabecera set ultima_actividad = now() where id_guia = v_id;

  return jsonb_build_object('ok', true, 'idGuia', v_id, 'estado', v_g.estado,
    'editadas', v_ed, 'eliminadas', v_el, 'agregadas', v_ag);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM, 'idGuia', v_id);
end;
$function$;

revoke all on function me.editar_guia_lineas(jsonb) from public;
grant execute on function me.editar_guia_lineas(jsonb) to authenticated, service_role;

commit;
