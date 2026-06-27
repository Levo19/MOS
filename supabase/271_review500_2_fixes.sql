-- 271_review500_2_fixes.sql — Correcciones de la 2ª revisión 500x (post-cutover CPE/serie).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- H7  (money/fiscal, LIVE): me.editar_cliente bloqueaba SOLO nf_estado='EMITIDO' → un CPE en PENDIENTE/
--      RECHAZADO/NULL (correlativo YA quemado, comprobante ya enviado o por reconciliar a NubeFact) podía
--      mutar cliente_doc/nombre/tipo_doc_cliente → sombra fiscal divergente de SUNAT. Caso real vivo:
--      V-1775671077612 BOLETA nf_estado=NULL, correlativo B001-000001 consumido. FIX: bloquear por TIPO,
--      no por estado (en cuanto crear_cpe_directo grabó la fila, una BOLETA/FACTURA NUNCA es editable).
-- MED16(cero-gas): me.crear_venta_directa confiaba en p->>'serie' (que el front saca de la Hoja vía GAS
--      getEstacionesParaApp → se atrasa). Ahora RESUELVE la serie NV desde mos.series_documentales
--      (estación→zona), igual que crear_cpe_directo (SQL 270). Fallback al serie del front si no hay fila.
-- LOW17/19 (fiscal, latente): crear_cpe_directo resolvía serie por zona con `limit 1` sin desempate →
--      no determinístico si una zona tuviera >1 serie activa del mismo tipo. FIX: tiebreaker `, id_serie asc`.
-- Fiscal/money-safe: solo cambia DE DÓNDE sale la serie y QUÉ se puede editar; idempotencia, total==Σ y
--      correlativo atómico quedan byte-iguales.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── H7: me.editar_cliente — bloquear edición de titular fiscal en CUALQUIER CPE (por TIPO) ──
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
  v_tdc_in text := nullif(regexp_replace(coalesce(p->>'tipoDocCliente',''),'\D','','g'),'');
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
  from me.ventas where id_venta = v_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venta '||v_id||' no encontrada');
  end if;

  -- [H7 · 500x-2] Bloquear por TIPO, no por estado: una BOLETA/FACTURA ya minteó el correlativo y fue
  -- (o será reconciliada) a NubeFact/SUNAT → su titular fiscal NUNCA debe cambiarse. PENDIENTE/RECHAZADO/
  -- NULL son post-mint, no pre. Solo NOTA_DE_VENTA es editable; para CPE → dar de baja y reemitir.
  if coalesce(v_tipo,'') <> 'NOTA_DE_VENTA' then
    return jsonb_build_object('ok', false,
      'error', 'Comprobante '||coalesce(nullif(v_tipo,''),'(sin tipo)')||' (estado '||coalesce(nullif(v_nf,''),'(sin)')||
               ') no editable: el titular fiscal no se cambia tras mintear el correlativo. Solo NOTA_DE_VENTA. Para CPE: dar de baja y reemitir.');
  end if;

  v_tdc := case
    when v_tdc_in is not null then v_tdc_in::smallint
    when length(v_doc) = 8  then 1
    when length(v_doc) = 11 then 6
    else 0 end;

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

-- ── MED16: me.crear_venta_directa — serie NV autoritativa desde Supabase (simetría con crear_cpe_directo) ──
create or replace function me.crear_venta_directa(p jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $fn$
declare
  v_app   text := me.jwt_app();
  v_sub   text := me.jwt_sub();
  v_ref   text := nullif(btrim(coalesce(p->>'ref_local','')), '');
  v_serie text := nullif(btrim(coalesce(p->>'serie','')), '');
  v_tipo  text := upper(coalesce(p->>'tipo_doc',''));
  v_caja  text := coalesce(p->>'id_caja','');
  v_caja_ok boolean;
  v_zona  text;
  v_est   text := nullif(btrim(coalesce(p->>'estacion','')), '');   -- [MED16 500x-2]
  v_serie_sd text;                                                  -- [MED16 500x-2]
  v_total numeric := coalesce((p->>'total')::numeric, 0);
  v_suma  numeric;
  v_nit   int;
  v_ex    me.ventas%rowtype;
  v_num   bigint;
  v_corr  text;
  v_id    text;
  v_item  jsonb;
  v_linea int := 0;
  v_ins   int;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if v_ref   is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  if v_tipo not in ('NOTA_DE_VENTA','NV','') then return jsonb_build_object('status','error','error','SOLO_NV_DIRECTO'); end if;

  -- idempotencia PRIMERO (reintento → misma venta, sin re-validar)
  select * into v_ex from me.ventas where ref_local = v_ref limit 1;
  if found then
    return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo);
  end if;

  -- total == Σ(items.subtotal)
  select coalesce(sum((it->>'subtotal')::numeric), 0), count(*)
    into v_suma, v_nit
  from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it;
  if v_nit > 0 and abs(v_total - v_suma) > 0.01 then
    return jsonb_build_object('status','error','error','TOTAL_NO_CUADRA',
                              'detalle', 'total='||v_total||' suma_items='||v_suma);
  end if;

  -- caja ABIERTA + zona de la caja
  select (estado = 'ABIERTA'), zona_id into v_caja_ok, v_zona
  from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then
    return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA');
  end if;

  -- [MED16 · 500x-2] SERIE NV autoritativa desde Supabase (mos.series_documentales): estación primero,
  -- luego zona. OJO: el front manda tipo_doc='NOTA_DE_VENTA' pero la tabla guarda 'NOTA_VENTA' → match IN.
  -- Si no hay fila, cae al serie del front (compat). Resiste el drift de la Hoja stale (SQL 269).
  select serie into v_serie_sd from mos.series_documentales
   where activo and upper(tipo_documento) in ('NOTA_VENTA','NOTA_DE_VENTA','NV')
     and ( (v_est is not null and id_estacion = v_est)
        or (v_zona is not null and v_zona <> '' and id_zona = v_zona) )
   order by (v_est is not null and id_estacion = v_est) desc, id_serie asc
   limit 1;
  if v_serie_sd is not null and btrim(v_serie_sd) <> '' then v_serie := btrim(v_serie_sd); end if;
  if v_serie is null then return jsonb_build_object('status','error','error','SERIE_REQUERIDA'); end if;

  -- correlativo atómico (idempotente por ref_local)
  v_num  := me.siguiente_correlativo(v_serie, v_ref);
  v_corr := v_serie || '-' || lpad(v_num::text, 6, '0');
  v_id   := 'V-' || (floor(extract(epoch from clock_timestamp()) * 1000))::bigint::text
                 || '-' || substr(md5(random()::text || clock_timestamp()::text || v_ref), 1, 8);

  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
                         tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio,
                         ref_local, obs, tipo_doc_cliente, zona_id)
  values (v_id, now(), p->>'vendedor', p->>'estacion', coalesce(p->>'cliente_doc',''), coalesce(p->>'cliente_nombre',''),
          v_total, coalesce(nullif(v_tipo,''),'NOTA_DE_VENTA'),
          coalesce(p->>'forma_pago','EFECTIVO'), v_corr, v_caja,
          coalesce(nullif(v_sub,''), p->>'dispositivo_id', ''), 'COMPLETADO', v_ref, coalesce(p->>'obs',''),
          coalesce((p->>'tipo_doc_cliente')::int, 0), coalesce(v_zona,''))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;
  get diagnostics v_ins = row_count;

  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_ref limit 1;
    if found then return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo); end if;
    return jsonb_build_object('status','error','error','INSERT_INCONSISTENTE');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_linea := v_linea + 1;
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
                                   cod_barras, valor_unitario, tipo_igv, unidad_medida)
    values (v_id, v_linea, v_item->>'sku', v_item->>'nombre', coalesce((v_item->>'cantidad')::numeric,0),
            coalesce((v_item->>'precio')::numeric,0), coalesce((v_item->>'subtotal')::numeric,0),
            coalesce(v_item->>'cod_barras',''), coalesce((v_item->>'valor_unitario')::numeric,0),
            coalesce((v_item->>'tipo_igv')::int,1), coalesce(v_item->>'unidad_medida','NIU'))
    on conflict (id_venta, linea) do nothing;
  end loop;

  return jsonb_build_object('status','success','dedup',false,'id_venta',v_id,'correlativo',v_corr,'numero',v_num);
end;
$fn$;
revoke all on function me.crear_venta_directa(jsonb) from public;
grant execute on function me.crear_venta_directa(jsonb) to authenticated;

-- ── LOW17/19: me.crear_cpe_directo — tiebreaker determinístico en la resolución de serie por zona ──
create or replace function me.crear_cpe_directo(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_app     text := me.jwt_app();
  v_sub     text := me.jwt_sub();
  v_ref     text := nullif(btrim(coalesce(p->>'ref_local','')), '');
  v_serie   text := nullif(btrim(coalesce(p->>'serie','')), '');
  v_tipo    text := upper(coalesce(p->>'tipo_doc',''));
  v_caja    text := coalesce(p->>'id_caja','');
  v_caja_ok boolean;
  v_zona    text;
  v_est     text := nullif(btrim(coalesce(p->>'estacion','')), '');
  v_serie_sd text;
  v_total   numeric := coalesce((p->>'total')::numeric, 0);
  v_suma    numeric;
  v_nit     int;
  v_ex      me.ventas%rowtype;
  v_num     bigint; v_corr text; v_id text; v_item jsonb; v_linea int := 0; v_ins int;
begin
  if v_app  <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not me._cpe_directo_on() then return jsonb_build_object('status','error','error','CPE_DIRECTO_DESACTIVADO'); end if;
  if v_ref  is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('status','error','error','SOLO_CPE_DIRECTO'); end if;

  select * into v_ex from me.ventas where ref_local = v_ref limit 1;
  if found then
    return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo,
                              'nf_estado',coalesce(v_ex.nf_estado,''),'nf_hash',coalesce(v_ex.nf_hash,''),'nf_enlace',coalesce(v_ex.nf_enlace,''));
  end if;

  select coalesce(sum((it->>'subtotal')::numeric), 0), count(*) into v_suma, v_nit
    from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it;
  if v_nit > 0 and abs(v_total - v_suma) > 0.01 then
    return jsonb_build_object('status','error','error','TOTAL_NO_CUADRA','detalle','total='||v_total||' suma_items='||v_suma);
  end if;

  select (estado = 'ABIERTA'), zona_id into v_caja_ok, v_zona from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA'); end if;

  -- [270 #18 + LOW17/19 500x-2] SERIE autoritativa desde Supabase: estación primero, luego zona.
  -- Tiebreaker determinístico `id_serie asc` para que con >1 serie activa por (zona,tipo) la elección
  -- sea estable (no dependa del orden físico del plan).
  select serie into v_serie_sd from mos.series_documentales
   where activo and upper(tipo_documento) = v_tipo
     and ( (v_est is not null and id_estacion = v_est)
        or (v_zona is not null and v_zona <> '' and id_zona = v_zona) )
   order by (v_est is not null and id_estacion = v_est) desc, id_serie asc
   limit 1;
  if v_serie_sd is not null and btrim(v_serie_sd) <> '' then v_serie := btrim(v_serie_sd); end if;
  if v_serie is null then return jsonb_build_object('status','error','error','SERIE_REQUERIDA'); end if;

  v_num  := me.siguiente_correlativo(v_serie, v_ref);
  v_corr := v_serie || '-' || lpad(v_num::text, 6, '0');
  v_id   := 'V-' || (floor(extract(epoch from clock_timestamp()) * 1000))::bigint::text
                 || '-' || substr(md5(random()::text || clock_timestamp()::text || v_ref), 1, 8);

  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
                         tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio,
                         ref_local, obs, tipo_doc_cliente, nf_estado, zona_id)
  values (v_id, now(), p->>'vendedor', p->>'estacion', coalesce(p->>'cliente_doc',''), coalesce(p->>'cliente_nombre',''),
          v_total, v_tipo,
          coalesce(p->>'forma_pago','EFECTIVO'), v_corr, v_caja,
          coalesce(nullif(v_sub,''), p->>'dispositivo_id', ''), 'COMPLETADO', v_ref, coalesce(p->>'obs',''),
          coalesce((p->>'tipo_doc_cliente')::int, 0), 'PENDIENTE', coalesce(v_zona,''))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;
  get diagnostics v_ins = row_count;

  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_ref limit 1;
    if found then return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo,
                              'nf_estado',coalesce(v_ex.nf_estado,''),'nf_hash',coalesce(v_ex.nf_hash,''),'nf_enlace',coalesce(v_ex.nf_enlace,'')); end if;
    return jsonb_build_object('status','error','error','INSERT_INCONSISTENTE');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_linea := v_linea + 1;
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
                                   cod_barras, valor_unitario, tipo_igv, unidad_medida)
    values (v_id, v_linea, v_item->>'sku', v_item->>'nombre', coalesce((v_item->>'cantidad')::numeric,0),
            coalesce((v_item->>'precio')::numeric,0), coalesce((v_item->>'subtotal')::numeric,0),
            coalesce(v_item->>'cod_barras',''), coalesce((v_item->>'valor_unitario')::numeric,0),
            coalesce((v_item->>'tipo_igv')::int,1), coalesce(v_item->>'unidad_medida','NIU'))
    on conflict (id_venta, linea) do nothing;
  end loop;

  return jsonb_build_object('status','success','dedup',false,'id_venta',v_id,'correlativo',v_corr,'numero',v_num,'nf_estado','PENDIENTE');
end;
$function$;
