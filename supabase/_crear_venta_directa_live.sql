CREATE OR REPLACE FUNCTION me.crear_venta_directa(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- [500x-2b] sin items NO se mintea correlativo (un comprobante sin líneas no es auditable)
  if v_nit = 0 then return jsonb_build_object('status','error','error','SIN_ITEMS'); end if;

  -- caja ABIERTA + zona de la caja
  select (estado = 'ABIERTA'), zona_id into v_caja_ok, v_zona
  from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then
    return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA');
  end if;

  -- [MED16 · 500x-2] SERIE NV autoritativa desde Supabase (mos.series_documentales): estación primero,
  -- luego zona. OJO: el front manda tipo_doc='NOTA_DE_VENTA' pero la tabla guarda 'NOTA_VENTA' → match IN.
  -- Si no hay fila, cae al serie del front (compat). Resiste el drift de la Hoja stale (SQL 269).
  -- [500x-2b] serie SOLO de la zona de la caja (la estación user-supplied no debe cruzar zonas);
  -- dentro de la zona, prefiere la fila de la estación enviada.
  select serie into v_serie_sd from mos.series_documentales
   where activo and upper(tipo_documento) in ('NOTA_VENTA','NOTA_DE_VENTA','NV')
     and ( v_zona is null or v_zona = '' or id_zona = v_zona )
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
$function$
;
