-- ════════════════════════════════════════════════════════════════════════════
-- fac_06_me_bridge.sql · Puente POS de ME → capa central fac
-- ════════════════════════════════════════════════════════════════════════════
-- ME (POS) necesita: (1) registrar la venta en me.ventas (caja/cierre/finanzas) Y
-- (2) emitir el CPE. Esta RPC hace AMBAS atómicamente: delega emisión+correlativo a
-- fac.emitir_cpe (autoridad única del número) y graba la venta con ese correlativo.
-- Reemplaza el viejo crear_cpe_directo→Edge→set_cpe_nf (3 saltos) por 1 sola llamada.
-- Idempotente por ref_local. Si fac falla (TOTAL_NO_CUADRA / rechazo / timeout) → la
-- venta NO se graba (rollback) y ME cae a su path previo.

create or replace function me.emitir_cpe_fac(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app   text := me.jwt_app();
  v_sub   text := me.jwt_sub();
  v_ref   text := nullif(btrim(coalesce(p->>'ref_local','')), '');
  v_tipo  text := upper(coalesce(p->>'tipo_doc',''));
  v_caja  text := coalesce(p->>'id_caja','');
  v_caja_ok boolean; v_zona text;
  v_total numeric := coalesce((p->>'total')::numeric, 0);
  v_ex    me.ventas%rowtype;
  v_fac   jsonb; v_corr text; v_estado text; v_nfest text;
  v_id    text; v_item jsonb; v_linea int := 0; v_ins int;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not fac._on() then return jsonb_build_object('status','error','error','FAC_DESACTIVADO'); end if;
  if v_ref is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('status','error','error','SOLO_CPE'); end if;

  -- idempotencia: venta ya existe por ref_local (reintento) → devolver la misma
  select * into v_ex from me.ventas where ref_local = v_ref limit 1;
  if found then
    return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo,
      'nf_estado',coalesce(v_ex.nf_estado,''),'nf_hash',coalesce(v_ex.nf_hash,''),'nf_enlace',coalesce(v_ex.nf_enlace,''),
      'qr','','estado',coalesce(v_ex.nf_estado,''));
  end if;

  -- caja ABIERTA + zona (paridad con crear_cpe_directo)
  select (estado = 'ABIERTA'), zona_id into v_caja_ok, v_zona from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA'); end if;

  -- EMITIR vía la capa central (mintea correlativo fac + NubeFact). Misma tx → atómico.
  v_fac := fac.emitir_cpe(jsonb_build_object(
    'tipo_doc', v_tipo, 'serie', p->>'serie', 'zona', coalesce(v_zona,''),   -- serie por zona de la caja
    'cliente', coalesce(p->'cliente','{}'::jsonb),
    'items', coalesce(p->'items','[]'::jsonb), 'total', v_total,
    'local_id', v_ref, 'origen','POS', 'ref_externa', v_ref, 'creado_por', p->>'vendedor'));
  if coalesce(v_fac->>'status','') <> 'success' then
    return v_fac;   -- propaga el error exacto (FAC_DESACTIVADO/TOTAL_NO_CUADRA/etc.)
  end if;
  v_corr   := v_fac->>'correlativo';
  v_estado := v_fac->>'estado';   -- STUB | EMITIDO | PENDIENTE | RECHAZADO
  v_nfest  := case when v_estado in ('EMITIDO','STUB','PENDIENTE') then v_estado else 'RECHAZADO' end;

  v_id := 'V-' || (floor(extract(epoch from clock_timestamp())*1000))::bigint::text
              || '-' || substr(md5(random()::text || clock_timestamp()::text || v_ref), 1, 8);
  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
     tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio, ref_local, obs,
     tipo_doc_cliente, nf_estado, nf_hash, nf_enlace, zona_id)
  values (v_id, now(), p->>'vendedor', p->>'estacion',
     coalesce(p->'cliente'->>'doc',''), coalesce(p->'cliente'->>'nombre',''), v_total,
     v_tipo, coalesce(p->>'forma_pago','EFECTIVO'), v_corr, v_caja,
     coalesce(nullif(v_sub,''), p->>'dispositivo_id',''), 'COMPLETADO', v_ref, coalesce(p->>'obs',''),
     coalesce(nullif(regexp_replace(coalesce(p->>'tipo_doc_cliente','0'),'\D','','g'),'')::int, 0), v_nfest, v_fac->>'hash', v_fac->>'pdf', coalesce(v_zona,''))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;
  get diagnostics v_ins = row_count;

  -- carrera: otra tx ya registró esta venta (y fac.emitir_cpe dedupeó la emisión por local_id) →
  -- devolver la existente SIN insertar detalle huérfano contra un v_id que no se grabó.
  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_ref limit 1;
    if found then return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo,
      'estado',coalesce(v_ex.nf_estado,''),'nf_estado',coalesce(v_ex.nf_estado,''),'nf_hash',coalesce(v_ex.nf_hash,''),'nf_enlace',coalesce(v_ex.nf_enlace,''),'qr',''); end if;
    return jsonb_build_object('status','error','error','INSERT_INCONSISTENTE');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_linea := v_linea + 1;
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
       cod_barras, valor_unitario, tipo_igv, unidad_medida)
    values (v_id, v_linea, v_item->>'sku', v_item->>'nombre', coalesce((v_item->>'cantidad')::numeric,0),
       coalesce((v_item->>'precio')::numeric,0), coalesce((v_item->>'subtotal')::numeric,0),
       coalesce(v_item->>'cod_barras',''), coalesce((v_item->>'valor_unitario')::numeric,0),
       coalesce(nullif(regexp_replace(coalesce(v_item->>'tipo_igv','1'),'\D','','g'),'')::int,1), coalesce(v_item->>'unidad_medida','NIU'))
    on conflict (id_venta, linea) do nothing;
  end loop;

  return jsonb_build_object('status','success','dedup',false,'id_venta',v_id,'correlativo',v_corr,
    'estado',v_estado,'nf_estado',v_nfest,'qr',coalesce(v_fac->>'qr',''),'pdf',coalesce(v_fac->>'pdf',''),
    'hash',coalesce(v_fac->>'hash',''));
end;
$fn$;

revoke all on function me.emitir_cpe_fac(jsonb) from public;
grant execute on function me.emitir_cpe_fac(jsonb) to authenticated;
