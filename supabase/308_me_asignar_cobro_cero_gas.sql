-- ============================================================================
-- 308_me_asignar_cobro_cero_gas.sql — Cutover cero-GAS de "asignar cobro a cajero"
-- ----------------------------------------------------------------------------
-- Reemplaza gas/Creditos.gs::asignarCobroACajero (escritura de dinero: designa qué
-- cajero cobra un crédito). Migra a UNA RPC atómica que valida (venta CREDITO/
-- POR_COBRAR + caja destino ABIERTA), es idempotente (advisory-lock por venta +
-- local_id anti-retry) e inserta en me.creditos_cobro_asignado — todo desde Postgres.
-- El push al cajero lo dispara el frontend MOS (reusa enviarPushSB + fan-out companion).
-- 100% Supabase. INERTE hasta prender ME_COBRO_DIRECTO (RPC → COBRO_OFF → MOS cae a GAS).
-- ============================================================================

-- flag de cutover (default OFF → MOS asigna por GAS)
insert into mos.config(clave, valor) values ('ME_COBRO_DIRECTO', '0')
  on conflict (clave) do nothing;

-- clave de idempotencia del cliente (anti doble-asignación por reintento de red)
alter table me.creditos_cobro_asignado add column if not exists local_id text;

create or replace function me.asignar_cobro_cajero(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idventa text := btrim(coalesce(p->>'idVenta',''));
  v_caja    text := btrim(coalesce(p->>'cajaDestino',''));
  v_metodo  text := upper(btrim(coalesce(p->>'metodoSugerido','')));
  v_msg     text := left(btrim(coalesce(p->>'mensajeAdmin','')), 140);
  v_admin   text := regexp_replace(btrim(coalesce(p->>'adminNombre','MOS-Admin')), '^admin:', '', 'i');
  v_local   text := btrim(coalesce(p->>'localId',''));
  v_ttl     int  := coalesce((p->>'horasTTL')::int, 1);
  v_fp text; v_corr text; v_cli text; v_cajaorig text; v_total numeric;
  v_vend text; v_estado text;
  v_prev   me.creditos_cobro_asignado%rowtype;
  v_idcobro text; v_venc timestamptz; v_now timestamptz := now();
begin
  -- solo el panel admin de MOS asigna cobros
  if coalesce(me.jwt_app(),'') <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- INERTE hasta el cutover
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_idventa = '' then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;
  if v_caja = ''    then return jsonb_build_object('ok',false,'error','cajaDestino requerida'); end if;
  if v_ttl not in (1,2,4,6) then v_ttl := 1; end if;

  -- 1) venta debe existir y estar pendiente (CREDITO / POR_COBRAR)
  select upper(coalesce(forma_pago,'')), coalesce(correlativo,''), coalesce(cliente_nombre,''),
         coalesce(id_caja,''), coalesce(total,0)
    into v_fp, v_corr, v_cli, v_cajaorig, v_total
    from me.ventas where id_venta = v_idventa;
  if not found then return jsonb_build_object('ok',false,'error','VENTA_NO_ENCONTRADA'); end if;
  if v_fp not in ('CREDITO','POR_COBRAR') then
    return jsonb_build_object('ok',false,'error','VENTA_NO_PENDIENTE');
  end if;

  -- 2) caja destino ABIERTA + su cajero
  select coalesce(vendedor,''), upper(coalesce(estado,'')) into v_vend, v_estado
    from me.cajas where id_caja = v_caja;
  if not found or v_estado <> 'ABIERTA' then
    return jsonb_build_object('ok',false,'error','CAJA_DEST_NO_ABIERTA');
  end if;

  -- 3) idempotencia: serializar por venta y no permitir 2 ASIGNADO a la vez
  perform pg_advisory_xact_lock(hashtext('cobro:'||v_idventa));
  -- retry del MISMO request (mismo local_id) → devolver el existente (éxito idempotente)
  if v_local <> '' then
    select * into v_prev from me.creditos_cobro_asignado where local_id = v_local limit 1;
    if found then
      return jsonb_build_object('ok',true,'idCobro',v_prev.id_cobro,'cajeroDestino',v_prev.vendedor_dest,
        'horasTTL',v_prev.horas_ttl,'fechaVencimiento',to_char(v_prev.fecha_vencimiento at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
        'mensaje','Cobro ya asignado a '||v_prev.vendedor_dest,'idempotente',true,'via','directo');
    end if;
  end if;
  -- otra asignación viva para esta venta (distinto request) → rechazar (paridad GAS)
  select * into v_prev from me.creditos_cobro_asignado
   where id_venta = v_idventa and upper(coalesce(estado,'')) = 'ASIGNADO' limit 1;
  if found then
    return jsonb_build_object('ok',false,'error','YA_ASIGNADO');
  end if;

  -- 4) crear la asignación
  v_venc := v_now + (v_ttl || ' hours')::interval;
  v_idcobro := 'CB-' || (extract(epoch from clock_timestamp())*1000)::bigint::text || '-' || substr(md5(random()::text||v_idventa),1,4);
  insert into me.creditos_cobro_asignado (
    id_cobro, id_venta, caja_destino, vendedor_dest, metodo_sug, estado, admin_asignador,
    fecha_asig, fecha_res, razon, id_caja_origen, monto, cliente_nombre, correlativo,
    fecha_vencimiento, horas_ttl, mensaje_admin, reasignaciones, local_id
  ) values (
    v_idcobro, v_idventa, v_caja, v_vend, v_metodo, 'ASIGNADO', v_admin,
    v_now, null, '', v_cajaorig, v_total, v_cli, v_corr,
    v_venc, v_ttl, v_msg, 0, nullif(v_local,'')
  );

  return jsonb_build_object(
    'ok', true, 'idCobro', v_idcobro, 'cajeroDestino', v_vend, 'horasTTL', v_ttl,
    'fechaVencimiento', to_char(v_venc at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
    'mensaje', 'Cobro asignado a '||v_vend||' · vence en '||v_ttl||'h',
    'via', 'directo',
    -- payload para el push que dispara el frontend (fan-out a los equipos del cajero)
    'pushTitulo', '💳 Cobro pendiente · ' || coalesce(nullif(v_cli,''),'cliente'),
    'pushCuerpo', v_admin || ' te asignó un crédito de S/ ' || to_char(v_total,'FM999999990.00') ||
                  case when v_metodo <> '' then ' ('||v_metodo||')' else '' end || '. Tocá para cobrar.'
  );
end;
$fn$;
revoke all on function me.asignar_cobro_cajero(jsonb) from public;
grant execute on function me.asignar_cobro_cajero(jsonb) to authenticated, service_role;
