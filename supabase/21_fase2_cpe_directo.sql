-- 21_fase2_cpe_directo.sql — Fase 2: CPE (boleta/factura) DIRECTO. Espeja crear_venta_directa pero para CPE:
-- mintea el correlativo de la serie B/F, inserta la venta con nf_estado='PENDIENTE', y deja la emisión a SUNAT
-- a la Edge Function emitir-cpe (el front: crear_cpe_directo → emitir-cpe → set_cpe_nf → imprimir con QR).
-- Idempotente por ref_local. Compliance-crítico → detrás de flag ME_CPE_DIRECTO en el front.

create or replace function me.crear_cpe_directo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app     text := me.jwt_app();
  v_ref     text := nullif(btrim(coalesce(p->>'ref_local','')), '');
  v_serie   text := nullif(btrim(coalesce(p->>'serie','')), '');
  v_tipo    text := upper(coalesce(p->>'tipo_doc',''));
  v_caja    text := coalesce(p->>'id_caja','');
  v_caja_ok boolean;
  v_ex      me.ventas%rowtype;
  v_num     bigint; v_corr text; v_id text; v_item jsonb; v_linea int := 0; v_ins int;
begin
  if v_app  <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if v_ref  is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  if v_serie is null then return jsonb_build_object('status','error','error','SERIE_REQUERIDA'); end if;
  -- SOLO CPE acá (NV usa crear_venta_directa). Boleta/Factura.
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('status','error','error','SOLO_CPE_DIRECTO'); end if;

  -- idempotencia: si ya existe por ref_local (reintento) → devolver la MISMA (con su estado NF actual)
  select * into v_ex from me.ventas where ref_local = v_ref limit 1;
  if found then
    return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo,
                              'nf_estado',coalesce(v_ex.nf_estado,''),'nf_hash',coalesce(v_ex.nf_hash,''),'nf_enlace',coalesce(v_ex.nf_enlace,''));
  end if;

  -- caja ABIERTA (parity con el cierre/ConLog); fail-closed → el front cae a GAS
  select (estado = 'ABIERTA') into v_caja_ok from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA'); end if;

  -- correlativo atómico de la serie B/F (idempotente por ref_local: en carrera ambas obtienen el MISMO número)
  v_num  := me.siguiente_correlativo(v_serie, v_ref);
  v_corr := v_serie || '-' || lpad(v_num::text, 6, '0');
  v_id   := 'V-' || (floor(extract(epoch from clock_timestamp()) * 1000))::bigint::text
                 || '-' || substr(md5(random()::text || clock_timestamp()::text || v_ref), 1, 8);

  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
                         tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio,
                         ref_local, obs, tipo_doc_cliente, nf_estado)
  values (v_id, now(), p->>'vendedor', p->>'estacion', coalesce(p->>'cliente_doc',''), coalesce(p->>'cliente_nombre',''),
          coalesce((p->>'total')::numeric, 0), v_tipo,
          coalesce(p->>'forma_pago','EFECTIVO'), v_corr, v_caja,
          coalesce(p->>'dispositivo_id',''), 'COMPLETADO', v_ref, coalesce(p->>'obs',''),
          coalesce((p->>'tipo_doc_cliente')::int, 0), 'PENDIENTE')
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;
  get diagnostics v_ins = row_count;

  -- carrera: otra ejecución ganó por ref_local → devolver la existente (no duplica)
  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_ref limit 1;
    if found then return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo,
                              'nf_estado',coalesce(v_ex.nf_estado,''),'nf_hash',coalesce(v_ex.nf_hash,''),'nf_enlace',coalesce(v_ex.nf_enlace,'')); end if;
  end if;

  -- detalle (idempotente por (id_venta,linea))
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
$fn$;

-- Patch del resultado NF tras emitir (set por el front con lo que devuelve la Edge emitir-cpe). Por ref_local.
create or replace function me.set_cpe_nf(p_ref_local text, p_nf jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_app text := me.jwt_app(); v_n int;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if nullif(btrim(coalesce(p_ref_local,'')),'') is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  update me.ventas
     set nf_estado = coalesce(p_nf->>'nf_estado', nf_estado),
         nf_hash   = coalesce(p_nf->>'nf_hash',   nf_hash),
         nf_enlace = coalesce(p_nf->>'nf_enlace', nf_enlace)
   where ref_local = p_ref_local;
  get diagnostics v_n = row_count;
  return jsonb_build_object('status','success','actualizadas', v_n);
end;
$fn$;

revoke all on function me.crear_cpe_directo(jsonb) from public;
revoke all on function me.set_cpe_nf(text, jsonb) from public;
grant execute on function me.crear_cpe_directo(jsonb) to authenticated;
grant execute on function me.set_cpe_nf(text, jsonb) to authenticated;

-- Flag central (default OFF). Prender solo cuando los secrets NubeFact estén seteados + probado.
insert into mos.config (clave, valor, descripcion) values
  ('ME_CPE_DIRECTO','0','ME: emision CPE (boleta/factura) directa via Edge emitir-cpe (toda la flota)')
on conflict (clave) do nothing;
