-- 152_wh_fix_doble_conteo_cierre_reapertura.sql
-- ============================================================
-- [MONEY-CRITICAL · FIX DOBLE-CONTEO DE INVENTARIO en cierre/reapertura de guías]
--
-- BUG (auditoría 50x · LATENTE pero ALCANZABLE):
--   Había TRES rutas de cierre/reapertura con semántica inconsistente:
--     1. PWA cerrarGuia → wh.cerrar_guia(p jsonb): movía stock pero NO seteaba
--        wh.guia_detalle.cantidad_aplicada (quedaba 0) y escribía kardex por id_mov
--        que el front no manda → guías cerradas por PWA quedaban con aplicada=0.
--     2. GAS + cron autocierre → wh.cerrar_guia_idempotente(text): delta =
--        cant_recibida − cantidad_aplicada, SETEA cantidad_aplicada, kardex único
--        por (guia,linea). (correcta)
--     3. PWA reabrirGuia → wh.reabrir_guia(p jsonb): sin 'detalles' no revierte
--        stock NI resetea cantidad_aplicada; solo pone ABIERTA.
--
--   CAMINO AL DOBLE-CONTEO: guía cerrada por PWA (aplicada=0, stock ya aplicado)
--   → reabierta por PWA (no revierte, aplicada SIGUE 0) → a los 30 min el cron de
--   inactividad la toma (estado ABIERTA) → cerrar_guia_idempotente calcula
--   delta = cant_recibida − 0 = TOTAL → RE-APLICA el stock completo = DOBLE CONTEO.
--
-- FIX (una sola semántica idempotente y coherente):
--   A. wh.cerrar_guia_idempotente(text): se vuelve la ÚNICA verdad del stock.
--      Se le AGREGA gate wh._claim_ok() (consistencia con el resto de RPCs de
--      dinero: pasa para token WH y para service_role/cron donde jwt_app()='').
--      Se le AGREGA grant EXECUTE a authenticated (la PWA va como authenticated).
--      Lógica de delta/kardex/cantidad_aplicada SIN cambios (ya era correcta).
--   B. wh.cerrar_guia(p jsonb): DEPRECADA. Ya no mueve stock por su cuenta; tras
--      el lock/idempotencia DELEGA en cerrar_guia_idempotente (lee guia_detalle,
--      setea cantidad_aplicada, kardex único). Así cualquier caller viejo (PWA
--      antes del deploy, cola offline con payload viejo) queda BLINDADO contra el
--      doble-conteo. Sigue devolviendo {ok,estado,montoTotal,...} compatible.
--   C. wh.reabrir_guia(p jsonb): coherente con el modelo idempotente. INVARIANTE:
--      reabrir NUNCA toca stock y NUNCA resetea cantidad_aplicada. Tras un cierre
--      idempotente cantidad_aplicada = cant_recibida → si se recierra sin editar,
--      delta = cant_recibida − cant_recibida = 0 → NO re-aplica (no dobla). Si se
--      EDITAN cantidades estando ABIERTA, el recierre aplica solo el delta de la
--      edición (correcto). Se ELIMINA la rama de "revertir stock por detalles"
--      (era dead code peligroso: revertía stock pero dejaba aplicada intacta →
--      recierre delta 0 → stock revertido y NUNCA re-aplicado = pérdida de stock).
--
-- INVARIANTE GLOBAL (en piedra):
--   cantidad_aplicada = unidades que YA impactaron el stock por esa línea.
--   * cerrar  → aplica (cant_recibida − cantidad_aplicada) y setea aplicada=cant_recibida.
--   * reabrir → NO toca stock, NO toca cantidad_aplicada (solo estado=ABIERTA).
--   * recerrar (sin editar) → delta 0 → no-op de stock/kardex.
--   * editar líneas ABIERTA + recerrar → aplica solo el delta editado.
--   Resultado: cualquier ciclo cerrar→reabrir→(auto)recerrar = el stock de UN
--   solo cierre, kardex sin duplicar (id_mov = 'MOVID_'||id_guia||'#'||linea).
--
-- SEGURIDAD: no destructivo (solo redefine 3 funciones + 1 grant). Idempotente
--   (re-correr es no-op). No toca flags de sync. No toca datos.
-- ============================================================

-- ── A. cerrar_guia_idempotente: + gate _claim_ok, + grant authenticated ──
create or replace function wh.cerrar_guia_idempotente(p_id_guia text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id        text := nullif(btrim(coalesce(p_id_guia,'')), '');
  v_estado    text;
  v_tipo      text;
  v_ingreso   boolean;
  v_envasado  boolean;
  v_monto     numeric := 0;
  v_d         record;
  v_cod       text;
  v_cant      numeric;
  v_apl       numeric;
  v_delta     numeric;   -- cant_recibida − cantidad_aplicada (lo que falta aplicar)
  v_signo     numeric;   -- delta de stock con signo según ingreso/salida
  v_antes     numeric;
  v_despues   numeric;
  v_idmov     text;
  v_aplicadas int := 0;
  v_saltadas  int := 0;
begin
  -- [152] gate de app: pasa para token WH (jwt_app='warehouseMos') y para
  -- service_role/cron (jwt_app=''). Bloquea otras apps. Consistencia con el
  -- resto de RPCs de dinero (cerrar_guia/reabrir_guia ya lo tienen).
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- lock de cabecera: serializa contra cierres concurrentes (doble-tap / cron + manual)
  select estado, tipo into v_estado, v_tipo from wh.guias where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  v_tipo     := upper(coalesce(v_tipo,''));
  v_ingreso  := (v_tipo like 'INGRESO%' or v_tipo like 'ENTRADA%');
  v_envasado := v_tipo in ('INGRESO_ENVASADO','SALIDA_ENVASADO');

  -- monto total = Σ(cant_recibida × precio_unitario)   (igual que cerrar_guia)
  select coalesce(sum(wh._num(cant_recibida::text) * wh._num(precio_unitario::text)), 0)
    into v_monto from wh.guia_detalle where id_guia = v_id;

  -- aplicar por detalle (saltar si envasado: el stock ya lo aplicó Envasados)
  if not v_envasado then
    for v_d in
      select linea, cod_producto, cant_recibida, cantidad_aplicada
        from wh.guia_detalle
       where id_guia = v_id
       order by linea asc nulls last
    loop
      v_cod  := nullif(btrim(v_d.cod_producto), '');
      v_cant := wh._num(v_d.cant_recibida::text);
      v_apl  := wh._num(coalesce(v_d.cantidad_aplicada, 0)::text);
      v_delta := v_cant - v_apl;

      -- línea sin producto → solo alinear marca, sin stock
      if v_cod is null then
        update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
        continue;
      end if;

      -- delta 0 → SKIP TOTAL: no toca stock ni kardex. (red de seguridad anti-duplicado)
      if v_delta = 0 then
        v_saltadas := v_saltadas + 1;
        continue;
      end if;

      v_signo := case when v_ingreso then v_delta else -v_delta end;
      -- origen único por línea: una sola fila de kardex por (guia, linea) aunque se recierre N veces.
      v_idmov := 'MOVID_' || v_id || '#' || v_d.linea;

      -- ── stock ATÓMICO: cantidad + signo (nunca read-modify-write). 1ra fila por producto (como GAS).
      update wh.stock
         set cantidad_disponible = cantidad_disponible + v_signo, ultima_actualizacion = now()
       where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
       returning cantidad_disponible into v_despues;
      if found then
        v_antes := v_despues - v_signo;
      else
        v_antes := 0; v_despues := v_signo;
        insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
        values ('STK'||v_id||'_'||v_cod, v_cod, v_despues, now());
      end if;

      -- kardex con origen único (id_guia#linea) → on conflict do nothing protege la traza
      insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
      values (v_idmov, now(), v_cod, v_signo, v_antes, v_despues, 'CIERRE_GUIA', v_id, 'sistema-cierre-idem')
      on conflict (id_mov) do nothing;

      -- marcar la línea como aplicada al 100% (recerrar dará delta 0)
      update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
      v_aplicadas := v_aplicadas + 1;
    end loop;
  end if;

  -- cerrar cabecera
  update wh.guias set estado = 'CERRADA', monto_total = v_monto where id_guia = v_id;

  return jsonb_build_object('ok', true, 'id_guia', v_id, 'estado', 'CERRADA',
    'montoTotal', v_monto, 'lineasAplicadas', v_aplicadas, 'lineasSaltadas', v_saltadas,
    'eraEstado', v_estado);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM, 'id_guia', v_id);
end;
$function$;

-- La PWA va como rol 'authenticated' (JWT mint-wh). Sin este grant, el cutover
-- del front al cierre idempotente daría HTTP 403. service_role (GAS/cron) ya lo tiene.
grant execute on function wh.cerrar_guia_idempotente(text) to authenticated;


-- ── B. cerrar_guia(p jsonb): DEPRECADA → delega en la idempotente ──
-- Mantiene la firma {p:{id_guia,...}} para no romper callers viejos (PWA pre-deploy,
-- cola offline). Ya NO mueve stock por su cuenta: tras el lock/idempotencia delega
-- en cerrar_guia_idempotente (que lee guia_detalle, setea cantidad_aplicada y
-- escribe kardex único). Así el doble-conteo es IMPOSIBLE aunque algún caller
-- siga llamando esta función. Devuelve shape compatible {ok,estado,montoTotal,yaCerrada}.
create or replace function wh.cerrar_guia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id     text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_estado text;
  v_res    jsonb;
begin
  -- [152 DEPRECADA] kept para compat. El gate WH_CERRAR_GUIA_DIRECTO se respeta
  -- (no cambiar el contrato de gating que el front/GAS pudieran asumir).
  if coalesce((select valor from mos.config where clave='WH_CERRAR_GUIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CERRAR_GUIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- idempotencia previa: si ya cerrada, NO recerrar (devolver yaCerrada como antes)
  select estado into v_estado from wh.guias where id_guia = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;
  if upper(coalesce(v_estado,'')) in ('CERRADA','AUTOCERRADA') then
    return jsonb_build_object('ok',true,'yaCerrada',true,'estado',v_estado,
      'montoTotal',(select monto_total from wh.guias where id_guia = v_id));
  end if;

  -- DELEGA en la idempotente (única verdad del stock; lee guia_detalle, no el payload 'detalles').
  v_res := wh.cerrar_guia_idempotente(v_id);
  if coalesce((v_res->>'ok')::boolean,false) then
    return jsonb_build_object('ok',true,'dedup',false,'id_guia',v_id,'estado','CERRADA',
      'montoTotal', coalesce((v_res->>'montoTotal')::numeric, 0), 'delegado', true);
  end if;
  return v_res;  -- propaga el error de la idempotente
end;
$function$;


-- ── C. reabrir_guia(p jsonb): coherente con el modelo idempotente ──
-- INVARIANTE: reabrir NUNCA toca stock y NUNCA resetea cantidad_aplicada.
-- Solo pone estado=ABIERTA (idempotente por estado). El stock aplicado se preserva;
-- al recerrar, cerrar_guia_idempotente aplica delta = cant_recibida − cantidad_aplicada
-- = 0 (sin editar) → no dobla. Se ELIMINA la rama vieja de "revertir stock por
-- detalles" (dead code peligroso: revertía stock dejando aplicada intacta → recierre
-- delta 0 → stock perdido sin re-aplicar).
create or replace function wh.reabrir_guia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id      text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_estado  text;
begin
  if coalesce((select valor from mos.config where clave='WH_REABRIR_GUIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REABRIR_GUIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- FOR UPDATE: serializa contra cierre/reapertura concurrente del mismo id.
  select estado into v_estado from wh.guias where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  -- idempotente: si ya ABIERTA, no-op (no toca nada)
  if upper(coalesce(v_estado,'')) = 'ABIERTA' then
    return jsonb_build_object('ok',true,'yaAbierta',true,'estado_previo',v_estado);
  end if;

  -- INVARIANTE: NO se revierte stock, NO se resetea cantidad_aplicada. Solo estado.
  update wh.guias set estado = 'ABIERTA', ultima_actividad = now() where id_guia = v_id;
  return jsonb_build_object('ok',true,'id_guia',v_id,'revertido',false,'estado_previo',v_estado);
end;
$function$;
