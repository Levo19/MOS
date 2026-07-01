-- ============================================================
-- 264_review500_fixes_live.sql
-- Fixes de la revisión adversarial 500x — hallazgos LIVE (money/stock/seguridad).
-- ------------------------------------------------------------
-- C1 (CRITICAL): me.venta_reposicion_datos reponía por código CRUDO (presentación) mientras
--   el cierre descuenta por CANÓNICO (mos._venta_canonico) → stock fantasma asimétrico (factor≠1).
--   Fix: resolver totales_por_cod al canónico, idéntico a me.zona_descontar_venta. Corrige AMBOS
--   paths (la RPC me.anular_venta y el GAS _reponerStockVentaAnulada leen esta RPC). El pickup
--   tambien queda correcto (espera codigo canonico).
-- H9 (HIGH→MED): me.zona_descontar_venta filtraba forma_pago con `<> 'ANULADO'` EXACTO → una NV
--   convertida (forma_pago='ANULADO_CONVERSION') NO se excluía → doble descuento de stock pre-cierre.
--   Fix: `not like 'ANULADO%'` (alinea con cierre/efectos). Se dispara con conversión NV→CPE (GAS o Etapa4).
-- H5+MED (HIGH/MED seguridad): wh.pickup_descontar_venta — LIKE-injection (idCaja/idGuiaME con %),
--   gate demasiado amplio, y no excluía estados terminales del acumulador (ABSORBIDO/MIGRADO/ELIMINADO).
--   Fix: rechazar metacaracteres LIKE + restringir gate a ('','MOS') + ampliar skip de estados.
-- MED (concurrencia): me.editar_forma_pago / me.editar_cliente leían sin FOR UPDATE → lost-update
--   del historial ante edición concurrente del mismo ticket. Fix: FOR UPDATE (igual que anular).
-- ============================================================

-- ── C1: me.venta_reposicion_datos con resolución CANÓNICA ──
create or replace function me.venta_reposicion_datos(p_id_venta text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_app    text := me.jwt_app();
  v_id     text := nullif(btrim(coalesce(p_id_venta,'')),'');
  v_caja   text;
  v_forma  text;
  v_zona   text;
  v_cerr   boolean := false;
  v_tot    jsonb;
begin
  if v_app not in ('', 'MOS', 'mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'ID_VENTA_REQUERIDO');
  end if;

  select id_caja, forma_pago into v_caja, v_forma
  from me.ventas where id_venta = v_id limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'VENTA_NO_ENCONTRADA', 'id_venta', v_id);
  end if;

  v_caja := nullif(btrim(coalesce(v_caja,'')),'');
  if v_caja is null then
    return jsonb_build_object('ok', true, 'id_venta', v_id, 'id_caja', '',
      'caja_cerrada', false, 'zona', '', 'totales_por_cod', '{}'::jsonb,
      'forma_pago', coalesce(v_forma,''));
  end if;

  select gc.zona_id into v_zona
  from me.guias_cabecera gc
  where gc.tipo = 'SALIDA_VENTAS'
    and coalesce(gc.observacion,'') ilike '%'||v_caja||'%'
  order by gc.fecha desc nulls last
  limit 1;
  v_cerr := found;

  -- totales por código CANÓNICO (mismo criterio que me.zona_descontar_venta:29-36) →
  -- la reposición ENTRADA repone el MISMO canónico y la MISMA magnitud (cant×factor unidad / cant peso)
  -- que descontó el cierre. Antes agrupaba por código crudo → asimetría (stock fantasma).
  select coalesce(jsonb_object_agg(cb, cant), '{}'::jsonb)
  into v_tot
  from (
    select cv.canon_cod as cb, sum(cv.cant) as cant
    from me.ventas_detalle d
    cross join lateral mos._venta_canonico(d.cod_barras, d.cantidad::numeric, d.unidad_medida) cv
    where d.id_venta = v_id
      and coalesce(nullif(btrim(cv.canon_cod),''),'') <> ''
      and cv.cant > 0
    group by cv.canon_cod
  ) t;

  return jsonb_build_object(
    'ok', true, 'id_venta', v_id, 'id_caja', v_caja,
    'caja_cerrada', v_cerr, 'zona', coalesce(v_zona,''),
    'totales_por_cod', v_tot, 'forma_pago', coalesce(v_forma,''));
end;
$function$;
revoke all on function me.venta_reposicion_datos(text) from public, anon;
grant execute on function me.venta_reposicion_datos(text) to authenticated, service_role;


-- ── H9: me.zona_descontar_venta excluye ANULADO% (no solo ANULADO exacto) ──
create or replace function me.zona_descontar_venta(p jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_caja   text := btrim(coalesce(p->>'idCaja',''));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
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

  create temp table _venta_agg (cod_barra text primary key, cant numeric) on commit drop;
  insert into _venta_agg(cod_barra, cant)
  select cv.canon_cod, sum(cv.cant)
    from me.ventas v join me.ventas_detalle vd on vd.id_venta = v.id_venta
    cross join lateral mos._venta_canonico(vd.cod_barras, vd.cantidad::numeric, vd.unidad_medida) cv
   where v.id_caja = v_caja and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'   -- 264 H9: excluye ANULADO_CONVERSION
     and coalesce(nullif(btrim(cv.canon_cod),''),'') <> '' and cv.cant > 0
   group by cv.canon_cod
  on conflict (cod_barra) do update set cant = _venta_agg.cant + excluded.cant;

  for v_cb, v_cant in select cod_barra, cant from _venta_agg loop
    v_kres := me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb, 'tipo', 'SALIDA_VENTA', 'delta', (-v_cant),
      'refTipo', 'VENTA', 'refId', 'VENTA-CAJA:'||v_caja||':'||v_cb, 'usuario', v_user, 'origen', v_origen));

    if coalesce((v_kres->>'dedup')::boolean, false) then
      v_dedup := v_dedup + 1;
    else
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


-- ── H5+MED: wh.pickup_descontar_venta — anti LIKE-injection + gate estricto + skip estados acumulador ──
create or replace function wh.pickup_descontar_venta(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app    text := me.jwt_app();
  v_caja   text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_guiaME text := nullif(btrim(coalesce(p->>'idGuiaME','')),'');
  v_anul   jsonb := coalesce(p->'itemsAnulados', '[]'::jsonb);
  v_pk     record;
  v_items  jsonb;
  v_final  jsonb := '[]'::jsonb;
  v_it     jsonb;
  v_an     jsonb;
  v_cod    text;
  v_qty    numeric;
  v_sol    numeric;
  v_ajustes int := 0;
  v_codigos jsonb;
  v_matched boolean;
begin
  -- Gate estricto: solo el caller anidado (me.anular_venta, app ''/MOS). Antes admitía
  -- mosExpress/warehouseMos sin caller legítimo → cualquier token POS podía mutar pickups.
  if v_app not in ('','MOS') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- Anti LIKE-injection: idCaja/idGuiaME van a un ILIKE; rechazar metacaracteres (% _ \).
  if v_caja ~ '[%_\\]' or coalesce(v_guiaME,'') ~ '[%_\\]' then
    return jsonb_build_object('ok', false, 'error', 'ID_INVALIDO');
  end if;
  if jsonb_typeof(v_anul) <> 'array' or jsonb_array_length(v_anul) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Sin itemsAnulados');
  end if;
  if v_caja is null and v_guiaME is null then
    return jsonb_build_object('ok', false, 'error', 'Requiere idCaja o idGuiaME');
  end if;

  select * into v_pk
  from wh.pickups
  where ( (v_guiaME is not null and notas ilike '%idGuiaME='||v_guiaME||'%')
       or (v_caja   is not null and notas ilike '%idCaja='||v_caja||'%') )
  order by fecha_creado desc nulls last
  limit 1
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Pickup origen no encontrado');
  end if;

  -- Estados terminales / del acumulador-v2 → no ajustar (incluye ABSORBIDO/MIGRADO/ELIMINADO,
  -- que son solo-Supabase y no estaban en la lista heredada del GAS Sheet-side).
  if v_pk.estado in ('COMPLETADO','CANCELADO','PARCIAL','ABSORBIDO','MIGRADO','ELIMINADO') then
    return jsonb_build_object('ok', true, 'ajustado', false,
      'motivo', 'Pickup ya cerrado: '||v_pk.estado);
  end if;

  v_items := coalesce(v_pk.items, '[]'::jsonb);
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok', true, 'ajustado', false, 'motivo', 'Sin items');
  end if;

  for v_it in select value from jsonb_array_elements(v_items) loop
    v_sol     := coalesce((v_it->>'solicitado')::numeric, 0);
    v_codigos := coalesce(v_it->'codigosOriginales', '[]'::jsonb);
    for v_an in select value from jsonb_array_elements(v_anul) loop
      v_cod := upper(btrim(coalesce(v_an->>'codigoBarra','')));
      v_qty := coalesce((v_an->>'cantidad')::numeric, 0);
      if v_cod = '' or v_qty <= 0 then continue; end if;
      v_matched := exists (
        select 1 from jsonb_array_elements_text(v_codigos) c
        where upper(btrim(c)) = v_cod
      );
      if v_matched then
        v_sol := greatest(0, v_sol - v_qty);
        v_ajustes := v_ajustes + 1;
      end if;
    end loop;
    if v_sol > 0 then
      v_final := v_final || jsonb_build_array(jsonb_set(v_it, '{solicitado}', to_jsonb(v_sol)));
    end if;
  end loop;

  if jsonb_array_length(v_final) = 0 then
    update wh.pickups
      set estado = 'CANCELADO', items = '[]'::jsonb, ultima_actividad = now()
      where id_pickup = v_pk.id_pickup;
    return jsonb_build_object('ok', true, 'ajustado', true, 'ajustes', v_ajustes,
      'cancelado', true, 'idPickup', v_pk.id_pickup);
  end if;

  update wh.pickups
    set items = v_final, ultima_actividad = now()
    where id_pickup = v_pk.id_pickup;
  return jsonb_build_object('ok', true, 'ajustado', true, 'ajustes', v_ajustes,
    'cancelado', false, 'idPickup', v_pk.id_pickup);
end;
$fn$;
revoke all on function wh.pickup_descontar_venta(jsonb) from public, anon;
grant execute on function wh.pickup_descontar_venta(jsonb) to authenticated, service_role;


-- ── MED: FOR UPDATE en me.editar_forma_pago y me.editar_cliente (evita lost-update del historial) ──
create or replace function me.editar_forma_pago(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $fn$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_new   text := nullif(btrim(coalesce(p->>'formaPagoNueva','')),'');
  v_mot   text := nullif(btrim(coalesce(p->>'motivo','')),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_ant   text;
  v_hist  jsonb;
begin
  if v_app not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id  is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;
  if v_new is null then return jsonb_build_object('ok', false, 'error', 'formaPagoNueva requerida'); end if;
  if v_mot is null then return jsonb_build_object('ok', false, 'error', 'motivo es obligatorio para auditoría'); end if;

  -- [500x MED] tomar el lock de la venta ANTES del FOR UPDATE (mismo namespace 'cobro:'||idVenta que
  -- confirmar/directo, y en el MISMO orden lock→row para no crear ABBA): serializa la edición manual
  -- de forma_pago con un cobro en vuelo de la misma venta.
  perform pg_advisory_xact_lock(hashtext('cobro:'||v_id));
  select forma_pago, historial_cambios into v_ant, v_hist
  from me.ventas where id_venta = v_id for update;   -- 264: FOR UPDATE serializa read-then-append
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venta '||v_id||' no encontrada');
  end if;
  if upper(coalesce(v_ant,'')) like 'ANULADO%' then
    return jsonb_build_object('ok', false, 'error', 'No se puede modificar un ticket anulado');
  end if;

  -- [500x MED] si el ticket deja de ser un crédito pendiente, anular cualquier cobro ASIGNADO vivo
  -- (si no, el cajero podría cobrarlo otra vez = doble cobro de la misma deuda).
  if upper(v_new) not in ('CREDITO','POR_COBRAR') then
    update me.creditos_cobro_asignado
       set estado='CANCELADO_ADMIN', fecha_res=now(),
           razon='Anulado por edición de forma de pago', updated_at=now()
     where id_venta = v_id and upper(coalesce(estado,''))='ASIGNADO';
  end if;

  update me.ventas
    set forma_pago = v_new,
        historial_cambios = me._venta_hist_append(v_hist, jsonb_build_object(
          'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
          'source', 'ME_EDITAR_FORMA_PAGO', 'accion', 'editar_forma_pago',
          'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes',coalesce(v_ant,''),'despues',v_new)),
          'autorizadoPor', v_auth, 'motivo', v_mot)),
        updated_at = now()
    where id_venta = v_id;

  return jsonb_build_object('ok', true, 'mensaje', 'Forma de pago actualizada',
    'idVenta', v_id, 'antes', coalesce(v_ant,''), 'despues', v_new);
end;
$fn$;
revoke all on function me.editar_forma_pago(jsonb) from public, anon;
grant execute on function me.editar_forma_pago(jsonb) to authenticated, service_role;

create or replace function me.editar_cliente(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $fn$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_doc   text := btrim(coalesce(p->>'clienteDoc',''));
  v_nom   text := btrim(coalesce(p->>'clienteNombre',''));
  v_dir   text := nullif(btrim(coalesce(p->>'clienteDireccion','')),'');
  v_mot   text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_tipo  text;  v_nf text;  v_docA text;  v_nomA text;  v_hist jsonb;
  v_tdc   smallint;
  v_cambios jsonb := '[]'::jsonb;
begin
  if v_app not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;

  select tipo_doc, nf_estado, cliente_doc, cliente_nombre, historial_cambios
    into v_tipo, v_nf, v_docA, v_nomA, v_hist
  from me.ventas where id_venta = v_id for update;   -- 264: FOR UPDATE serializa read-then-append
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venta '||v_id||' no encontrada');
  end if;

  if coalesce(v_tipo,'') <> 'NOTA_DE_VENTA' and coalesce(v_nf,'') = 'EMITIDO' then
    return jsonb_build_object('ok', false,
      'error', 'CPE emitido ('||coalesce(v_tipo,'')||') no se puede editar. Solicite la baja del CPE primero.');
  end if;

  v_tdc := case when length(v_doc) = 8 then 1 when length(v_doc) = 11 then 6 else 0 end;

  if coalesce(v_docA,'') <> v_doc then
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object('campo','Cliente_Doc','antes',coalesce(v_docA,''),'despues',v_doc));
  end if;
  if coalesce(v_nomA,'') <> v_nom then
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object('campo','Cliente_Nombre','antes',coalesce(v_nomA,''),'despues',v_nom));
  end if;

  update me.ventas
    set cliente_doc = v_doc,
        cliente_nombre = v_nom,
        tipo_doc_cliente = v_tdc,
        historial_cambios = case when jsonb_array_length(v_cambios) > 0
          then me._venta_hist_append(v_hist, jsonb_build_object(
            'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
            'source', 'ME_EDITAR_CLIENTE', 'accion', 'editar_cliente',
            'cambios', v_cambios, 'autorizadoPor', v_auth, 'motivo', v_mot))
          else historial_cambios end,
        updated_at = now()
    where id_venta = v_id;

  -- Back-fill del directorio de clientes frecuentes (paridad con verificarYAgregaCliente del GAS).
  -- No pisa nombre/direccion existentes con vacío (solo rellena si estaban vacíos).
  if v_doc <> '' and v_nom <> '' then
    insert into me.clientes_frecuentes (documento, nombre, tipo_doc, direccion)
    values (v_doc, v_nom, v_tdc::text, v_dir)
    on conflict (documento) do update
      set nombre = case when btrim(coalesce(me.clientes_frecuentes.nombre,''))='' then excluded.nombre else me.clientes_frecuentes.nombre end,
          direccion = coalesce(nullif(excluded.direccion,''), me.clientes_frecuentes.direccion);
  end if;

  return jsonb_build_object('ok', true, 'mensaje', 'Cliente actualizado',
    'idVenta', v_id, 'cambios', jsonb_array_length(v_cambios));
end;
$fn$;
revoke all on function me.editar_cliente(jsonb) from public, anon;
grant execute on function me.editar_cliente(jsonb) to authenticated, service_role;
