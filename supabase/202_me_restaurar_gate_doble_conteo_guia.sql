-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 202_me_restaurar_gate_doble_conteo_guia.sql — FIX MONEY/INVENTARIO money-safe (2026-06-20)
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 🔴 REGRESIÓN (verificada en DB live 2026-06-20): me.zona_registrar_guia VOLVIÓ a doblar el saldo en
--    reintento/doble-tap. El SQL 151 había puesto el gate anti-doble-conteo (aplicar el saldo SOLO si el kardex
--    NO fue dedup), pero el SQL 201 — al quitar el upper() del matching de código — recreó la función "IDÉNTICA
--    a 144" y BORRÓ ese gate. Estado vivo previo a este archivo: `perform me.zona_kardex_registrar(...)` (sin
--    capturar el resultado) + `insert into me.stock_zonas ... on conflict do update set cantidad = cantidad +
--    (signo*cant)` INCONDICIONAL. → un reintento del trigger reintentarStockPendiente o un doble-tap del operador
--    en una guía MANUAL (SALIDA_JEFA, traslados SALIDA_MOVIMIENTO/ENTRADA, reposición de anulada ANUL:<idVenta>)
--    deduplica en el kardex (índice único uq_me_kardex_ref por refId 'GUIA:<idGuia>:<cb>') pero SUMA el saldo 2
--    veces, sin rastro en el kardex. SALIDA_VENTAS por caja NO se afecta (va por me.zona_descontar_venta, que
--    conserva su gate).
--
-- 🟢 FIX (merge mecánico 151 + 201): se restaura el gate de 151 SOBRE el cuerpo de 201 (sin upper, igualdad
--    EXACTA de código). Se captura `v_kres := me.zona_kardex_registrar(...)` y se envuelven AMBOS
--    `insert into me.stock_zonas` (el de origen y el espejo de destino del SALIDA_MOVIMIENTO) en
--    `if not coalesce((v_kres->>'dedup')::boolean,false) then ... end if`. Patrón idéntico al de
--    me.zona_descontar_venta. Resultado: en reintento/doble-tap (kardex dedup=true) el saldo NO se vuelve a sumar.
--
-- ⚠️ FUENTE CANÓNICA: este archivo es ahora la definición autoritativa de me.zona_registrar_guia.
--    Incluye el gate 151 + el no-upper de 201. NO recrear esta función desde la base 144 — eso reabre el agujero
--    de doble-conteo. Cualquier migración futura que toque esta RPC DEBE partir de esta definición.
--
-- Idempotente (create or replace). NO cambia firma. NO toca me.zona_descontar_venta (ventas, gate intacto),
-- me.zona_kardex_registrar, ni ninguna otra RPC. NO toca datos (solo redefine la función).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create schema if not exists mos;

create or replace function me.zona_registrar_guia(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := btrim(coalesce(p->>'idGuia',''));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_tipo   text := upper(btrim(coalesce(p->>'tipo','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_idEnt  text := nullif(btrim(coalesce(p->>'idGuiaEntrada','')),'');
  v_zdest  text := upper(nullif(btrim(coalesce(p->>'zonaDestino','')),''));
  v_items  jsonb := coalesce(p->'items', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_signo  int;
  v_n      int := 0;
  v_kres   jsonb;   -- 🔴 151: resultado del kardex → gatear el saldo por dedup (anti doble-conteo)
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' or v_zona = '' or v_tipo = '' then
    return jsonb_build_object('ok',false,'error','Requiere idGuia, zona y tipo');
  end if;
  v_signo := case when v_tipo like 'SALIDA%' then -1 else 1 end;

  for v_e in select * from jsonb_array_elements(v_items) loop
    v_cb   := btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barras', v_e->>'cod_barra', ''));  -- 🔴 201#2: SIN upper(), código TAL CUAL
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;

    -- KARDEX origen (idempotente por refId de guía+código). Capturamos el resultado para el gate del saldo.
    v_kres := me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb,
      'tipo', case when v_signo<0 then (case when v_tipo='SALIDA_MOVIMIENTO' then 'TRASLADO_OUT' else 'SALIDA_JEFA' end)
                   else 'TRASLADO_IN' end,
      'delta', (v_signo * v_cant), 'refTipo', 'GUIA', 'refId', 'GUIA:'||v_id||':'||v_cb,
      'usuario', v_user, 'origen', v_origen));

    -- SALDO atómico origen — SOLO si el kardex NO fue dedup (🔴 151: reintento/doble-tap NO dobla el saldo).
    if not coalesce((v_kres->>'dedup')::boolean, false) then
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_cb, v_zona, (v_signo * v_cant), v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) + (v_signo * v_cant),
            usuario = excluded.usuario, fecha_ultimo_registro = now();
    end if;

    -- SALIDA_MOVIMIENTO con destino → entrada espejo en la zona destino (mismo gate por dedup).
    if v_tipo = 'SALIDA_MOVIMIENTO' and v_zdest is not null then
      v_kres := me.zona_kardex_registrar(jsonb_build_object(
        'zona', v_zdest, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN', 'delta', v_cant,
        'refTipo', 'GUIA', 'refId', 'GUIA:'||coalesce(v_idEnt, v_id||'-IN')||':'||v_cb,
        'usuario', v_user, 'origen', v_origen));
      if not coalesce((v_kres->>'dedup')::boolean, false) then
        insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
          values (v_cb, v_zdest, v_cant, v_user, now())
        on conflict (cod_barras, zona_id) do update
          set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_cant,
              usuario = excluded.usuario, fecha_ultimo_registro = now();
      end if;
    end if;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'idGuia', v_id, 'zona', v_zona, 'tipo', v_tipo, 'lineas', v_n);
end;
$fn$;
revoke all on function me.zona_registrar_guia(jsonb) from public;
grant execute on function me.zona_registrar_guia(jsonb) to service_role, authenticated;
