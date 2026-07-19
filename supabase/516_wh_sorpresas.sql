-- 516_wh_sorpresas.sql — 🎯 PRODUCTOS SORPRESA (auditoría de escaneo real) · FASE 0 backend
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- El admin (MASTER/ADMIN/ascendido acceso_mos) quita o agrega unidades de una guía SALIDA_ZONA
-- y lo registra. LA SORPRESA ES LA CORRECCIÓN: ajusta wh.guia_detalle.cant_recibida (el baseline
-- que me.recibir_guia_wh usa como "enviado") — sin guía de ajuste. El operador de zona NO ve el
-- esperado (146 ya es ciego por diseño): cuenta físico. Al cerrar la recepción (146 escribe
-- me.zona_traslado_verificacion con detalle [{codBarra,enviado,escaneado,dif}]), un TRIGGER evalúa:
--   escaneado == corregido → PASÓ · == original (el papel) → FALLÓ · otro → DISCREPANCIA
-- y pushea el veredicto al admin. Decisión dueño: FALLÓ = observación con monto, SIN descuento.
-- GATE: clave admin de 8 dígitos verificada server-side (mos._validar_clave_admin_core, honra
-- acceso_mos → Jorgenis puede). GUARDIA: producto no despachado en la guía → PRODUCTO_NO_EN_GUIA.
-- STOCK: si la guía WH ya está CERRADA (stock ya descontado), el delta ajusta wh.stock atómico
-- (quitar 1 → +1 vuelve al andamio; mandar +2 → −2, validando disponible). ABIERTA → nada (el
-- cierre descuenta lo corregido). Idempotente por id_sorpresa (localId del cliente).
-- ════════════════════════════════════════════════════════════════════════════════════════════════

create table if not exists wh.sorpresas (
  id_sorpresa      text primary key,
  id_guia          text not null,
  id_zona          text,
  cod_producto     text not null,
  descripcion      text,
  delta            numeric not null,          -- ±: negativo=quitó · positivo=mandó de más
  cant_original    numeric not null,          -- lo que decía la guía (y el ticket impreso)
  cant_corregida   numeric not null,          -- baseline real tras la sorpresa
  admin_nombre     text,
  ts_registro      timestamptz default now(),
  estado           text not null default 'ESPERANDO',  -- ESPERANDO | PASO | FALLO | DISCREPANCIA
  operador_evaluado text,
  cant_registrada  numeric,
  ts_resultado     timestamptz,
  costo_unitario   numeric                    -- para la observación con monto (S/)
);
create index if not exists idx_wh_sorpresas_guia on wh.sorpresas(id_guia);
create index if not exists idx_wh_sorpresas_estado on wh.sorpresas(estado);

-- ── RPC: registrar sorpresa ─────────────────────────────────────────────────────────────────────
-- p: { id_sorpresa(localId), id_guia, cod_producto, delta, clave_admin, admin?, app?, device? }
create or replace function wh.registrar_sorpresa(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_orig   numeric;
  v_id     text := nullif(btrim(coalesce(p->>'id_sorpresa','')), '');
  v_guia   text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_cod    text := nullif(btrim(coalesce(p->>'cod_producto','')), '');
  v_delta  numeric := wh._num(p->>'delta');
  v_clave  text := nullif(btrim(coalesce(p->>'clave_admin','')), '');
  v_auth   jsonb;
  v_g      record;
  v_d      record;
  v_ya     record;
  v_nueva  numeric;
  v_costo  numeric;
begin
  if not wh._claim_ok() and not mos._claim_ok() then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_guia is null or v_cod is null or v_delta = 0 then
    return jsonb_build_object('ok',false,'error','PARAMS_INVALIDOS'); end if;

  -- idempotencia (reintento del cliente)
  select * into v_ya from wh.sorpresas where id_sorpresa = v_id;
  if found then return jsonb_build_object('ok',true,'dedup',true,'estado',v_ya.estado); end if;

  -- GATE admin: clave 8 díg verificada por el core central (honra acceso_mos → ascendidos)
  v_auth := mos._validar_clave_admin_core(v_clave, 'SORPRESA', v_guia,
              coalesce(p->>'app','WH'), coalesce(p->>'device',''),
              'sorpresa ' || v_cod || ' Δ' || v_delta);
  if coalesce(v_auth->>'autorizado','false') <> 'true' then
    return jsonb_build_object('ok',false,'error','CLAVE_INVALIDA',
             'detalle', coalesce(v_auth->>'error','clave rechazada')); end if;

  -- guía debe ser SALIDA_ZONA y la recepción NO debe estar cerrada aún
  select * into v_g from wh.guias where id_guia = v_guia;
  if not found or upper(coalesce(v_g.tipo,'')) <> 'SALIDA_ZONA' then
    return jsonb_build_object('ok',false,'error','GUIA_INVALIDA'); end if;
  if exists (select 1 from me.zona_traslado_verificacion where id_guia = 'WH:' || v_guia) then
    return jsonb_build_object('ok',false,'error','SORPRESA_TARDE','detalle','la zona ya cerró la recepción'); end if;

  -- GUARDIA: el producto debe existir como línea despachada de ESTA guía
  select * into v_d from wh.guia_detalle
   where id_guia = v_guia and upper(cod_producto) = upper(v_cod)
   order by linea limit 1;
  if not found then
    return jsonb_build_object('ok',false,'error','PRODUCTO_NO_EN_GUIA'); end if;

  v_orig  := coalesce(v_d.cant_recibida,0);
  v_nueva := v_orig + v_delta;
  if v_nueva < 0 then
    return jsonb_build_object('ok',false,'error','DELTA_EXCEDE','detalle','la línea tiene ' || coalesce(v_d.cant_recibida,0)); end if;

  -- LA SORPRESA ES LA CORRECCIÓN: ajustar el baseline de la línea (atómico)
  update wh.guia_detalle set cant_recibida = v_nueva
   where id_guia = v_guia and linea = v_d.linea;

  -- STOCK: si la guía ya CERRÓ (salida ya descontada), devolver/quitar el delta al andamio.
  -- quitar físico (delta<0) → esa unidad vuelve al almacén → stock +|delta|.
  -- mandar de más (delta>0) → salió del almacén → stock −delta (atómico, sin validar negativo:
  -- paridad con el resto del sistema WH que tolera ajustes admin).
  if upper(coalesce(v_g.estado,'')) = 'CERRADA' then
    update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_delta,
                        ultima_actualizacion = now()
     where upper(cod_producto) = upper(v_cod);
  end if;

  -- costo para la observación con monto (mejor esfuerzo; 0 si no hay)
  begin
    select coalesce(nullif(precio_unitario,0),0) into v_costo
      from wh.guia_detalle where id_guia = v_guia and linea = v_d.linea;
  exception when others then v_costo := 0; end;

  insert into wh.sorpresas(id_sorpresa,id_guia,id_zona,cod_producto,descripcion,delta,
                           cant_original,cant_corregida,admin_nombre,costo_unitario)
  values (v_id, v_guia, v_g.id_zona, v_cod, null, v_delta,
          v_orig, v_nueva,
          coalesce(v_auth->>'nombre', nullif(btrim(coalesce(p->>'admin','')),''), 'admin'),
          v_costo);

  return jsonb_build_object('ok',true,'id_sorpresa',v_id,
           'cant_original', v_orig, 'cant_corregida', v_nueva);
end; $fn$;
revoke all on function wh.registrar_sorpresa(jsonb) from public, anon;
grant execute on function wh.registrar_sorpresa(jsonb) to service_role, authenticated;

-- ── Lectura: sorpresas (para WH lista del día + MOS panel/score) ───────────────────────────────
create or replace function wh.sorpresas_lista(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select case when wh._claim_ok() or mos._claim_ok()
    then jsonb_build_object('ok', true, 'data', coalesce((
      select jsonb_agg(jsonb_build_object(
        'idSorpresa', s.id_sorpresa, 'idGuia', s.id_guia, 'idZona', s.id_zona,
        'codProducto', s.cod_producto, 'delta', s.delta,
        'cantOriginal', s.cant_original, 'cantCorregida', s.cant_corregida,
        'admin', s.admin_nombre, 'ts', s.ts_registro, 'estado', s.estado,
        'operador', s.operador_evaluado, 'cantRegistrada', s.cant_registrada,
        'tsResultado', s.ts_resultado, 'costo', s.costo_unitario)
        order by s.ts_registro desc)
      from wh.sorpresas s
      where s.ts_registro >= now() - make_interval(days => least(greatest(coalesce((p->>'dias')::int, 30),1),365))
    ), '[]'::jsonb))
    else jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA') end;
$fn$;
revoke all on function wh.sorpresas_lista(jsonb) from public, anon;
grant execute on function wh.sorpresas_lista(jsonb) to service_role, authenticated;

-- ── TRIGGER de evaluación: cuando la zona cierra la recepción (146 inserta 'WH:<guia>') ────────
create or replace function wh._evaluar_sorpresas_de_verificacion()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare
  v_guia text;
  s record;
  v_lin jsonb;
  v_esc numeric;
  v_res text;
begin
  if new.id_guia not like 'WH:%' then return new; end if;
  v_guia := substring(new.id_guia from 4);
  for s in select * from wh.sorpresas where id_guia = v_guia and estado = 'ESPERANDO' loop
    select l into v_lin from jsonb_array_elements(coalesce(new.detalle,'[]'::jsonb)) l
     where upper(coalesce(l->>'codBarra','')) = upper(s.cod_producto) limit 1;
    if v_lin is null then
      v_esc := null; v_res := 'DISCREPANCIA';
    else
      v_esc := wh._num(v_lin->>'escaneado');
      v_res := case when v_esc = s.cant_corregida then 'PASO'
                    when v_esc = s.cant_original  then 'FALLO'
                    else 'DISCREPANCIA' end;
    end if;
    update wh.sorpresas
       set estado = v_res, operador_evaluado = new.usuario,
           cant_registrada = v_esc, ts_resultado = now()
     where id_sorpresa = s.id_sorpresa;
    -- push al admin (best-effort, jamás rompe el cierre de recepción)
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMIN')),
        'titulo', case v_res when 'PASO' then '🎯✅ Sorpresa PASADA'
                             when 'FALLO' then '🎯❌ Sorpresa FALLADA'
                             else '🎯⚠️ Sorpresa con discrepancia' end,
        'cuerpo', coalesce(new.usuario,'operador') || ' registró ' || coalesce(v_esc::text,'—')
                  || ' de ' || s.cod_producto || ' (papel: ' || s.cant_original
                  || ' · real: ' || s.cant_corregida || ') · ' || coalesce(new.zona_id,''),
        'data', jsonb_build_object('tipo','sorpresa','idSorpresa',s.id_sorpresa,'resultado',v_res)));
    exception when others then null; end;
  end loop;
  return new;
end; $fn$;

drop trigger if exists trg_evaluar_sorpresas on me.zona_traslado_verificacion;
create trigger trg_evaluar_sorpresas
  after insert or update on me.zona_traslado_verificacion
  for each row execute function wh._evaluar_sorpresas_de_verificacion();
