-- 585 · [CPE serie-por-zona hardening · review 100x] Cierra 3 hallazgos del review:
--  H1 (ALTA): me.convertir_nv_cpe con NV sin zona_id (361 NV legacy) defaulteaba a la 1ª serie
--             (MOS-VIP BBB1/FFF1 en el live) → CPE emitido en el LOCAL/token EQUIVOCADO. Ahora
--             deriva la zona de la caja/estación de la NV; si no se resuelve, falla SERIE_REQUERIDA.
--  H2 (MEDIA): me.crear_cpe_directo tenía el mismo hueco de zona-vacía → mismo fix.
--  H3 (BAJA): sin unicidad (zona,tipo) activo, el `order by id_serie asc limit 1` sería no-determinista
--             si alguien crea una 2ª serie por zona → índice único parcial que lo impide de raíz.
-- Money-safe: solo cambia la SELECCIÓN de serie (más estricta); el resto de ambas funciones intacto
-- (dump pg_get_functiondef del live + reemplazo quirúrgico del bloque de serie).

CREATE OR REPLACE FUNCTION me.convertir_nv_cpe(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idnv  text := nullif(btrim(coalesce(p->>'idVentaNV','')),'');
  v_tipo  text := upper(coalesce(p->>'tipoDocNuevo',''));
  v_doc   text := btrim(coalesce(p->>'clienteDoc',''));
  v_nom   text := btrim(coalesce(p->>'clienteNombre',''));
  v_dir   text := btrim(coalesce(p->>'clienteDireccion',''));
  v_tdc   int  := coalesce(nullif(btrim(coalesce(p->>'tipoDocCliente','')),'')::int, -1);
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_rvf   jsonb;
  v_nv    me.ventas%rowtype;
  v_ex    me.ventas%rowtype;
  v_local text;
  v_serie text; v_num bigint; v_corr text; v_id text; v_ins int;
  v_items jsonb;
  v_base  jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'CONVERTIR_NV_CPE', coalesce(v_idnv,''), coalesce(nullif(p->>'app',''),'mosExpress'));
  if v_rvf is not null then return v_rvf; end if;
  if me.jwt_app() not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if not me._cpe_directo_on() then return jsonb_build_object('ok',false,'error','CPE_DIRECTO_DESACTIVADO'); end if;
  if v_idnv is null then return jsonb_build_object('ok',false,'error','idVentaNV requerido'); end if;
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('ok',false,'error','tipoDocNuevo debe ser BOLETA o FACTURA'); end if;

  v_local := 'CONVERT-' || v_idnv;

  select * into v_nv from me.ventas where id_venta = v_idnv for update;
  if not found then return jsonb_build_object('ok',false,'error','Venta original '||v_idnv||' no encontrada'); end if;

  -- idempotencia total: NV ya convertida → devolver el CPE existente (con base para re-emitir si sigue PENDIENTE)
  if v_nv.forma_pago = 'ANULADO_CONVERSION' then
    select * into v_ex from me.ventas where ref_local = v_local limit 1;
    if found then
      select coalesce(jsonb_agg(jsonb_build_object('nombre',d.nombre,'cantidad',d.cantidad,'precio',d.precio,
               'subtotal',d.subtotal,'sku',d.sku,'cod_barras',d.cod_barras,'valor_unitario',d.valor_unitario,
               'tipo_igv',d.tipo_igv,'unidad_de_medida',coalesce(d.unidad_medida,'NIU')) order by d.linea),'[]'::jsonb)
        into v_items from me.ventas_detalle d where d.id_venta = v_ex.id_venta;
      return jsonb_build_object('ok',true,'dedup',true,'idVenta',v_ex.id_venta,'correlativoNuevo',v_ex.correlativo,
        'refLocal',v_local,'nfEstado',coalesce(v_ex.nf_estado,''),
        'ventaBase', jsonb_build_object('header', jsonb_build_object('tipoDoc',v_ex.tipo_doc,'total',v_ex.total,
          'metodo',v_ex.forma_pago,'obs',coalesce(v_ex.obs,''),
          'cliente', jsonb_build_object('tipo',coalesce(v_ex.tipo_doc_cliente,0),'doc',coalesce(v_ex.cliente_doc,''),
            'nombre',coalesce(v_ex.cliente_nombre,''),'direccion','')), 'items', v_items));
    end if;
    return jsonb_build_object('ok',false,'error','NV ya convertida pero el CPE no aparece — revisar '||v_local);
  end if;
  if upper(coalesce(v_nv.forma_pago,'')) like 'ANULADO%' then
    return jsonb_build_object('ok',false,'error','La NV está ANULADA — no se puede convertir');
  end if;
  if v_nv.tipo_doc <> 'NOTA_DE_VENTA' then
    return jsonb_build_object('ok',false,'error','Solo se convierten NOTAS DE VENTA (este ticket es '||coalesce(v_nv.tipo_doc,'?')||')');
  end if;

  -- tipo de doc del cliente (catálogo 06): explícito > derivado
  if v_tdc < 0 then
    v_tdc := case when v_doc = '' then 0
                  when v_doc ~ '^[0-9]{11}$' then 6
                  when v_doc ~ '^[0-9]{8}$'  then 1
                  else 4 end;
  end if;

  -- Reglas SUNAT server-side (una sola fuente, mismas del POS/fac):
  if v_tipo = 'FACTURA' then
    if v_doc !~ '^[0-9]{11}$' or substring(v_doc,1,2) not in ('10','15','17','20') then
      return jsonb_build_object('ok',false,'error','FACTURA requiere RUC válido de 11 dígitos');
    end if;
    if v_nom = '' then return jsonb_build_object('ok',false,'error','FACTURA requiere razón social'); end if;
    if v_dir = '' then return jsonb_build_object('ok',false,'error','FACTURA requiere dirección fiscal'); end if;
    if v_tdc in (4,7) then return jsonb_build_object('ok',false,'error','CE/Pasaporte no puede recibir FACTURA'); end if;
    v_tdc := 6;
  else
    if coalesce(v_nv.total,0) > 700 and (v_doc = '' or v_nom = '') then
      return jsonb_build_object('ok',false,'error','BOLETA > S/700 exige cliente identificado (DNI/RUC/CE + nombre)');
    end if;
  end if;

  -- SERIE por ZONA de emisión de la NV (numeración propia por zona — regla del dueño).
  -- [585·H1] Las NV legacy (361 sin zona_id) NO deben defaultear a la primera serie: eso emitía
  -- el CPE en el LOCAL EQUIVOCADO (con su token/RUC), irreversible ante SUNAT. Derivar la zona de
  -- la caja o la estación de la NV; si no se resuelve, FALLAR con SERIE_REQUERIDA (nunca adivinar).
  declare v_zona_ef text;
  begin
    v_zona_ef := nullif(btrim(coalesce(v_nv.zona_id,'')),'');
    if v_zona_ef is null then
      select nullif(btrim(coalesce(zona_id,'')),'') into v_zona_ef from me.cajas where id_caja = v_nv.id_caja limit 1;
    end if;
    if v_zona_ef is null then
      select nullif(btrim(coalesce(id_zona,'')),'') into v_zona_ef from mos.series_documentales
       where activo and id_estacion = v_nv.estacion limit 1;
    end if;
    if v_zona_ef is null then
      return jsonb_build_object('ok',false,'error','SERIE_REQUERIDA: no se pudo determinar la zona de la NV '||coalesce(v_nv.correlativo,v_idnv)||' (sin zona_id/caja/estación) — asigna la zona antes de convertir');
    end if;
    select serie into v_serie from mos.series_documentales
     where activo and upper(tipo_documento) = v_tipo and id_zona = v_zona_ef
     order by id_serie asc limit 1;
    if v_serie is null or btrim(v_serie) = '' then
      return jsonb_build_object('ok',false,'error','SERIE_REQUERIDA: la zona '||v_zona_ef||' no tiene serie '||v_tipo||' activa en MOS config');
    end if;
    v_serie := btrim(v_serie);
  end;

  v_num  := me.siguiente_correlativo(v_serie, v_local);
  v_corr := v_serie || '-' || lpad(v_num::text, 6, '0');

  -- 1) anular la NV (el pago pasa al CPE nuevo)
  update me.ventas set
    forma_pago = 'ANULADO_CONVERSION',
    historial_cambios = me._venta_hist_append(historial_cambios, jsonb_build_object(
      'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
      'source','ME_CONVERTIR_NV_CPE_V2','accion','convertida_a_'||v_tipo,
      'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes',coalesce(v_nv.forma_pago,''),'despues','ANULADO_CONVERSION')),
      'motivo','Convertida a '||v_tipo||' '||v_corr)),
    updated_at = now()
  where id_venta = v_idnv;

  -- 2) crear la venta CPE (PENDIENTE) heredando pago/caja/zona/vendedor
  v_id := 'V-' || (floor(extract(epoch from clock_timestamp()) * 1000))::bigint::text
               || '-' || substr(md5(random()::text || clock_timestamp()::text || v_local), 1, 8);
  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
                         tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio,
                         ref_local, obs, tipo_doc_cliente, nf_estado, zona_id, historial_cambios)
  values (v_id, now(), coalesce(v_user, v_nv.vendedor), v_nv.estacion, v_doc, v_nom, v_nv.total,
          v_tipo, v_nv.forma_pago, v_corr, v_nv.id_caja, v_nv.dispositivo_id, 'COMPLETADO',
          v_local, 'Convertida de '||coalesce(v_nv.correlativo,v_idnv), v_tdc, 'PENDIENTE', v_nv.zona_id,
          me._venta_hist_append(null, jsonb_build_object(
            'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
            'source','ME_CONVERTIR_NV_CPE_V2','accion','emitida_por_conversion',
            'cambios', jsonb_build_array(jsonb_build_object('campo','Origen','antes',coalesce(v_nv.correlativo,v_idnv),'despues',v_corr)),
            'motivo','')))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;
  get diagnostics v_ins = row_count;
  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_local limit 1;
    if found then v_id := v_ex.id_venta; v_corr := v_ex.correlativo; end if;
  else
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
                                   cod_barras, valor_unitario, tipo_igv, unidad_medida)
    select v_id, d.linea, d.sku, d.nombre, d.cantidad, d.precio, d.subtotal,
           d.cod_barras, d.valor_unitario, d.tipo_igv, d.unidad_medida
      from me.ventas_detalle d where d.id_venta = v_idnv;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('nombre',d.nombre,'cantidad',d.cantidad,'precio',d.precio,
           'subtotal',d.subtotal,'sku',d.sku,'cod_barras',d.cod_barras,'valor_unitario',d.valor_unitario,
           'tipo_igv',d.tipo_igv,'unidad_de_medida',coalesce(d.unidad_medida,'NIU')) order by d.linea),'[]'::jsonb)
    into v_items from me.ventas_detalle d where d.id_venta = v_id;

  v_base := jsonb_build_object(
    'header', jsonb_build_object('tipoDoc', v_tipo, 'total', v_nv.total, 'metodo', v_nv.forma_pago,
      'obs', 'Convertida de '||coalesce(v_nv.correlativo,v_idnv),
      'cliente', jsonb_build_object('tipo', v_tdc, 'doc', v_doc, 'nombre', v_nom, 'direccion', v_dir)),
    'items', v_items);

  return jsonb_build_object('ok',true,'idVenta',v_id,'correlativoNuevo',v_corr,'refLocal',v_local,
    'serie',v_serie,'numero',v_num,'nfEstado','PENDIENTE','ventaBase',v_base);
end; $function$
;

CREATE OR REPLACE FUNCTION me.crear_cpe_directo(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- [500x-2b] CPE SIN items NO se emite (SUNAT exige >=1 línea; no quemar correlativo en comprobante vacío)
  if v_nit = 0 then return jsonb_build_object('status','error','error','SIN_ITEMS'); end if;

  select (estado = 'ABIERTA'), zona_id into v_caja_ok, v_zona from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA'); end if;

  -- [270 #18 + LOW17/19 500x-2] SERIE autoritativa desde Supabase por ZONA de la caja.
  -- [585·H2] La zona vacía ya NO desactiva el filtro (eso defaulteaba a la 1ª serie = local
  -- equivocado). Si la caja no trae zona, derivarla de la estación; si no se resuelve → SERIE_REQUERIDA.
  if v_zona is null or btrim(v_zona) = '' then
    select nullif(btrim(coalesce(id_zona,'')),'') into v_zona from mos.series_documentales
     where activo and v_est is not null and id_estacion = v_est limit 1;
  end if;
  if v_zona is null or btrim(v_zona) = '' then
    return jsonb_build_object('status','error','error','SERIE_REQUERIDA','detalle','zona no resuelta (caja/estación)');
  end if;
  -- Tiebreaker determinístico `id_serie asc`; serie SOLO de la zona resuelta (estación no cruza zonas).
  select serie into v_serie_sd from mos.series_documentales
   where activo and upper(tipo_documento) = v_tipo and id_zona = btrim(v_zona)
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
$function$
;

-- H3: unicidad (zona, tipo_documento) entre series activas → tiebreaker irrelevante, sin doble seriado.
create unique index if not exists ux_series_doc_zona_tipo_activo
  on mos.series_documentales (id_zona, upper(tipo_documento))
  where activo;

notify pgrst, 'reload schema';
