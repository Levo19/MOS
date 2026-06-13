-- 43_wh_agregar_detalle_guia.sql — [PASO 4] Agregar línea a una guía (la pieza compleja). INERTE.
-- ⚠️ flag WH_AGREGAR_DETALLE_GUIA_DIRECTO. Replica _agregarDetalleGuiaImpl (Guias.gs):
--   · AUTO-SUMA: si ya existe línea (id_guia + cod, no ANULADO) → suma cant_recibida; sino INSERT con linea=max+1.
--   · Si la guía está CERRADA/AUTOCERRADA → ajusta stock por el delta (atómico) + movimiento + sync lote (INGRESO+fecha).
-- El cliente resuelve el cod contra el catálogo (cache) y pasa id_detalle (+ id_lote_nuevo/id_mov para idempotencia).
-- A guía ABIERTA: solo registra la línea (el stock/lotes se aplican al cerrar vía wh.cerrar_guia).

insert into mos.config (clave, valor, descripcion) values
  ('WH_AGREGAR_DETALLE_GUIA_DIRECTO','0','WH: agregar detalle de guia directo (pieza de recepcion/envasado).')
on conflict (clave) do nothing;

create or replace function wh.agregar_detalle_guia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_guia    text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_cod     text := nullif(btrim(coalesce(p->>'codigo_producto','')), '');
  v_iddet   text := coalesce(p->>'id_detalle','');
  v_idlote  text := coalesce(p->>'id_lote','');
  v_idlnew  text := nullif(btrim(coalesce(p->>'id_lote_nuevo','')), '');
  v_obs     text := coalesce(p->>'observacion','');
  v_fvenc   text := nullif(btrim(coalesce(p->>'fecha_vencimiento','')), '');
  v_idmov   text := nullif(btrim(coalesce(p->>'id_mov','')), '');
  v_cesp    numeric := wh._num(p->>'cantidad_esperada');
  v_crec    numeric := wh._num(p->>'cantidad_recibida');
  v_precio  numeric := wh._num(p->>'precio_unitario');
  v_estado  text; v_tipo text; v_cerrada boolean; v_ingreso boolean;
  v_linea   int; v_qty_ant numeric; v_accion text;
  v_delta numeric; v_antes numeric; v_despues numeric; v_reuse text;
begin
  if coalesce((select valor from mos.config where clave='WH_AGREGAR_DETALLE_GUIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_AGREGAR_DETALLE_GUIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_guia is null or v_cod is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_cesp < 0 or v_crec < 0 then return jsonb_build_object('ok',false,'error','CANTIDAD_NEGATIVA'); end if;
  if v_fvenc is not null then v_fvenc := left(v_fvenc,10); end if;

  select estado, tipo into v_estado, v_tipo from wh.guias where id_guia = v_guia limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;
  v_cerrada := upper(coalesce(v_estado,'')) in ('CERRADA','AUTOCERRADA');
  v_ingreso := upper(coalesce(v_tipo,'')) like 'INGRESO%';

  -- AUTO-SUMA: línea existente (mismo cod, no ANULADO) → suma; sino INSERT con linea=max+1
  select linea, cant_recibida into v_linea, v_qty_ant from wh.guia_detalle
   where id_guia = v_guia and upper(cod_producto) = upper(v_cod) and upper(coalesce(observacion,'')) <> 'ANULADO'
   order by linea limit 1;
  if found then
    update wh.guia_detalle
       set cant_recibida = coalesce(v_qty_ant,0) + v_crec,
           id_lote = case when v_idlote <> '' then v_idlote else id_lote end,
           fecha_vencimiento = case when v_fvenc is not null then v_fvenc::date else fecha_vencimiento end
     where id_guia = v_guia and linea = v_linea;
    v_accion := 'AUTOSUMA';
  else
    select coalesce(max(linea),0)+1 into v_linea from wh.guia_detalle where id_guia = v_guia;
    insert into wh.guia_detalle (id_guia, linea, cod_producto, cant_esperada, cant_recibida, precio_unitario,
      id_lote, observacion, id_producto_nuevo, id_detalle, fecha_vencimiento)
    values (v_guia, v_linea, v_cod, v_cesp, v_crec, v_precio, coalesce(v_idlote,''), v_obs, '', v_iddet,
      case when v_fvenc is not null then v_fvenc::date else null end);
    v_accion := 'INSERT';
  end if;

  -- Si la guía YA está cerrada: aplicar el delta al stock (atómico) + movimiento + lote (igual que GAS).
  -- Guía ABIERTA: NO se toca stock/lote acá (se aplica al cerrar vía wh.cerrar_guia).
  if v_cerrada and v_crec <> 0 then
    v_delta := case when v_ingreso then v_crec else -v_crec end;
    update wh.stock set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = now()
     where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
     returning cantidad_disponible into v_despues;
    if found then v_antes := v_despues - v_delta;
    else v_antes := 0; v_despues := v_delta;
      insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
      values ('STK'||v_guia||'_'||v_cod, v_cod, v_despues, now());
    end if;
    if v_idmov is not null then
      insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
      values (v_idmov, now(), v_cod, v_delta, v_antes, v_despues, 'AGREGAR_DETALLE', v_guia, coalesce(p->>'usuario',''))
      on conflict (id_mov) do nothing;
    end if;
    -- lote: INGRESO con fecha → REUSE (cod,guia,fecha) o INSERT
    if v_ingreso and v_fvenc is not null then
      select id_lote into v_reuse from wh.lotes_vencimiento
       where upper(cod_producto)=upper(v_cod) and id_guia=v_guia and fecha_vencimiento=v_fvenc::date limit 1;
      if v_reuse is not null then
        update wh.lotes_vencimiento set cantidad_inicial=v_crec, cantidad_actual=v_crec, estado='ACTIVO' where id_lote=v_reuse;
      elsif v_idlnew is not null then
        insert into wh.lotes_vencimiento (id_lote, cod_producto, fecha_vencimiento, cantidad_inicial, cantidad_actual, id_guia, estado, fecha_creacion)
        values (v_idlnew, v_cod, v_fvenc::date, v_crec, v_crec, v_guia, 'ACTIVO', now());
      end if;
    end if;
  end if;

  return jsonb_build_object('ok',true,'accion',v_accion,'id_guia',v_guia,'linea',v_linea,'aplico_stock',v_cerrada);
end;
$fn$;

revoke all on function wh.agregar_detalle_guia(jsonb) from public;
grant execute on function wh.agregar_detalle_guia(jsonb) to service_role, authenticated;
