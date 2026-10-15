-- Rollback 1048: me.convertir_nv_cpe tal como quedó con la 1047
begin;
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
  -- [1047] cobro opcional + reapunte de abonos
  v_cobro    jsonb := case when jsonb_typeof(p->'cobro') = 'object' then p->'cobro' else null end;
  v_cmet     text;              -- método pedido (EFECTIVO|VIRTUAL|MIXTO)
  v_cefe     numeric;           -- parte efectivo
  v_cvir     numeric;           -- parte virtual
  v_total    numeric;           -- total de la NV a céntimos
  v_fp_nv    text;              -- forma_pago de la NV (upper, trim)
  v_fp_cpe   text;              -- forma_pago con la que nace el CPE
  v_caja_pre text;              -- id_caja leído ANTES del row-lock (para ordenar locks)
  v_cajaest  text;
  v_reap     int := 0;          -- movimientos 'Abono deuda' reapuntados al CPE
  v_asig     int := 0;          -- cobros ASIGNADO cerrados por cobro-en-conversión
  v_hcambios jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'CONVERTIR_NV_CPE', coalesce(v_idnv,''), coalesce(nullif(p->>'app',''),'mosExpress'));
  if v_rvf is not null then return v_rvf; end if;
  if me.jwt_app() not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if not me._cpe_directo_on() then return jsonb_build_object('ok',false,'error','CPE_DIRECTO_DESACTIVADO'); end if;
  if v_idnv is null then return jsonb_build_object('ok',false,'error','idVentaNV requerido'); end if;
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('ok',false,'error','tipoDocNuevo debe ser BOLETA o FACTURA'); end if;

  -- [1047] p.cobro: validar FORMA (sin tocar datos) antes de cualquier lock. Montos: numéricos, ≥ 0, máx. 2 decimales.
  if p ? 'cobro' and jsonb_typeof(p->'cobro') <> 'null' and v_cobro is null then
    return jsonb_build_object('ok',false,'error','COBRO_INVALIDO','mensaje','El cobro debe ser un objeto {forma_pago, efectivo, virtual}.');
  end if;
  if v_cobro is not null then
    v_cmet := upper(btrim(coalesce(v_cobro->>'forma_pago', v_cobro->>'formaPago', v_cobro->>'metodo', '')));
    if v_cmet like 'MIXTO%' then v_cmet := 'MIXTO'; end if;
    if v_cmet not in ('EFECTIVO','VIRTUAL','MIXTO') then
      return jsonb_build_object('ok',false,'error','COBRO_METODO_INVALIDO','mensaje','Forma de pago del cobro: EFECTIVO, VIRTUAL o MIXTO.');
    end if;
    if v_cmet = 'MIXTO' then
      begin
        v_cefe := nullif(btrim(coalesce(v_cobro->>'efectivo','')),'')::numeric;
        v_cvir := nullif(btrim(coalesce(v_cobro->>'virtual','')),'')::numeric;
      exception when others then
        return jsonb_build_object('ok',false,'error','COBRO_MONTO_INVALIDO','mensaje','Los montos del cobro mixto no son números válidos.');
      end;
      if v_cefe is null or v_cvir is null or v_cefe < 0 or v_cvir < 0
         or v_cefe <> round(v_cefe, 2) or v_cvir <> round(v_cvir, 2) then
        return jsonb_build_object('ok',false,'error','COBRO_MONTO_INVALIDO','mensaje','En MIXTO indica efectivo y virtual (≥ 0, en céntimos).');
      end if;
    end if;
  end if;

  v_local := 'CONVERT-' || v_idnv;

  -- [1047 · (C)] orden de locks = el de los cobros: 'cobro:'||venta → 'cerrarcaja:'||caja → fila.
  perform pg_advisory_xact_lock(hashtext('cobro:'||v_idnv));
  select nullif(btrim(coalesce(id_caja,'')),'') into v_caja_pre from me.ventas where id_venta = v_idnv;
  if v_caja_pre is not null then
    perform pg_advisory_xact_lock(hashtext('cerrarcaja:'||v_caja_pre));
  end if;

  select * into v_nv from me.ventas where id_venta = v_idnv for update;
  if not found then return jsonb_build_object('ok',false,'error','Venta original '||v_idnv||' no encontrada'); end if;
  -- [1047] la caja no puede cambiar bajo 'cobro:' (cobrar_venta_directo usa el mismo lock); defensa por si acaso.
  if nullif(btrim(coalesce(v_nv.id_caja,'')),'') is distinct from v_caja_pre then
    return jsonb_build_object('ok',false,'error','REINTENTAR','mensaje','El ticket cambió de caja mientras se convertía. Reintenta.');
  end if;

  -- idempotencia total: NV ya convertida → devolver el CPE existente (con base para re-emitir si sigue PENDIENTE)
  if v_nv.forma_pago = 'ANULADO_CONVERSION' then
    select * into v_ex from me.ventas where ref_local = v_local limit 1;
    if found then
      -- [1047 · (A)] auto-cura: si la NV tenía un abono que aún la referencia, reapuntarlo al CPE (idempotente).
      v_reap := me._conv_nv_reapuntar_abonos(v_idnv, v_ex.id_venta,
                  'NV '||coalesce(v_nv.correlativo,v_idnv)||' convertida a '||coalesce(v_ex.correlativo,v_ex.id_venta), v_user);
      if v_reap > 0 then
        update me.ventas set historial_cambios = me._venta_hist_append(historial_cambios, jsonb_build_object(
            'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
            'source','ME_CONVERTIR_NV_CPE_1047','accion','abono_reapuntado_a_cpe',
            'cambios', jsonb_build_array(jsonb_build_object('campo','AbonoDeuda','antes',v_idnv,'despues',v_ex.id_venta)),
            'motivo', v_reap||' cobro(s) de la NV ahora referencian este CPE')),
          updated_at = now()
        where id_venta = v_ex.id_venta;
      end if;
      select coalesce(jsonb_agg(jsonb_build_object('nombre',d.nombre,'cantidad',d.cantidad,'precio',d.precio,
               'subtotal',d.subtotal,'sku',d.sku,'cod_barras',d.cod_barras,'valor_unitario',d.valor_unitario,
               'tipo_igv',d.tipo_igv,'unidad_de_medida',coalesce(d.unidad_medida,'NIU')) order by d.linea),'[]'::jsonb)
        into v_items from me.ventas_detalle d where d.id_venta = v_ex.id_venta;
      return jsonb_build_object('ok',true,'dedup',true,'idVenta',v_ex.id_venta,'correlativoNuevo',v_ex.correlativo,
        'refLocal',v_local,'nfEstado',coalesce(v_ex.nf_estado,''),
        -- [1047] estado de pago real del CPE (el reintento informa lo que quedó, no lo pedido)
        'formaPago',coalesce(v_ex.forma_pago,''),
        'porCobrar',(upper(coalesce(v_ex.forma_pago,'')) = 'POR_COBRAR'),
        'idCaja',coalesce(v_ex.id_caja,''),'abonosReapuntados',v_reap,
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

  -- [1047 · (B)] cobro en la conversión: SOLO NV POR_COBRAR, caja de la NV ABIERTA, montos que cuadren al céntimo.
  v_fp_nv  := upper(btrim(coalesce(v_nv.forma_pago,'')));
  v_fp_cpe := v_nv.forma_pago;                 -- sin cobro: hereda (comportamiento previo intacto)
  if v_cobro is not null then
    if v_fp_nv <> 'POR_COBRAR' then
      return jsonb_build_object('ok',false,
        'error', case when v_fp_nv = 'CREDITO' then 'COBRO_SOLO_POR_COBRAR' else 'COBRO_NO_APLICA' end,
        'mensaje', case when v_fp_nv = 'CREDITO'
                        then 'Este ticket es un CRÉDITO: cóbralo con "Cobrar deuda" (entra a la caja receptora) o conviértelo sin cobro.'
                        else 'Este ticket ya está pagado ('||coalesce(v_nv.forma_pago,'')||'); conviértelo sin cobro.' end,
        'formaPagoNV', coalesce(v_nv.forma_pago,''));
    end if;
    select upper(coalesce(estado,'')) into v_cajaest from me.cajas where id_caja = v_caja_pre;
    if coalesce(v_cajaest,'') <> 'ABIERTA' then
      return jsonb_build_object('ok',false,'error','CAJA_NO_ABIERTA',
        'mensaje','La caja del ticket ('||coalesce(v_caja_pre,'sin caja')||') no está abierta: no se puede registrar el cobro ahí.');
    end if;
    v_total := round(coalesce(v_nv.total,0), 2);
    if v_total <= 0 then
      return jsonb_build_object('ok',false,'error','COBRO_NO_APLICA','mensaje','El ticket no tiene monto a cobrar.');
    end if;
    if v_total <> coalesce(v_nv.total,0) then   -- [1047 · QA] el CPE se inserta con v_nv.total: debe ser exacto a céntimos
      return jsonb_build_object('ok',false,'error','COBRO_MONTO_INVALIDO','mensaje','El total del ticket tiene más de 2 decimales: conviértelo sin cobrar y cóbralo aparte.');
    end if;
    if v_cmet = 'MIXTO' then
      if v_cefe + v_cvir <> v_total then
        return jsonb_build_object('ok',false,'error','MIXTO_NO_CUADRA',
          'mensaje','Efectivo + virtual (S/ '||to_char(v_cefe + v_cvir,'FM999999990.00')||') debe ser igual al total (S/ '||to_char(v_total,'FM999999990.00')||').');
      end if;
      if v_cvir = 0 then v_cmet := 'EFECTIVO';
      elsif v_cefe = 0 then v_cmet := 'VIRTUAL';
      end if;
    end if;
    v_fp_cpe := case v_cmet
                  when 'EFECTIVO' then 'EFECTIVO'
                  when 'VIRTUAL'  then 'VIRTUAL'
                  else 'MIXTO (VIR:'||to_char(v_cvir,'FM999999990.00')||'/EFE:'||to_char(v_cefe,'FM999999990.00')||')'
                end;
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
      -- [1047] si se cobró al convertir, queda escrito en la NV con qué método se cobró
      'motivo','Convertida a '||v_tipo||' '||v_corr
               || case when v_cobro is not null then ' · cobrada al convertir: '||v_fp_cpe else '' end)),
    updated_at = now()
  where id_venta = v_idnv;

  -- 2) crear la venta CPE (PENDIENTE) heredando pago/caja/zona/vendedor
  --    [1047] forma_pago = v_fp_cpe (= la de la NV si no hay cobro; el método cobrado si hay p.cobro)
  v_hcambios := jsonb_build_array(jsonb_build_object('campo','Origen','antes',coalesce(v_nv.correlativo,v_idnv),'despues',v_corr));
  if v_cobro is not null then
    v_hcambios := v_hcambios || jsonb_build_array(jsonb_build_object('campo','FormaPago','antes',coalesce(v_nv.forma_pago,''),'despues',v_fp_cpe));
  end if;
  v_id := 'V-' || (floor(extract(epoch from clock_timestamp()) * 1000))::bigint::text
               || '-' || substr(md5(random()::text || clock_timestamp()::text || v_local), 1, 8);
  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
                         tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio,
                         ref_local, obs, tipo_doc_cliente, nf_estado, zona_id, historial_cambios)
  values (v_id, now(), coalesce(v_user, v_nv.vendedor), v_nv.estacion, v_doc, v_nom, v_nv.total,
          v_tipo, v_fp_cpe, v_corr, v_nv.id_caja, v_nv.dispositivo_id, 'COMPLETADO',
          v_local, 'Convertida de '||coalesce(v_nv.correlativo,v_idnv), v_tdc, 'PENDIENTE', v_nv.zona_id,
          me._venta_hist_append(null, jsonb_build_object(
            'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
            'source', case when v_cobro is not null then 'ME_CONVERTIR_NV_CPE_1047' else 'ME_CONVERTIR_NV_CPE_V2' end,
            'accion', case when v_cobro is not null then 'emitida_por_conversion_cobrada' else 'emitida_por_conversion' end,
            'cambios', v_hcambios,
            'motivo', case when v_cobro is not null then 'Cobrada al convertir ('||v_fp_cpe||')' else '' end)))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;
  get diagnostics v_ins = row_count;
  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_local limit 1;
    if found then v_id := v_ex.id_venta; v_corr := v_ex.correlativo; v_fp_cpe := v_ex.forma_pago; end if;
  else
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
                                   cod_barras, valor_unitario, tipo_igv, unidad_medida)
    select v_id, d.linea, d.sku, d.nombre, d.cantidad, d.precio, d.subtotal,
           d.cod_barras, d.valor_unitario, d.tipo_igv, d.unidad_medida
      from me.ventas_detalle d where d.id_venta = v_idnv;
  end if;

  -- 3) [1047 · (A)] el/los cobros ya registrados de la NV pasan a referenciar al CPE (si no, el cierre lo cuenta 2x).
  v_reap := me._conv_nv_reapuntar_abonos(v_idnv, v_id,
              'NV '||coalesce(v_nv.correlativo,v_idnv)||' convertida a '||v_tipo||' '||v_corr, v_user);
  if v_reap > 0 then
    update me.ventas set historial_cambios = me._venta_hist_append(historial_cambios, jsonb_build_object(
        'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
        'source','ME_CONVERTIR_NV_CPE_1047','accion','abono_reapuntado_a_cpe',
        'cambios', jsonb_build_array(jsonb_build_object('campo','AbonoDeuda','antes',v_idnv,'despues',v_id)),
        'motivo', v_reap||' cobro(s) de la NV ahora referencian este CPE')),
      updated_at = now()
    where id_venta = v_id;
  end if;

  -- 4) [1047 · (B)] cobrado al convertir → cerrar cobros ASIGNADO vivos de la NV (paridad cobrar_credito_directo).
  if v_cobro is not null then
    update me.creditos_cobro_asignado
       set estado='COBRADO', fecha_res=now(), metodo_sug=v_cmet,
           razon = coalesce(nullif(razon,''),'') || case when coalesce(razon,'')<>'' then ' · ' else '' end
                   || 'Cobrado al convertir a '||v_tipo||' '||v_corr,
           updated_at=now()
     where id_venta = v_idnv and upper(coalesce(estado,'')) = 'ASIGNADO';
    get diagnostics v_asig = row_count;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('nombre',d.nombre,'cantidad',d.cantidad,'precio',d.precio,
           'subtotal',d.subtotal,'sku',d.sku,'cod_barras',d.cod_barras,'valor_unitario',d.valor_unitario,
           'tipo_igv',d.tipo_igv,'unidad_de_medida',coalesce(d.unidad_medida,'NIU')) order by d.linea),'[]'::jsonb)
    into v_items from me.ventas_detalle d where d.id_venta = v_id;

  v_base := jsonb_build_object(
    'header', jsonb_build_object('tipoDoc', v_tipo, 'total', v_nv.total, 'metodo', v_fp_cpe,   -- [1047] método real del CPE
      'obs', 'Convertida de '||coalesce(v_nv.correlativo,v_idnv),
      'cliente', jsonb_build_object('tipo', v_tdc, 'doc', v_doc, 'nombre', v_nom, 'direccion', v_dir)),
    'items', v_items);

  return jsonb_build_object('ok',true,'idVenta',v_id,'correlativoNuevo',v_corr,'refLocal',v_local,
    'serie',v_serie,'numero',v_num,'nfEstado','PENDIENTE','ventaBase',v_base,
    -- [1047] estado de pago del CPE para que la UI lo diga claro
    'formaPago',coalesce(v_fp_cpe,''),
    'porCobrar',(upper(coalesce(v_fp_cpe,'')) = 'POR_COBRAR'),
    'cobroAplicado',(v_cobro is not null),
    'idCaja',coalesce(v_nv.id_caja,''),
    'abonosReapuntados',v_reap,
    'cobrosAsignadosCerrados',v_asig);
end; $function$
;
commit;
