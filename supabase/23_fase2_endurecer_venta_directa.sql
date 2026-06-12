-- 23_fase2_endurecer_venta_directa.sql — [Lote1-B · fixes C3+A1+M2 de la revisión 2026-06-12]
-- Endurece me.crear_venta_directa (EN PRODUCCIÓN fleet-wide) que confiaba 100% en el body:
--   C3: dispositivo_id ahora sale del claim `sub` del JWT (no falsificable), no del payload.
--   C3: total debe cuadrar con Σ(items.subtotal) — tolerancia 0.01 (rechaza montos manipulados).
--   A1: caja debe estar ABIERTA (gap "ventas fantasma" que GAS cerró en v2.7.5; mismo patrón
--       que crear_movimiento_directo/crear_cpe_directo: idempotencia PRIMERO, validación después).
--   M2: zona_id se deriva de la caja → reportes por zona ya no pierden las ventas directas.
-- Fail-closed: cualquier rechazo hace que la PWA caiga al fallback GAS (que valida lo mismo)
-- → ninguna venta legítima se pierde; las manipuladas se rechazan en ambos paths.

-- Helper: claim 'sub' del JWT (deviceId minteado por GAS). '' si no hay token/claim.
create or replace function me.jwt_sub()
returns text language sql stable as $fn$
  select coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb) ->> 'sub', '');
$fn$;

create or replace function me.crear_venta_directa(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
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
  if v_serie is null then return jsonb_build_object('status','error','error','SERIE_REQUERIDA'); end if;
  -- etapa NV-only (CPE = SUNAT, sigue por GAS)
  if v_tipo not in ('NOTA_DE_VENTA','NV','') then return jsonb_build_object('status','error','error','SOLO_NV_DIRECTO'); end if;

  -- idempotencia PRIMERO: si ya existe por ref_local (reintento) → devolver la MISMA, sin re-validar
  -- caja/total (ya se validó cuando se creó; la caja pudo cerrar entre el 1er intento y el reintento).
  select * into v_ex from me.ventas where ref_local = v_ref limit 1;
  if found then
    return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo);
  end if;

  -- [Lote1-B · C3] total debe cuadrar con la suma de los items (solo si hay items; tolerancia 0.01).
  -- Un total manipulado (ej. 0.01 con carrito lleno) se rechaza → el fallback GAS también lo rechaza.
  select coalesce(sum((it->>'subtotal')::numeric), 0), count(*)
    into v_suma, v_nit
  from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it;
  if v_nit > 0 and abs(v_total - v_suma) > 0.01 then
    return jsonb_build_object('status','error','error','TOTAL_NO_CUADRA',
                              'detalle', 'total='||v_total||' suma_items='||v_suma);
  end if;

  -- [Lote1-B · A1] caja ABIERTA para una venta NUEVA (parity con procesarVenta de GAS y con
  -- crear_movimiento_directo). fail-closed: no encontrada o no-ABIERTA → rechazar (cae a GAS).
  -- De paso derivamos zona_id de la caja (M2: antes quedaba NULL en las ventas directas).
  select (estado = 'ABIERTA'), zona_id into v_caja_ok, v_zona
  from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then
    return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA');
  end if;

  -- correlativo atómico (idempotente por ref_local: en carrera, ambas ejecuciones obtienen el MISMO número)
  v_num  := me.siguiente_correlativo(v_serie, v_ref);
  v_corr := v_serie || '-' || lpad(v_num::text, 6, '0');
  -- [PK-collision-ALTO] sufijo aleatorio = colisión-resistente, manteniendo orden temporal.
  v_id   := 'V-' || (floor(extract(epoch from clock_timestamp()) * 1000))::bigint::text
                 || '-' || substr(md5(random()::text || clock_timestamp()::text || v_ref), 1, 8);

  -- [Lote1-B · C3] dispositivo_id = claim sub del JWT (verificado por la plataforma), NO el payload.
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

  -- carrera: otra ejecución ganó el insert por ref_local → devolver la existente (no duplica)
  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_ref limit 1;
    if found then return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo); end if;
    -- rama teóricamente inalcanzable: no insertó y tampoco existe → NO seguir (evita detalle huérfano)
    return jsonb_build_object('status','error','error','INSERT_INCONSISTENTE');
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
revoke all on function me.jwt_sub() from public;
grant execute on function me.jwt_sub() to authenticated;
