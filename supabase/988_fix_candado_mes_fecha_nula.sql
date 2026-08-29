-- [988] FIX M1 (revisión senior): el candado de mes era fail-OPEN ante fecha nula (date_trunc(null)<... = NULL
--  no bloquea). Ahora fecha IS NULL tambien BLOQUEA (fail-closed): un ticket sin fecha no se convierte.
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

  -- [985 · candado de mes] No convertir tickets de un MES CALENDARIO ANTERIOR: emitir hoy un CPE de un mes
  --  pasado meteria el IGV de ese mes en el periodo actual (declaracion incorrecta). Regla del dueno: solo
  --  dentro del mismo mes calendario (hora Peru). Off-switch: mos.config CPE_CONVERT_MES_ESTRICTO='0'.
  if coalesce((select valor from mos.config where clave='CPE_CONVERT_MES_ESTRICTO' limit 1),'1') <> '0'
     and ( v_nv.fecha is null
        or date_trunc('month', (v_nv.fecha at time zone 'America/Lima'))
           < date_trunc('month', (now() at time zone 'America/Lima')) ) then
    return jsonb_build_object('ok',false,'error','MES_ANTERIOR',
      'mensaje', case when v_nv.fecha is null
                      then 'Este ticket no tiene fecha registrada; por seguridad no se convierte.'
                      else 'Este ticket es de un mes anterior ('||to_char(v_nv.fecha at time zone 'America/Lima','DD/MM/YYYY')||'). Solo se convierte dentro del mismo mes calendario, para no declarar IGV de un mes en otro.' end,
      'fechaTicket', coalesce(to_char(v_nv.fecha at time zone 'America/Lima','YYYY-MM-DD'),''));
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

select '988 fix M1 candado mes fecha nula listo' as ok;
