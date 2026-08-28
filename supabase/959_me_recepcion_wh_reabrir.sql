-- 959_me_recepcion_wh_reabrir.sql — REABRIR / EDITAR una recepción WH→ME ya cerrada (con clave admin/master)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- App de DINERO/inventario. El operador de zona recibe una guía de almacén por escaneo (me.recibir_guia_wh_cerrar).
-- Si se olvidó productos o quiere corregir un detalle, RE-ESCANEA el QR: el sistema detecta "ya ingresada" y le
-- ofrece EDITAR/AGREGAR bajo clave admin de 8 dígitos (rol_nivel>=2 = ADMIN o MASTER). Este archivo:
--   1) me.recepcion_wh_reabrir(p {idGuiaWH, claveAdmin}) — re-verifica la clave server-side y marca estado='ABIERTA'.
--   2) REDEFINE me.recibir_guia_wh_cerrar para permitir el RE-CIERRE cuando estado='ABIERTA', aplicando SOLO el
--      DELTA vs lo ya escaneado (incremental, money-safe). El front manda el set completo (precargado + nuevo).
--   3) columna reaperturas (contador de sesiones de edición) + permiso REABRIR_RECEPCION.
--
-- ── POR QUÉ ES MONEY-SAFE ───────────────────────────────────────────────────────────────────────────────────
--   · Hoy WH_DESPACHO_SUMA_ZONA='1' → la recepción NO toca me.stock_zonas (lo suma el despacho por trigger).
--     Aun así, si algún día el flag se apaga, el re-cierre aplica el DELTA (nuevo−previo) por línea, NUNCA el set
--     completo otra vez → imposible doble-contar. Kardex idempotente por refId con sufijo de sesión (:r<n>).
--   · La reapertura re-verifica la clave con mos.reverificar_clave_admin (bcrypt + cascada nivel + auditoría),
--     mismo helper que las RPCs de dinero (434/435). No confía en el flag del front.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

-- Contador de sesiones de edición (0 = nunca reabierta). Usado en el refId del kardex para trazar cada edición.
alter table me.zona_traslado_verificacion add column if not exists reaperturas int not null default 0;

-- Permiso de la acción (nivel 2 = ADMIN o MASTER), igual que REABRIR_GUIA.
insert into mos.permisos_accion (accion, nivel_minimo, label, app)
  select 'REABRIR_RECEPCION', 2, 'Reabrir recepción de almacén (editar/agregar)', ''
  where not exists (select 1 from mos.permisos_accion where accion = 'REABRIR_RECEPCION');


-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) me.recepcion_wh_reabrir(p {idGuiaWH|idGuia, claveAdmin|clave, usuario?})
--    Re-verifica la clave admin (accion REABRIR_RECEPCION) y marca la recepción como ABIERTA (editable).
--    Devuelve la fila (con su `detalle` = lo ya escaneado) para que el front PRECARGUE el conteo y continúe.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.recepcion_wh_reabrir(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id    text := btrim(coalesce(p->>'idGuiaWH', p->>'idGuia', ''));
  v_clave text := nullif(btrim(coalesce(p->>'claveAdmin', p->>'clave', '')), '');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_ref   text;
  v_row   me.zona_traslado_verificacion%rowtype;
  v_rev   jsonb;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuiaWH'); end if;
  v_ref := 'WH:'||v_id;

  select * into v_row from me.zona_traslado_verificacion where id_guia = v_ref;
  if not found then
    return jsonb_build_object('ok',false,'error','Esta guía no tiene recepción registrada todavía');
  end if;

  -- Re-verificación server-side de la clave admin/master (NULL = autorizado; jsonb = rechazo).
  v_rev := mos.reverificar_clave_admin(v_clave, 'REABRIR_RECEPCION', v_ref, 'mosExpress');
  if v_rev is not null then return v_rev; end if;

  update me.zona_traslado_verificacion
     set estado = 'ABIERTA', reaperturas = coalesce(reaperturas,0) + 1
   where id_guia = v_ref
   returning * into v_row;

  return jsonb_build_object('ok', true, 'data', to_jsonb(v_row));
end;
$fn$;
revoke all on function me.recepcion_wh_reabrir(jsonb) from public;
grant execute on function me.recepcion_wh_reabrir(jsonb) to service_role, authenticated;


-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) REDEFINE me.recibir_guia_wh_cerrar — permite RE-CIERRE cuando estado='ABIERTA' (incremental / money-safe).
--    Cambios vs 592: (a) el guard de dedup solo rechaza si la recepción existe y NO está ABIERTA; (b) el kardex y
--    el stock aplican el DELTA por línea (nuevo − previo), con refId de sesión; (c) upsert de la verificación.
--    Todo lo demás (cómputo enviado/escaneado/detalle, gate de stock por flag) queda idéntico a 592.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.recibir_guia_wh_cerrar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := btrim(coalesce(p->>'idGuiaWH', p->>'idGuia', ''));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'MOS-PWA-ME');
  v_g      wh.guias%rowtype;
  v_ref    text;
  v_exist  me.zona_traslado_verificacion%rowtype;
  v_reabierto boolean := false;
  v_sess   int := 0;
  v_sfx    text := '';
  v_esc    jsonb := coalesce(p->'escaneados', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_prev   numeric(20,3);
  v_delta  numeric(20,3);
  v_linea  int;
  v_enviado_tot   numeric(20,3) := 0;
  v_escaneado_tot numeric(20,3) := 0;
  v_dif_tot       numeric(20,3) := 0;
  v_ok_n   int := 0;
  v_dif_n  int := 0;
  v_estado text;
  v_detalle jsonb := '[]'::jsonb;
  v_aplicar_stock boolean := (coalesce((select valor from mos.config where clave='WH_DESPACHO_SUMA_ZONA' limit 1),'0') <> '1');
  v_row     me.zona_traslado_verificacion%rowtype;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuiaWH'); end if;

  v_ref := 'WH:'||v_id;

  select * into v_exist from me.zona_traslado_verificacion where id_guia = v_ref;
  if found then
    if upper(coalesce(v_exist.estado,'')) = 'ABIERTA' then
      v_reabierto := true;                          -- re-cierre autorizado (fue reabierta con clave admin)
      v_sess := coalesce(v_exist.reaperturas, 0);
      v_sfx  := case when v_sess > 0 then ':r'||v_sess else '' end;
    else
      return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_exist));   -- ya cerrada, idempotente
    end if;
  end if;

  select * into v_g from wh.guias where id_guia = v_id;
  if not found then return jsonb_build_object('ok',false,'error','Guía WH no encontrada: '||v_id); end if;

  if v_zona = '' then v_zona := upper(btrim(coalesce(v_g.id_zona,''))); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Falta zona (ni en el request ni en la guía WH)'); end if;

  -- Set ESCANEADO enviado por el front (en un re-cierre = previo precargado + nuevo, el TOTAL por línea).
  create temp table if not exists _esc_agg (cod_barra text primary key, cant numeric) on commit drop;
  truncate _esc_agg;
  for v_e in select * from jsonb_array_elements(v_esc) loop
    v_cb   := btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barra', ''));
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;
    insert into _esc_agg(cod_barra, cant) values (v_cb, v_cant)
      on conflict (cod_barra) do update set cant = _esc_agg.cant + excluded.cant;
  end loop;

  -- PREVIO escaneado (solo en re-cierre): sale del detalle guardado, para aplicar el DELTA.
  create temp table if not exists _prev_agg (cod_barra text primary key, cant numeric) on commit drop;
  truncate _prev_agg;
  if v_reabierto then
    insert into _prev_agg(cod_barra, cant)
      select upper(btrim(d->>'codBarra')), coalesce((d->>'escaneado')::numeric,0)
        from jsonb_array_elements(coalesce(v_exist.detalle,'[]'::jsonb)) d
       where nullif(btrim(coalesce(d->>'codBarra','')),'') is not null
         and coalesce((d->>'escaneado')::numeric,0) <> 0
      on conflict (cod_barra) do update set cant = _prev_agg.cant + excluded.cant;
  end if;

  -- Cómputo enviado(WH) vs escaneado(TOTAL) + detalle — idéntico a 592 (usa el set completo _esc_agg).
  with envi as (
      select d.cod_producto as cod_barra, min(d.linea) as linea, sum(d.cant_recibida) as enviado,
             nullif(string_agg(distinct nullif(btrim(coalesce(d.id_lote,'')),''), '/'), '') as lote,
             min(d.fecha_vencimiento) as venc
        from wh.guia_detalle d
       where d.id_guia = v_id
         and nullif(btrim(coalesce(d.cod_producto,'')),'') is not null
         and upper(coalesce(d.observacion,'')) <> 'ANULADO'
       group by d.cod_producto
  ),
  uni as (
      select coalesce(en.cod_barra, es.cod_barra) as cod_barra, en.linea as linea,
             coalesce(en.enviado, 0) as enviado, coalesce(es.cant, 0) as escaneado,
             en.lote as lote, en.venc as venc
        from envi en full join _esc_agg es on es.cod_barra = en.cod_barra
  )
  select
      coalesce(sum(enviado),0), coalesce(sum(escaneado),0), coalesce(sum(enviado - escaneado),0),
      coalesce(sum(case when enviado = escaneado then 1 else 0 end),0),
      coalesce(sum(case when enviado <> escaneado then 1 else 0 end),0),
      coalesce(jsonb_agg(jsonb_build_object(
          'codBarra', u.cod_barra, 'descripcion', coalesce(pr.descripcion, u.cod_barra),
          'enviado', u.enviado, 'escaneado', u.escaneado, 'dif', (u.enviado - u.escaneado),
          'lote', u.lote, 'venc', u.venc,
          'estado', case when u.enviado = u.escaneado then 'OK' when u.escaneado < u.enviado then 'FALTA' else 'SOBRA' end
        ) order by (u.enviado - u.escaneado) desc, u.cod_barra), '[]'::jsonb)
  into v_enviado_tot, v_escaneado_tot, v_dif_tot, v_ok_n, v_dif_n, v_detalle
  from uni u
  left join lateral (select descripcion from mos.productos pr where pr.codigo_barra = u.cod_barra limit 1) pr on true;

  v_estado := case when v_dif_n = 0 then 'COMPLETO' else 'INCOMPLETO' end;

  -- KARDEX + STOCK por DELTA (nuevo − previo). En primer cierre _prev_agg está vacío → delta = total (== 592).
  -- Recorremos la UNIÓN de códigos nuevos y previos para captar también correcciones a la baja / quitados.
  for v_cb in
    select cod_barra from _esc_agg union select cod_barra from _prev_agg
  loop
    v_cant := coalesce((select cant from _esc_agg  where cod_barra = v_cb), 0);
    v_prev := coalesce((select cant from _prev_agg where cod_barra = v_cb), 0);
    v_delta := v_cant - v_prev;
    if v_delta = 0 then continue; end if;
    select min(d.linea) into v_linea from wh.guia_detalle d where d.id_guia = v_id and d.cod_producto = v_cb;
    -- Kardex: trazabilidad de la recepción (idempotente por refId con sufijo de sesión). NO mueve stock por sí solo.
    perform me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb,
      'tipo', case when v_delta >= 0 then 'TRASLADO_IN' else 'TRASLADO_OUT' end, 'delta', v_delta,
      'refTipo', 'TRASLADO', 'refId', 'TRASLADO-WH:'||v_id||':'||coalesce(v_linea::text, 'X-'||v_cb)||v_sfx,
      'usuario', v_user, 'origen', v_origen));
    -- Saldo operativo SOLO si el flag lo pide (hoy OFF por WH_DESPACHO_SUMA_ZONA='1'): aplica el DELTA (no el total).
    if v_aplicar_stock then
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_cb, v_zona, v_delta, v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) + excluded.cantidad,
            usuario = excluded.usuario, fecha_ultimo_registro = now();
    end if;
  end loop;

  -- UPSERT de la verificación: primer cierre inserta; re-cierre (ABIERTA) actualiza. Conserva reaperturas.
  insert into me.zona_traslado_verificacion
    (id_guia, zona_id, tipo_guia, estado, total_enviado, total_escaneado, total_dif,
     lineas_ok, lineas_dif, detalle, stock_aplicado, usuario, verificado_ts, fecha_guia, reaperturas)
  values
    (v_ref, v_zona, coalesce(v_g.tipo,'SALIDA_ZONA_WH'), v_estado, v_enviado_tot, v_escaneado_tot, v_dif_tot,
     v_ok_n, v_dif_n, v_detalle, v_aplicar_stock, v_user, now(), v_g.fecha, v_sess)
  on conflict (id_guia) do update set
     estado = excluded.estado, total_enviado = excluded.total_enviado, total_escaneado = excluded.total_escaneado,
     total_dif = excluded.total_dif, lineas_ok = excluded.lineas_ok, lineas_dif = excluded.lineas_dif,
     detalle = excluded.detalle, stock_aplicado = excluded.stock_aplicado, usuario = excluded.usuario,
     verificado_ts = now()
  returning * into v_row;

  return jsonb_build_object('ok', true, 'dedup', false, 'reabierto', v_reabierto,
      'stockAplicado', v_aplicar_stock, 'data', to_jsonb(v_row));
end;
$fn$;
revoke all on function me.recibir_guia_wh_cerrar(jsonb) from public;
grant execute on function me.recibir_guia_wh_cerrar(jsonb) to service_role, authenticated;

select 'recepcion_wh_reabrir listo' ok;
