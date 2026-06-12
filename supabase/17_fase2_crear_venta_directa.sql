-- 17_fase2_crear_venta_directa.sql — Fase 2 ESCRITURA DIRECTA: la PWA crea la venta NV directo en Supabase.
-- SOLO NV (boleta/factura siguen por GAS por SUNAT). Idempotente por ref_local (reintento/doble-tap NO duplica).
-- Correlativo atómico vía me.siguiente_correlativo (mismo minter, idempotente por ref_local). security definer,
-- fail-closed por claim app=mosExpress. grant authenticated. NO toca Sheets (un mirror async lo mantiene al día).
create or replace function me.crear_venta_directa(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app   text := me.jwt_app();
  v_ref   text := nullif(btrim(coalesce(p->>'ref_local','')), '');
  v_serie text := nullif(btrim(coalesce(p->>'serie','')), '');
  v_tipo  text := upper(coalesce(p->>'tipo_doc',''));
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
  if v_serie is null then return jsonb_build_object('status','error','error','SERIE_REQUERIDA'); end if;
  -- etapa NV-only (CPE = SUNAT, sigue por GAS)
  if v_tipo not in ('NOTA_DE_VENTA','NV','') then return jsonb_build_object('status','error','error','SOLO_NV_DIRECTO'); end if;

  -- idempotencia: si ya existe por ref_local (reintento) → devolver la MISMA, sin re-crear ni re-mintear
  select * into v_ex from me.ventas where ref_local = v_ref limit 1;
  if found then
    return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo);
  end if;

  -- correlativo atómico (idempotente por ref_local: en carrera, ambas ejecuciones obtienen el MISMO número)
  v_num  := me.siguiente_correlativo(v_serie, v_ref);
  v_corr := v_serie || '-' || lpad(v_num::text, 6, '0');
  -- [PK-collision-ALTO] epoch_ms solo NO basta: 2 ventas concurrentes con ref_local distinto en el MISMO ms
  -- generaban el MISMO id_venta (PRIMARY KEY) → el on conflict es sobre (ref_local), no captura la violación
  -- de PK → la transacción aborta y la RPC falla. Sufijo aleatorio = colisión-resistente, manteniendo orden temporal.
  v_id   := 'V-' || (floor(extract(epoch from clock_timestamp()) * 1000))::bigint::text
                 || '-' || substr(md5(random()::text || clock_timestamp()::text || v_ref), 1, 8);

  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
                         tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio,
                         ref_local, obs, tipo_doc_cliente)
  values (v_id, now(), p->>'vendedor', p->>'estacion', coalesce(p->>'cliente_doc',''), coalesce(p->>'cliente_nombre',''),
          coalesce((p->>'total')::numeric, 0), coalesce(nullif(v_tipo,''),'NOTA_DE_VENTA'),
          coalesce(p->>'forma_pago','EFECTIVO'), v_corr, coalesce(p->>'id_caja',''),
          coalesce(p->>'dispositivo_id',''), 'COMPLETADO', v_ref, coalesce(p->>'obs',''),
          coalesce((p->>'tipo_doc_cliente')::int, 0))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;
  get diagnostics v_ins = row_count;

  -- carrera: otra ejecución ganó el insert por ref_local → devolver la existente (no duplica)
  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_ref limit 1;
    if found then return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo); end if;
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

  return jsonb_build_object('status','success','dedup',false,'id_venta',v_id,'correlativo',v_corr,'numero',v_num);
end;
$fn$;

revoke all on function me.crear_venta_directa(jsonb) from public;
grant execute on function me.crear_venta_directa(jsonb) to authenticated;
