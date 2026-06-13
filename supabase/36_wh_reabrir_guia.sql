-- 36_wh_reabrir_guia.sql — [PASO 4 · sesión 4c] Reabrir guía: revierte el stock del cierre, vuelve ABIERTA.
-- ⚠️ INERTE: gateada por mos.config.WH_REABRIR_GUIA_DIRECTO (default '0').
-- Replica reabrirGuia (Guias.gs): SOLO si estaba 'CERRADA' (no AUTOCERRADA, que nunca aplicó stock) y NO envasado,
-- revierte stock por línea (INGRESO→-cant, SALIDA→+cant). NO revierte lotes (igual que GAS). Recibe detalles como
-- parámetro. Idempotente por estado: si ya ABIERTA no revierte. FOR UPDATE evita doble-reverso concurrente.

insert into mos.config (clave, valor, descripcion) values
  ('WH_REABRIR_GUIA_DIRECTO','0','WH: reabrir guia directo a Supabase (RPC wh.reabrir_guia). Validar antes de prender.')
on conflict (clave) do nothing;

-- [40x A3] coerción numérica tolerante (idempotente; misma def que 30/35).
create or replace function wh._num(t text) returns numeric language sql immutable as $$
  select case
    when t is null then 0
    when btrim(replace(t, ',', '.')) ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(replace(t, ',', '.'))::numeric
    else 0 end;
$$;

create or replace function wh.reabrir_guia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id       text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_usuario  text := coalesce(p->>'usuario','');
  v_estado   text;
  v_tipo     text;
  v_ingreso  boolean;
  v_envasado boolean;
  v_d        jsonb;
  v_cod      text;
  v_cant     numeric;
  v_idmov    text;
  v_delta    numeric;
  v_antes    numeric;
  v_despues  numeric;
  v_existe   boolean;
  v_revertido boolean := false;
begin
  if coalesce((select valor from mos.config where clave='WH_REABRIR_GUIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REABRIR_GUIA_DIRECTO_OFF');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- FOR UPDATE: serializa contra otra reapertura/cierre concurrente (evita doble-reverso)
  select estado, tipo into v_estado, v_tipo from wh.guias where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  v_tipo     := upper(coalesce(v_tipo,''));
  v_ingreso  := v_tipo like 'INGRESO%';
  v_envasado := v_tipo in ('INGRESO_ENVASADO','SALIDA_ENVASADO');

  -- revertir stock SOLO si estaba CERRADA (AUTOCERRADA nunca aplicó stock) y no envasado
  if upper(coalesce(v_estado,'')) = 'CERRADA' and not v_envasado and jsonb_typeof(p->'detalles') = 'array' then
    v_revertido := true;
    for v_d in select jsonb_array_elements(p->'detalles') loop
      v_cod  := nullif(btrim(v_d->>'codigo_producto'),'');
      v_cant := wh._num(v_d->>'cantidad_recibida');
      if v_cod is null or v_cant = 0 then continue; end if;
      if coalesce(v_d->>'observacion','') = 'ANULADO' then continue; end if;   -- igual que GAS
      v_idmov := nullif(btrim(v_d->>'id_mov'),'');
      v_delta := case when v_ingreso then -v_cant else v_cant end;   -- REVERSO del cierre

      -- stock ATÓMICO (set = cantidad + delta) → evita lost-update concurrente
      update wh.stock set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = now()
       where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)  -- [B-1] 1ra fila (como GAS)
       returning cantidad_disponible into v_despues;
      if found then
        v_antes := v_despues - v_delta;
      else
        v_antes := 0; v_despues := v_delta;
        insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
        values ('STK'||v_id||'_'||v_cod, v_cod, v_despues, now());
      end if;
      if v_idmov is not null then
        insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
        values (v_idmov, now(), v_cod, v_delta, v_antes, v_despues, 'REABRIR_REVERSO', v_id, v_usuario)
        on conflict (id_mov) do nothing;
      end if;
    end loop;
  end if;

  update wh.guias set estado = 'ABIERTA' where id_guia = v_id;
  return jsonb_build_object('ok',true,'id_guia',v_id,'revertido',v_revertido,'estado_previo',v_estado);
end;
$fn$;

revoke all on function wh.reabrir_guia(jsonb) from public;
grant execute on function wh.reabrir_guia(jsonb) to service_role;
