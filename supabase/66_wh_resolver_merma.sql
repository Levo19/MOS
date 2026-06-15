-- 66_wh_resolver_merma.sql — [Tanda 2] Escritura directa: RESOLVER una merma (NO mueve stock por sí misma). INERTE.
-- ⚠️ gateada por mos.config.WH_RESOLVER_MERMA_DIRECTO (default '0').
--
-- Replica resolverMerma (Productos.gs):
--   · Valida rep + des == cantidad_original (con tolerancia 0.001).
--   · La parte REPARADA no toca stock (el producto siempre estuvo en stock).
--   · La parte DESECHADA se agrega como detalle a la guía SALIDA_MERMA ABIERTA de la SEMANA actual (lun-dom, TZ Lima):
--       - get-or-create de esa guía (estado ABIERTA), igual que _getOCrearGuiaMermaSemana.
--       - inserta UNA línea en wh.guia_detalle con la cantidad desechada.
--     → La guía queda ABIERTA, así que NO se toca wh.stock aquí: el descuento de stock ocurre cuando el operador
--       CIERRA esa guía SALIDA_MERMA (vía wh.cerrar_guia). Esto espeja exactamente al GAS (resolverMerma solo agrega
--       el detalle a una guía abierta; nunca llama _actualizarStock).
--   · Marca la merma: cantidad_reparada/desechada, cantidad_pendiente=0, estado='RESUELTA', fecha_resolucion,
--     observacion_resolucion, id_guia_salida.
--
-- IDEMPOTENCIA: la operación inserta una línea en wh.guia_detalle (NO idempotente natural si se re-corre antes de que
-- cambie el estado de la merma) → DEDUP por wh._dedup_nuevo(local_id) ADEMÁS del guard de estado por merma. El guard de
-- estado (FOR UPDATE sobre la fila de merma) serializa contra resoluciones concurrentes de la misma merma y evita el
-- doble-detalle; el dedup por local_id cubre el reintento del mismo POST. El id_detalle es determinista (del local_id)
-- → si por carrera llegara a re-insertarse, el conflict por (id_guia,linea) NO aplica (linea = max+1), por eso el guard
-- de estado + dedup son la defensa real. La guía semanal se identifica por su id_guia determinista 'GMERMA'+semana.

insert into mos.config (clave, valor, descripcion) values
  ('WH_RESOLVER_MERMA_DIRECTO','0','WH: resolver merma directo (RPC wh.resolver_merma). Agrega desecho a guia SALIDA_MERMA semanal ABIERTA. Validar antes de prender.')
on conflict (clave) do nothing;

create or replace function wh.resolver_merma(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idmerma text := nullif(btrim(coalesce(p->>'id_merma','')), '');
  v_rep     numeric := wh._num(p->>'cantidad_reparada');
  v_des     numeric := wh._num(p->>'cantidad_desechada');
  v_obs     text := coalesce(p->>'observacion_resolucion','');
  v_usuario text := coalesce(p->>'usuario','');
  v_iddet   text := nullif(btrim(coalesce(p->>'id_detalle','')), '');   -- determinista (del local_id) para la línea de desecho
  v_lid     text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_estado  text; v_orig numeric; v_cod text; v_motivo text;
  -- semana actual (lun-dom) en TZ Lima — espeja _getOCrearGuiaMermaSemana (que usa getDay() local del script = Lima)
  v_hoy     date := (now() at time zone 'America/Lima')::date;
  v_dow     int  := extract(dow from v_hoy)::int;   -- 0=domingo ... 6=sábado
  v_lunes   date;
  v_domingo date;
  v_idguia  text; v_linea int;
begin
  if coalesce((select valor from mos.config where clave='WH_RESOLVER_MERMA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_RESOLVER_MERMA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idmerma is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  -- [dedup] inserta línea de guía + cambia estado → NO idempotente natural ante reintento del mismo POST → dedup por local_id.
  if v_lid is not null and not wh._dedup_nuevo(v_lid, 'resolver_merma') then
    return jsonb_build_object('ok',true,'dedup',true);
  end if;

  -- localizar + BLOQUEAR la merma (FOR UPDATE serializa contra resolución concurrente → guard de estado real)
  select upper(coalesce(estado,'')), coalesce(cantidad_original,0), coalesce(cod_producto,''), coalesce(motivo,'')
    into v_estado, v_orig, v_cod, v_motivo
    from wh.mermas where id_merma = v_idmerma limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','MERMA_NO_ENCONTRADA'); end if;

  -- guard de estado: ya resuelta/desechada → no re-resolver (idempotente por estado)
  if v_estado in ('RESUELTA','DESECHADA') then
    return jsonb_build_object('ok',true,'yaResuelta',true,'id_merma',v_idmerma);
  end if;

  -- rep + des debe igualar el original (misma tolerancia que GAS)
  if abs((v_rep + v_des) - v_orig) > 0.001 then
    return jsonb_build_object('ok',false,'error','SUMA_NO_IGUALA_ORIGINAL','original',v_orig);
  end if;

  -- ── parte DESECHADA → guía SALIDA_MERMA ABIERTA de la semana (get-or-create) + detalle ──
  v_lunes   := v_hoy - (case when v_dow = 0 then 6 else v_dow - 1 end);
  v_domingo := v_lunes + 7;   -- exclusivo (lunes siguiente)
  if v_des > 0 and v_cod <> '' then
    -- buscar guía SALIDA_MERMA ABIERTA cuya fecha (día Lima) caiga en [lunes, domingo)
    select id_guia into v_idguia from wh.guias
     where tipo = 'SALIDA_MERMA' and upper(coalesce(estado,'')) = 'ABIERTA'
       and (fecha at time zone 'America/Lima')::date >= v_lunes
       and (fecha at time zone 'America/Lima')::date <  v_domingo
     order by fecha asc limit 1;
    if v_idguia is null then
      -- id determinista por semana → reintentos no crean guías duplicadas (on conflict no-op)
      v_idguia := 'GMERMA' || to_char(v_lunes,'YYYYMMDD');
      insert into wh.guias (id_guia,tipo,fecha,usuario,comentario,monto_total,estado,id_proveedor,id_zona,numero_documento,id_preingreso,foto)
      values (v_idguia,'SALIDA_MERMA',now(),coalesce(nullif(v_usuario,''),'sistema'),
              'Mermas semana '||to_char(v_lunes,'YYYY-MM-DD')||' al '||to_char(v_domingo-1,'YYYY-MM-DD'),
              0,'ABIERTA','','','','','')
      on conflict (id_guia) do nothing;
    end if;

    -- [FIX #1] LOCK de la guía semanal ANTES de calcular linea — serializa resoluciones concurrentes del mismo cod en la
    -- misma semana (sin esto, dos POST calculan max(linea)+1 iguales → choque con el PK (id_guia,linea) → unique_violation).
    -- Idéntico patrón a 43 (agregar_detalle_guia) y 35 (cerrar_guia), que hacen `for update` sobre wh.guias antes de tocar guia_detalle.
    perform 1 from wh.guias where id_guia = v_idguia for update;

    -- detalle de la guía — AUTO-SUMA igual que agregarDetalleGuia (Guias.gs): si ya hay línea (mismo cod, no ANULADO) en
    -- esta guía semanal, suma la cantidad; sino inserta línea nueva. La guía está ABIERTA → no toca stock de ningún modo
    -- (el descuento se aplica al CERRAR la guía SALIDA_MERMA). El dedup por local_id ya evita re-sumar el mismo POST.
    select linea into v_linea from wh.guia_detalle
     where id_guia = v_idguia and upper(coalesce(cod_producto,'')) = upper(v_cod) and upper(coalesce(observacion,'')) <> 'ANULADO'
     order by linea limit 1;
    if found then
      update wh.guia_detalle set cant_recibida = coalesce(cant_recibida,0) + v_des, cant_esperada = coalesce(cant_esperada,0) + v_des
       where id_guia = v_idguia and linea = v_linea;
    else
      select coalesce(max(linea),0)+1 into v_linea from wh.guia_detalle where id_guia = v_idguia;
      insert into wh.guia_detalle (id_guia,linea,cod_producto,cant_esperada,cant_recibida,precio_unitario,id_lote,observacion,id_producto_nuevo,id_detalle,fecha_vencimiento)
      values (v_idguia, v_linea, v_cod, v_des, v_des, 0, '',
              'Merma '||v_idmerma||case when v_motivo <> '' then ' · '||v_motivo else '' end, '',
              coalesce(v_iddet,'MRMDET_'||v_idmerma), null);
    end if;
  end if;

  -- ── marcar la merma RESUELTA ──
  update wh.mermas
     set cantidad_reparada      = v_rep,
         cantidad_desechada     = v_des,
         cantidad_pendiente     = 0,
         estado                 = 'RESUELTA',
         fecha_resolucion       = now(),
         observacion_resolucion = v_obs,
         id_guia_salida         = case when v_des > 0 then coalesce(v_idguia, id_guia_salida) else id_guia_salida end
   where id_merma = v_idmerma;

  return jsonb_build_object('ok',true,'dedup',false,'id_merma',v_idmerma,'id_guia_salida',coalesce(v_idguia,''),
    'cantidad_reparada',v_rep,'cantidad_desechada',v_des);
end;
$fn$;

revoke all on function wh.resolver_merma(jsonb) from public;
grant execute on function wh.resolver_merma(jsonb) to service_role, authenticated;
