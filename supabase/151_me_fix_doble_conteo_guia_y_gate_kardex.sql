-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 151_me_fix_doble_conteo_guia_y_gate_kardex.sql — FIXES money-safety de la auditoría 50x (2026-06-17)
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 🔴 ME-A · me.zona_registrar_guia DOBLABA el stock en un reintento/doble-tap:
--    el INSERT...ON CONFLICT DO UPDATE SET cantidad = cantidad + delta de me.stock_zonas corría INCONDICIONALMENTE,
--    sin mirar el `dedup` del kardex (que SÍ deduplica por refId 'GUIA:<idGuia>:<cb>'). Modo de fallo real: la RPC
--    commitea pero la respuesta HTTP se pierde (timeout) → GAS encola → reintento → el kardex deduplica pero el
--    saldo se aplica OTRA VEZ = doble-conteo. Igual por doble-tap del operador.
--    FIX: aplicar el saldo SOLO si el kardex NO fue dedup (mismo patrón que me.zona_descontar_venta). Idem bloque espejo.
--
-- 🟠 ME-C · me.zona_kardex_registrar gateaba con mos._claim_ok() = jwt_app() in ('','MOS'), que RECHAZA 'mosExpress'.
--    En recepción WH→ME por escaneo (token de la PWA ME, app='mosExpress'), recibir_guia_wh_cerrar aplica el saldo
--    pero su `perform me.zona_kardex_registrar(...)` devuelve APP_NO_AUTORIZADA y SE DESCARTA → saldo sin kardex
--    (hueco de auditoría, justo lo que causó 59 desync en WH). FIX: gatear el kardex con me._claim_zona_ok()
--    (acepta '' service_role/GAS · 'MOS' · 'mosExpress') — superconjunto seguro; los callers ya gatean afuera.
--
-- Idempotente (create or replace). NO cambia firmas. NO toca otras RPC.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── FIX ME-C: gate del kardex acepta el ecosistema de zona (incl. mosExpress) ───────────────────────────────
create or replace function me.zona_kardex_registrar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_cod    text := btrim(coalesce(p->>'codBarra',''));
  v_tipo   text := upper(btrim(coalesce(p->>'tipo','')));
  v_reft   text := nullif(upper(btrim(coalesce(p->>'refTipo',''))),'');
  v_refid  text := nullif(btrim(coalesce(p->>'refId','')),'');
  v_lote   text := nullif(btrim(coalesce(p->>'idLote','')),'');
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_local  text := nullif(btrim(coalesce(p->>'localId','')),'');
  v_has_abs boolean := (p ? 'nuevoAbsoluto') and (p->>'nuevoAbsoluto') is not null;
  v_abs    numeric(20,3);
  v_delta  numeric(20,3);
  v_antes  numeric(20,3);
  v_desp   numeric(20,3);
  v_row    me.stock_movimientos%rowtype;
  v_exist  me.stock_movimientos%rowtype;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- 🟠 ME-C (era mos._claim_ok)
  if v_zona = '' or v_cod = '' or v_tipo = '' then
    return jsonb_build_object('ok',false,'error','Requiere zona, codBarra y tipo');
  end if;

  if v_refid is not null then
    select * into v_exist from me.stock_movimientos
      where ambito='ZONA' and coalesce(zona_id,'')=v_zona and ref_id=v_refid limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_exist)); end if;
  end if;
  if v_local is not null then
    select * into v_exist from me.stock_movimientos where local_id=v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_exist)); end if;
  end if;

  select coalesce(saldo_despues,0) into v_antes
    from me.stock_movimientos
   where ambito='ZONA' and coalesce(zona_id,'')=v_zona and cod_barra=v_cod
   order by fecha desc, id desc limit 1;
  v_antes := coalesce(v_antes,0);

  if v_has_abs then
    v_abs   := (p->>'nuevoAbsoluto')::numeric;
    v_delta := v_abs - v_antes;
    if v_reft is null then v_reft := case when v_tipo='AUDITORIA' then 'AUDITORIA' else 'AJUSTE' end; end if;
  else
    if (p->>'delta') is null then
      return jsonb_build_object('ok',false,'error','Requiere delta o nuevoAbsoluto');
    end if;
    v_delta := (p->>'delta')::numeric;
  end if;
  v_desp := v_antes + v_delta;

  if v_reft is null then
    v_reft := case
      when v_tipo like 'INGRESO%' then 'GUIA'
      when v_tipo = 'SALIDA_VENTA' then 'VENTA'
      when v_tipo = 'SALIDA_JEFA' then 'GUIA'
      when v_tipo like 'TRASLADO%' then 'TRASLADO'
      when v_tipo = 'ENVASADO' then 'ENVASADO'
      else v_tipo end;
  end if;

  insert into me.stock_movimientos
    (ambito, zona_id, cod_barra, id_lote, tipo, delta, saldo_antes, saldo_despues,
     ref_tipo, ref_id, usuario, fecha, origen, local_id)
  values
    ('ZONA', v_zona, v_cod, v_lote, v_tipo, v_delta, v_antes, v_desp,
     v_reft, v_refid, v_user, now(), v_origen, v_local)
  on conflict do nothing
  returning * into v_row;

  if v_row.id is null then
    if v_refid is not null then
      select * into v_row from me.stock_movimientos
        where ambito='ZONA' and coalesce(zona_id,'')=v_zona and ref_id=v_refid limit 1;
    elsif v_local is not null then
      select * into v_row from me.stock_movimientos where local_id=v_local limit 1;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_row));
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'data',to_jsonb(v_row));
end;
$function$;

-- ── FIX ME-A: el saldo se aplica SOLO si el kardex no fue dedup (anti doble-conteo) ──────────────────────────
create or replace function me.zona_registrar_guia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
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
  v_kres   jsonb;   -- resultado del kardex → para gatear el saldo por dedup (ME-A)
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' or v_zona = '' or v_tipo = '' then
    return jsonb_build_object('ok',false,'error','Requiere idGuia, zona y tipo');
  end if;
  v_signo := case when v_tipo like 'SALIDA%' then -1 else 1 end;

  for v_e in select * from jsonb_array_elements(v_items) loop
    v_cb   := upper(btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barras', v_e->>'cod_barra', '')));
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;

    -- KARDEX origen (idempotente por refId de guía+código). Guarda el resultado para el gate del saldo.
    v_kres := me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb,
      'tipo', case when v_signo<0 then (case when v_tipo='SALIDA_MOVIMIENTO' then 'TRASLADO_OUT' else 'SALIDA_JEFA' end)
                   else 'TRASLADO_IN' end,
      'delta', (v_signo * v_cant), 'refTipo', 'GUIA', 'refId', 'GUIA:'||v_id||':'||v_cb,
      'usuario', v_user, 'origen', v_origen));

    -- SALDO atómico origen — SOLO si el kardex NO fue dedup (🔴 ME-A: reintento/doble-tap NO dobla el saldo).
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
$function$;
