-- [970] CAUSA RAÍZ del "+1 vs 122.6": al editar la cantidad de una guía CERRADA, wh.actualizar_cantidad_detalle
--  SÍ mueve wh.stock y SÍ escribe wh.ajustes, pero el movimiento en wh.stock_movimientos estaba CONDICIONADO a
--  que el front mandara `id_mov` (p->>'id_mov'). El front no lo manda → el stock quedó correcto pero el KARDEX
--  no registró el ajuste → el historial se ve incompleto (ingreso "+1") y el reconstructor mete un "cuadre"
--  grande. 82 ediciones quedaron sin su movimiento. Fix: SIEMPRE registrar el movimiento, con id determinista
--  derivado del ajuste (idempotente ante reintento). NO cambia stock (ya estaba bien) — solo completa el log.
create or replace function wh.actualizar_cantidad_detalle(p jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_iddet   text := nullif(btrim(coalesce(p->>'id_detalle','')), '');
  v_cant    numeric := wh._num(p->>'cantidad_recibida');
  v_cant_in text := nullif(btrim(coalesce(p->>'cantidad_recibida','')), '');
  v_usuario text := coalesce(p->>'usuario','');
  v_idmov   text := nullif(btrim(coalesce(p->>'id_mov','')), '');
  v_idlnew  text := nullif(btrim(coalesce(p->>'id_lote_nuevo','')), '');
  v_idaj    text := nullif(btrim(coalesce(p->>'id_ajuste','')), '');
  v_lid     text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_guia    text; v_linea int; v_cant_vieja numeric; v_cod text; v_obs text;
  v_idlote  text; v_fvenc date;
  v_estado  text; v_tipo text; v_cerrada boolean; v_ingreso boolean; v_envasado boolean;
  v_diff numeric; v_delta numeric; v_antes numeric; v_despues numeric;
  v_movfin  text;   -- [970] id_mov efectivo (del front o determinista)
begin
  if coalesce((select valor from mos.config where clave='WH_ACTUALIZAR_CANTIDAD_DETALLE_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ACTUALIZAR_CANTIDAD_DETALLE_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_lid is not null and not wh._dedup_nuevo(v_lid, 'actualizar_cantidad_detalle') then
    return jsonb_build_object('ok',true,'dedup',true);
  end if;
  if v_iddet is null or v_cant_in is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_lid is null then return jsonb_build_object('ok',false,'error','FALTA_LOCAL_ID'); end if;

  select id_guia, linea, coalesce(cant_recibida,0), coalesce(cod_producto,''), upper(coalesce(observacion,'')),
         coalesce(id_lote,''), fecha_vencimiento
    into v_guia, v_linea, v_cant_vieja, v_cod, v_obs, v_idlote, v_fvenc
    from wh.guia_detalle where id_detalle = v_iddet order by id_guia, linea limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','DETALLE_NO_ENCONTRADO'); end if;

  select upper(coalesce(estado,'')), upper(coalesce(tipo,'')) into v_estado, v_tipo
    from wh.guias where id_guia = v_guia limit 1;
  v_cerrada  := v_estado = 'CERRADA';
  v_ingreso  := v_tipo like 'INGRESO%';
  v_envasado := v_tipo in ('INGRESO_ENVASADO','SALIDA_ENVASADO');

  if v_cerrada and not v_envasado and v_cod <> '' then
    v_diff := v_cant - v_cant_vieja;
    if v_diff <> 0 then
      v_delta := case when v_ingreso then v_diff else -v_diff end;
      update wh.stock set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = now()
       where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
       returning cantidad_disponible into v_despues;
      if found then v_antes := v_despues - v_delta;
      else v_antes := 0; v_despues := v_delta;
        insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
        values ('STK'||v_guia||'_'||v_cod, v_cod, v_despues, now());
      end if;
      insert into wh.ajustes (id_ajuste, cod_producto, tipo_ajuste, cantidad_ajuste, motivo, usuario, id_auditoria, fecha)
      values (coalesce(v_idaj, 'AJ_'||v_lid), v_cod, case when v_delta>0 then 'INC' else 'DEC' end, abs(v_delta),
              'Edición cantidad guía cerrada · idGuia=' || v_guia || ' · detalle=' || v_iddet || ' · ' ||
                rtrim(rtrim(to_char(v_cant_vieja,'FM999999990.######'),'0'),'.') || '→' ||
                rtrim(rtrim(to_char(v_cant,'FM999999990.######'),'0'),'.') || 'u',
              v_usuario, '', now())
      on conflict (id_ajuste) do nothing;
      -- [970] SIEMPRE registrar el movimiento (antes: solo si el front mandaba id_mov → 82 ediciones sin log).
      --   id determinista = el del front, o derivado del ajuste (idempotente). Paridad con crearAjuste→_actualizarStock.
      v_movfin := coalesce(v_idmov, 'MOVAJ_'||coalesce(v_idaj, 'AJ_'||v_lid));
      insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
      values (v_movfin, now(), v_cod, v_delta, v_antes, v_despues, 'AJUSTE_MANUAL', v_iddet, coalesce(nullif(v_usuario,''),'edición-cantidad'))
      on conflict (id_mov) do nothing;
    end if;
  end if;

  update wh.guia_detalle
     set cant_recibida = v_cant,
         observacion   = case when v_obs = 'ANULADO' and v_cant > 0 then '' else observacion end
   where id_guia = v_guia and linea = v_linea;

  if v_cerrada and v_fvenc is not null and v_cod <> '' then
    perform wh._sync_lote_desde_detalle(v_idlote, v_cod, v_cant, to_char(v_fvenc,'YYYY-MM-DD'), v_guia, v_idlnew);
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'id_guia',v_guia,'linea',v_linea,'aplico_stock',(v_cerrada and not v_envasado));
end;
$function$;

select '970 actualizar_cantidad_detalle SIEMPRE loguea movimiento listo' as ok;
