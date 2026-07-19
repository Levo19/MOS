CREATE OR REPLACE FUNCTION me.cerrar_guia_zona_idempotente(p_id_guia text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id        text := nullif(btrim(coalesce(p_id_guia,'')), '');
  v_estado    text;
  v_tipo      text;
  v_zona      text;
  v_zdest     text;          -- zona destino (solo SALIDA_MOVIMIENTO) → espejo IN
  v_signo_in  boolean;       -- la guía SUMA al saldo (entrada/traslado-in) vs resta (salida)
  v_es_venta  boolean;       -- SALIDA_VENTAS: no mueve saldo aquí (lo hace zona_descontar_venta)
  v_es_trasl_in boolean;     -- ENTRADA_TRASLADO: espejo metadata-only de un SALIDA_MOVIMIENTO → NO re-sumar aquí
  v_es_mov    boolean;       -- SALIDA_MOVIMIENTO con destino → aplicar OUT origen + IN espejo destino
  v_aplicar_stock boolean := true;    -- ✅ [GATE-STOCK] ACTIVO (go-live 2026-06-17, sync OFF).
  v_d         record;
  v_cb        text;
  v_cant      numeric(20,3);
  v_apl       numeric(20,3);
  v_delta     numeric(20,3);
  v_signo     numeric(20,3);
  v_refk      text;
  v_kres      jsonb;          -- resultado del kardex → gatear el saldo por dedup (anti doble-conteo)
  v_aplicadas int := 0;
  v_saltadas  int := 0;
begin
  -- Gate: _claim_zona_ok acepta '' (GAS/service_role), 'MOS' y 'mosExpress' (PWA ME). Superset seguro,
  --   consistente con reabrir_guia_zona / zona_guia_registrar_meta / zona_kardex_registrar. El execute sigue
  --   limitado a service_role (los wrappers me/mos.cerrar_guia_zona, granted a authenticated, son la puerta gated).
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- lock de cabecera: serializa contra cierres concurrentes (doble-tap / cron + manual)
  select estado, tipo, zona_id, zona_destino into v_estado, v_tipo, v_zona, v_zdest
    from me.guias_cabecera where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  v_tipo        := upper(coalesce(v_tipo,''));
  v_zona        := upper(btrim(coalesce(v_zona,'')));
  v_zdest       := upper(nullif(btrim(coalesce(v_zdest,'')),''));
  v_signo_in    := (v_tipo like 'ENTRADA%' or v_tipo like 'TRASLADO_IN%');
  v_es_venta    := (v_tipo = 'SALIDA_VENTAS' or v_tipo = 'SALIDA_VENTA');
  v_es_trasl_in := (v_tipo = 'ENTRADA_TRASLADO');                       -- espejo metadata-only → no mueve saldo aquí
  v_es_mov      := (v_tipo = 'SALIDA_MOVIMIENTO' and v_zdest is not null);

  for v_d in
    select linea, cod_barras, cantidad, cantidad_aplicada
      from me.guias_detalle
     where id_guia = v_id
     order by linea asc nulls last
  loop
    v_cb   := nullif(btrim(coalesce(v_d.cod_barras,'')), '');
    v_cant := coalesce(v_d.cantidad, 0);
    v_apl  := coalesce(v_d.cantidad_aplicada, 0);
    v_delta := v_cant - v_apl;

    -- línea sin código → solo alinear marca, sin stock
    if v_cb is null then
      update me.guias_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
      continue;
    end if;

    -- delta 0 → SKIP TOTAL (red de seguridad anti-duplicado: recerrar/reabrir+recerrar no toca nada)
    if v_delta = 0 then
      v_saltadas := v_saltadas + 1;
      continue;
    end if;

    -- VENTA o ENTRADA_TRASLADO (espejo) → NO mueve saldo aquí. Solo marca aplicado (evita doble-conteo).
    --   · SALIDA_VENTAS: el saldo lo aplica zona_descontar_venta por caja.
    --   · ENTRADA_TRASLADO: su IN ya lo aplica el cierre del SALIDA_MOVIMIENTO origen (espejo abajo).
    if not v_es_venta and not v_es_trasl_in then
      v_signo := case when v_signo_in then v_delta else -v_delta end;
      v_refk  := 'CIERRE-GUIA:'||v_id||':'||v_d.linea;

      -- KARDEX origen (ref única determinista; idempotente aunque se recierre N veces). Gateamos el saldo por dedup.
      v_kres := me.zona_kardex_registrar(jsonb_build_object(
        'zona', v_zona, 'codBarra', v_cb,
        'tipo', case when v_signo_in then 'TRASLADO_IN'
                     when v_es_mov   then 'TRASLADO_OUT'
                     else 'SALIDA_JEFA' end,
        'delta', v_signo, 'refTipo', 'GUIA', 'refId', v_refk,
        'usuario', 'sistema-cierre-zona', 'origen', 'CIERRE-IDEM'));

      -- SALDO atómico origen — SOLO si el kardex NO fue dedup (reintento/doble-tap NO dobla el saldo).
      if v_aplicar_stock and not coalesce((v_kres->>'dedup')::boolean, false) then
        insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
          values (v_cb, v_zona, v_signo, 'sistema-cierre-zona', now())
        on conflict (cod_barras, zona_id) do update
          set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_signo,
              fecha_ultimo_registro = now();
      end if;

      -- ESPEJO DE TRASLADO: SALIDA_MOVIMIENTO con destino → IN en la zona destino (+v_delta). Mismo gate por dedup.
      --   refId distinto (CIERRE-GUIA-IN) → el OUT y el IN nunca se pisan. cantidad_aplicada de la línea (del OUT)
      --   gobierna AMBOS lados → recerrar = delta 0 = SKIP = ni OUT ni IN se re-aplican.
      if v_es_mov then
        v_kres := me.zona_kardex_registrar(jsonb_build_object(
          'zona', v_zdest, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN',
          'delta', v_delta, 'refTipo', 'GUIA', 'refId', 'CIERRE-GUIA-IN:'||v_id||':'||v_d.linea,
          'usuario', 'sistema-cierre-zona', 'origen', 'CIERRE-IDEM'));
        if v_aplicar_stock and not coalesce((v_kres->>'dedup')::boolean, false) then
          insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
            values (v_cb, v_zdest, v_delta, 'sistema-cierre-zona', now())
          on conflict (cod_barras, zona_id) do update
            set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_delta,
                fecha_ultimo_registro = now();
        end if;
      end if;
    end if;

    update me.guias_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
    v_aplicadas := v_aplicadas + 1;
  end loop;

  update me.guias_cabecera set estado = 'CERRADA' where id_guia = v_id;

  return jsonb_build_object('ok', true, 'idGuia', v_id, 'estado', 'CERRADA',
    'stockAplicado', v_aplicar_stock, 'lineasAplicadas', v_aplicadas, 'lineasSaltadas', v_saltadas,
    'eraEstado', v_estado);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM, 'idGuia', v_id);
end;
$function$
