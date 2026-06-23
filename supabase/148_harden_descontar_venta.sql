-- 148 — Hardening me.zona_descontar_venta
-- Motivo (hallazgo validación venta real 2026-06-17): la temp table `_venta_agg` de nombre
-- fijo con `on commit drop` rompe si la RPC se llama 2 veces en la MISMA transacción
-- ("relation _venta_agg already exists"). En el path vivo (PostgREST = 1 tx por RPC) no ocurre,
-- pero un orquestador que la llame en bucle dentro de una tx fallaría en la 2da iteración.
-- Fix: `if not exists` + `truncate` → robusto a múltiples llamadas por transacción.
-- Comportamiento del descuento idéntico (validado con rollback + idempotencia).

create or replace function me.zona_descontar_venta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_caja   text := btrim(coalesce(p->>'idCaja',''));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_items  jsonb := coalesce(p->'items', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_kres   jsonb;
  v_aplicados int := 0;
  v_dedup     int := 0;
  v_resultado jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_caja = '' then return jsonb_build_object('ok',false,'error','Requiere idCaja'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  -- Agregar por código (defensa: sumar si el array trae el mismo código en varias líneas).
  create temp table if not exists _venta_agg (cod_barra text primary key, cant numeric) on commit drop;
  truncate _venta_agg;
  for v_e in select * from jsonb_array_elements(v_items) loop
    v_cb   := upper(btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barras', v_e->>'cod_barra', '')));
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;
    insert into _venta_agg(cod_barra, cant) values (v_cb, v_cant)
      on conflict (cod_barra) do update set cant = _venta_agg.cant + excluded.cant;
  end loop;

  for v_cb, v_cant in select cod_barra, cant from _venta_agg loop
    -- KARDEX primero (es el guardián de idempotencia por id_caja). dedup=true → ya se descontó esta caja.
    v_kres := me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb, 'tipo', 'SALIDA_VENTA', 'delta', (-v_cant),
      'refTipo', 'VENTA', 'refId', 'VENTA-CAJA:'||v_caja||':'||v_cb, 'usuario', v_user, 'origen', v_origen));

    if coalesce((v_kres->>'dedup')::boolean, false) then
      v_dedup := v_dedup + 1;   -- esta caja+código YA se descontó → NO restar otra vez.
    else
      -- UPDATE ATÓMICO (resta). Insert si no existe la fila (saldo arranca en −cant; conteo físico lo corrige).
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_cb, v_zona, -v_cant, v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) - v_cant,
            usuario = excluded.usuario, fecha_ultimo_registro = now();
      v_aplicados := v_aplicados + 1;
    end if;
    v_resultado := v_resultado || jsonb_build_object('codBarra', v_cb, 'cantidad', v_cant,
      'aplicado', not coalesce((v_kres->>'dedup')::boolean,false));
  end loop;

  return jsonb_build_object('ok', true, 'idCaja', v_caja, 'zona', v_zona,
    'aplicados', v_aplicados, 'dedup', v_dedup, 'detalle', v_resultado);
end;
$function$;

revoke all on function me.zona_descontar_venta(jsonb) from public;
grant execute on function me.zona_descontar_venta(jsonb) to service_role, authenticated;
