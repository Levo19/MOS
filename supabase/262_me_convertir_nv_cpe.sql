-- ============================================================
-- 262_me_convertir_nv_cpe.sql
-- CUTOVER ventas-ME · Etapa 4 — NV→CPE 100% Supabase (cero GAS)
-- ------------------------------------------------------------
-- Porta `convertirNVaCPE` (EditarVenta.gs:392): emite un CPE retroactivo (BOLETA/FACTURA)
-- desde una Nota de Venta y anula la NV. La emisión la delega a `fac.emitir_cpe` (autoridad
-- única del correlativo + POST a NubeFact desde Postgres vía extensión http) — la MISMA capa
-- que usa me.emitir_cpe_fac. Pero el converter:
--   · lo llama el PANEL MOS (app='MOS') → fac._app_ok() permite ('mosExpress','MOS') ✓
--   · NO exige caja ABIERTA (a diferencia de me.emitir_cpe_fac): una conversión es retroactiva,
--     la "venta" ya ocurrió → el CPE HEREDA la caja ORIGINAL de la NV (v_nv.id_caja). Así el
--     stock queda net −1 por construcción: el cierre/guía de esa caja ya cubre (o cubrirá) la
--     salida; NO se repone ni se descuenta pickup (hay un CPE de reemplazo, no es anulación pura).
--   · idempotente por local_id 'CONVERT-<idVentaNV>' (paridad con el data_sync del GAS).
--
-- INERTE hasta el go-live fiscal: requiere fac._on() (FAC_CPE_DIRECTO='1') + fac.config con
-- token NubeFact + correlativos alineados. Con fac OFF devuelve FAC_DESACTIVADO → el front MOS
-- cae a GAS (idéntico a hoy). Gateado además por el front con `me_convert_directo` (default OFF).
--
-- Money/fiscal-safety: atómico (emisión + fila CPE + detalle + anulación NV en 1 tx). Si algo
-- post-emisión falla → rollback (la fila fac.comprobantes también, por estar en la misma tx).
-- ============================================================

create or replace function me.convertir_nv_cpe(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app   text := me.jwt_app();
  v_idnv  text := nullif(btrim(coalesce(p->>'idVentaNV','')),'');
  v_tipo  text := upper(coalesce(p->>'tipoDocNuevo',''));
  v_doc   text := btrim(coalesce(p->>'clienteDoc',''));
  v_nom   text := btrim(coalesce(p->>'clienteNombre',''));
  v_dir   text := coalesce(p->>'clienteDireccion','');
  v_serie text := nullif(btrim(coalesce(p->>'serieNueva','')),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_nv    me.ventas%rowtype;
  v_items jsonb := '[]'::jsonb;
  v_d     record;
  v_tipoc int;
  v_local text;
  v_fac   jsonb;
  v_corr  text; v_estado text; v_nfest text; v_newid text;
  v_total numeric;
  v_linea int := 0;
  v_exist text;
begin
  -- Gate: panel MOS o ME (mismas apps que fac._app_ok). service_role ('') NO: fac lo rechazaría.
  if v_app not in ('MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- Kill-switch fiscal: si la emisión directa está OFF → el front cae a GAS (inerte).
  if not fac._on() then
    return jsonb_build_object('ok', false, 'error', 'FAC_DESACTIVADO');
  end if;
  if v_idnv  is null then return jsonb_build_object('ok', false, 'error', 'idVentaNV requerido'); end if;
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('ok', false, 'error', 'tipoDocNuevo debe ser BOLETA o FACTURA'); end if;
  -- serieNueva es OPCIONAL: si no viene, fac.emitir_cpe la deriva de la ZONA de emisión de la NV
  -- (v_nv.zona_id → mos.series_documentales). Respeta el seriado por zona sin tecleo manual.
  -- Validación de documento según tipo (paridad con GAS).
  if v_tipo = 'BOLETA'  and v_doc !~ '^\d{8}$'  then return jsonb_build_object('ok', false, 'error', 'BOLETA requiere DNI de 8 dígitos'); end if;
  if v_tipo = 'FACTURA' and v_doc !~ '^\d{11}$' then return jsonb_build_object('ok', false, 'error', 'FACTURA requiere RUC de 11 dígitos'); end if;

  v_local := 'CONVERT-' || v_idnv;

  -- Leer la NV (lock).
  select * into v_nv from me.ventas where id_venta = v_idnv for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Venta original '||v_idnv||' no encontrada'); end if;

  -- Idempotencia: si la NV YA está convertida y existe el CPE → devolverlo (retry-friendly).
  if upper(coalesce(v_nv.forma_pago,'')) like 'ANULADO%' then
    if v_nv.forma_pago = 'ANULADO_CONVERSION' then
      select id_venta into v_exist from me.ventas where ref_local = v_local limit 1;
      if v_exist is not null then
        return jsonb_build_object('ok', true, 'dedup', true, 'idVentaNuevo', v_exist,
          'correlativoNuevo', (select correlativo from me.ventas where id_venta = v_exist),
          'mensaje', 'La NV ya había sido convertida (idempotente)');
      end if;
    end if;
    return jsonb_build_object('ok', false, 'error', 'La venta original ya fue anulada/convertida');
  end if;

  if coalesce(v_nv.tipo_doc,'') <> 'NOTA_DE_VENTA' then
    return jsonb_build_object('ok', false, 'error', 'Solo se convierten NOTA_DE_VENTA. Esta es '||coalesce(v_nv.tipo_doc,''));
  end if;

  -- Construir items desde el detalle de la NV (mismas líneas → mismo físico).
  select coalesce(jsonb_agg(jsonb_build_object(
      'sku', d.sku, 'nombre', d.nombre, 'cantidad', d.cantidad, 'precio', d.precio,
      'valor_unitario', d.valor_unitario, 'subtotal', d.subtotal, 'tipo_igv', d.tipo_igv,
      'unidad_medida', d.unidad_medida, 'cod_sunat', '', 'cod_barras', coalesce(d.cod_barras,'')
    ) order by d.linea), '[]'::jsonb)
  into v_items
  from me.ventas_detalle d where d.id_venta = v_idnv;
  if jsonb_array_length(v_items) = 0 then return jsonb_build_object('ok', false, 'error', 'La venta original no tiene items'); end if;

  v_total := coalesce(v_nv.total, 0);
  v_tipoc := case when v_tipo = 'FACTURA' then 6 else 1 end;   -- tipo_doc_cliente

  -- EMITIR vía la capa central fac (mintea correlativo + NubeFact, idempotente por local_id). Misma tx → atómico.
  v_fac := fac.emitir_cpe(jsonb_build_object(
    'tipo_doc', v_tipo, 'serie', v_serie, 'zona', coalesce(v_nv.zona_id,''),   -- serie por zona de emisión de la NV
    'cliente', jsonb_build_object('tipo', v_tipoc, 'doc', v_doc, 'nombre', v_nom, 'direccion', v_dir),
    'items', v_items, 'total', v_total,
    'local_id', v_local, 'origen', 'CONVERT', 'ref_externa', v_idnv, 'creado_por', coalesce(v_user,'')));
  if coalesce(v_fac->>'status','') <> 'success' then
    -- FAC_DESACTIVADO/APP_NO_AUTORIZADA → front cae a GAS; rechazo/total_no_cuadra → propaga (rollback total).
    return jsonb_build_object('ok', false, 'error', coalesce(v_fac->>'error','emisión fac falló'), 'fac', v_fac);
  end if;
  v_corr   := v_fac->>'correlativo';
  v_estado := v_fac->>'estado';   -- STUB | EMITIDO | PENDIENTE | RECHAZADO
  v_nfest  := case when v_estado in ('EMITIDO','STUB','PENDIENTE') then v_estado else 'RECHAZADO' end;

  -- Crear la venta CPE. HEREDA la caja ORIGINAL de la NV (stock net −1: el cierre/guía de esa
  -- caja cubre la salida; el converter NO mueve stock). ref_local='CONVERT-<idnv>' = idempotente.
  v_newid := 'V-' || (floor(extract(epoch from clock_timestamp())*1000))::bigint::text
                  || '-' || substr(md5(random()::text || clock_timestamp()::text || v_local), 1, 8);
  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
     tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio, ref_local, obs,
     tipo_doc_cliente, nf_estado, nf_hash, nf_enlace, zona_id)
  values (v_newid, now(), coalesce(nullif(v_user,''), v_nv.vendedor), v_nv.estacion, v_doc, v_nom, v_total,
     v_tipo, v_nv.forma_pago, v_corr, v_nv.id_caja, v_nv.dispositivo_id, 'COMPLETADO', v_local,
     'Conversión retroactiva de '||v_idnv, v_tipoc, v_nfest, v_fac->>'hash', v_fac->>'pdf', coalesce(v_nv.zona_id,''))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;

  -- Detalle de la CPE (mismas líneas que la NV).
  for v_d in select * from me.ventas_detalle where id_venta = v_idnv order by linea loop
    v_linea := v_linea + 1;
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
       cod_barras, valor_unitario, tipo_igv, unidad_medida)
    values (v_newid, v_linea, v_d.sku, v_d.nombre, v_d.cantidad, v_d.precio, v_d.subtotal,
       coalesce(v_d.cod_barras,''), v_d.valor_unitario, v_d.tipo_igv, v_d.unidad_medida)
    on conflict (id_venta, linea) do nothing;
  end loop;

  -- Anular la NV original (ANULADO_CONVERSION + obs + historial). SIN reposición de stock ni
  -- descuento de pickup (hay CPE de reemplazo; reponer dejaría el neto en 0 = sobreconteo).
  update me.ventas
    set forma_pago = 'ANULADO_CONVERSION',
        obs = 'Convertido a '||v_tipo||' '||v_corr,
        historial_cambios = me._venta_hist_append(v_nv.historial_cambios, jsonb_build_object(
          'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
          'source', 'ME_CONVERTIR_NV_CPE', 'accion', 'anular_por_conversion',
          'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes',coalesce(v_nv.forma_pago,''),'despues','ANULADO_CONVERSION')),
          'autorizadoPor', v_auth,
          'ref', jsonb_build_object('idVentaCPE', v_newid, 'correlativoCPE', v_corr, 'tipoDoc', v_tipo))),
        updated_at = now()
    where id_venta = v_idnv;

  return jsonb_build_object('ok', true, 'idVentaNuevo', v_newid, 'correlativoNuevo', v_corr,
    'nfEstado', v_nfest, 'nfHash', coalesce(v_fac->>'hash',''), 'nfEnlace', coalesce(v_fac->>'pdf',''),
    'qr', coalesce(v_fac->>'qr',''));
end;
$fn$;
revoke all on function me.convertir_nv_cpe(jsonb) from public, anon;
grant execute on function me.convertir_nv_cpe(jsonb) to authenticated, service_role;
