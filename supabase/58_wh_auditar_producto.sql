-- 58_wh_auditar_producto.sql — [PASO 5 · B4] Orquestador ATÓMICO de auditoría (resuelve HALLAZGO 40x #4).
-- auditar_producto hace auditoría EJECUTADA + ajuste de stock por la diferencia EN UNA SOLA TRANSACCIÓN (atómico,
-- no componible en cliente que no es atómico bajo fallo parcial). Replica _auditarProductoImpl (Productos.gs):
--   diff = stock_fisico - stock_sistema; resultado OK si |diff|<=0.5; si difiere → ajusta stock al físico (INC/DEC).
-- Idempotente por id_auditoria. UPDATE atómico de stock (cantidad += delta). Gate wh._claim_ok(). INERTE (flag).

insert into mos.config (clave, valor, descripcion) values
  ('WH_AUDITAR_PRODUCTO_DIRECTO','0','WH: auditar producto directo (orquestador atomico auditoria+ajuste).')
on conflict (clave) do nothing;

create or replace function wh.auditar_producto(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_cod     text := nullif(btrim(coalesce(p->>'codigo_barra', p->>'codigo_producto', '')), '');
  v_fisico  numeric := wh._num(p->>'stock_fisico');
  v_usuario text := coalesce(p->>'usuario','');
  v_obs     text := coalesce(p->>'observacion','');
  v_idaud   text := nullif(btrim(coalesce(p->>'id_auditoria','')), '');
  v_idaj    text := nullif(btrim(coalesce(p->>'id_ajuste','')), '');
  v_idstk   text := nullif(btrim(coalesce(p->>'id_stock_nuevo','')), '');
  v_idmov   text := nullif(btrim(coalesce(p->>'id_mov','')), '');
  v_sistema numeric; v_diff numeric; v_result text;
  v_delta numeric; v_antes numeric; v_despues numeric;
begin
  if coalesce((select valor from mos.config where clave='WH_AUDITAR_PRODUCTO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_AUDITAR_PRODUCTO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_cod is null or v_idaud is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_fisico < 0 then return jsonb_build_object('ok',false,'error','STOCK_FISICO_INVALIDO'); end if;

  -- idempotencia ATÓMICA por id_auditoria (dedup vía sync_directo: el insert-on-conflict toma el lock de la PK y
  -- serializa reintentos concurrentes — a diferencia de `if exists` que es un read sin lock con race). HALLAZGO 40x #1.
  if not wh._dedup_nuevo(v_idaud, 'auditar_producto') then
    return jsonb_build_object('ok',true,'dedup',true,'id_auditoria',v_idaud);
  end if;

  -- FOR UPDATE: lockea la fila de stock para que dos auditorías concurrentes del mismo producto NO calculen el ajuste
  -- sobre un v_sistema stale (lost-update lógico: la 2ª pisaría el ajuste de la 1ª). HALLAZGO 40x #1 (parte 2).
  select cantidad_disponible into v_sistema from wh.stock where cod_producto = v_cod order by id_stock limit 1 for update;
  v_sistema := coalesce(v_sistema, 0);
  v_diff := v_fisico - v_sistema;
  v_result := case when abs(v_diff) <= 0.5 then 'OK' else 'DIFERENCIA' end;

  insert into wh.auditorias (id_auditoria, fecha_asignacion, cod_producto, usuario, stock_sistema, stock_fisico,
    diferencia, resultado, observacion, estado, fecha_ejecucion)
  values (v_idaud, now(), v_cod, v_usuario, v_sistema, v_fisico, v_diff, v_result, v_obs, 'EJECUTADA', now());

  if abs(v_diff) > 0.5 then
    v_delta := v_diff;   -- llevar el stock al físico contado
    update wh.stock set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = now()
     where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
     returning cantidad_disponible into v_despues;
    if found then v_antes := v_despues - v_delta;
    else v_antes := 0; v_despues := v_delta;
      insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
      values (coalesce(v_idstk, 'STK'||v_idaud), v_cod, v_despues, now());
    end if;
    insert into wh.ajustes (id_ajuste, cod_producto, tipo_ajuste, cantidad_ajuste, motivo, usuario, id_auditoria, fecha)
    values (coalesce(v_idaj,'AJ'||v_idaud), v_cod, case when v_diff > 0 then 'INC' else 'DEC' end, abs(v_diff),
      'Auditoria: fisico='||v_fisico||' sistema='||v_sistema, v_usuario, v_idaud, now());
    if v_idmov is not null then
      insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
      values (v_idmov, now(), v_cod, v_delta, v_antes, v_despues, 'AUDITORIA', v_idaud, v_usuario)
      on conflict (id_mov) do nothing;
    end if;
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'id_auditoria',v_idaud,'diferencia',v_diff,'resultado',v_result,'ajusto',abs(v_diff) > 0.5);
end;
$fn$;

revoke all on function wh.auditar_producto(jsonb) from public;
grant execute on function wh.auditar_producto(jsonb) to service_role, authenticated;
