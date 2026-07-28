-- 579 · [Analítica precios · fixes del 100x integral]
-- (1) Costos duplicados: la migración copió cada entrada COSTO de historial_cambios 1:1
--     (un producto puede tener N entradas del MISMO guía/valor por re-aplicaciones) → 500 filas,
--     ~43 distintas → el mismo punto se dibujaba varias veces. Limpieza + dedup en la READ.
-- (2) wh.guia_preview: agregar gate de app (paridad con las demás RPC; sin anon).

-- ── (1a) LIMPIEZA: borrar COSTO exactamente duplicados (mismo producto/valor/guía/ts) ──
delete from mos.historial_precio_costo h
 using (
   select id, row_number() over (partition by id_producto, valor, coalesce(id_guia,''), ts order by id) rn
     from mos.historial_precio_costo where tipo = 'COSTO'
 ) dup
 where h.id = dup.id and dup.rn > 1;

-- ── (1b) READ con DEDUP de costos (distinct-on ts+valor → un punto por fecha/valor) ──
create or replace function mos.historial_precio_costo(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_id text := nullif(btrim(coalesce(p->>'idProducto','')),'');
  v_prod record; v_canon record; v_factor numeric; v_grp text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select * into v_prod from mos.productos where id_producto = v_id limit 1;
  if v_prod.id_producto is null then return jsonb_build_object('ok',false,'error','PRODUCTO_NO_ENCONTRADO'); end if;

  select pr.* into v_canon from mos.productos pr
   where (pr.sku_base = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto)
          or pr.id_producto = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto))
     and coalesce(nullif(pr.factor_conversion,0),1) = 1
     and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = ''
   order by pr.codigo_barra limit 1;
  if v_canon.id_producto is null then v_canon := v_prod; end if;

  v_factor := case
    when coalesce(nullif(btrim(v_prod.codigo_producto_base),''),'') <> ''
         and coalesce(v_prod.factor_conversion_base,0) > 0 then v_prod.factor_conversion_base
    when coalesce(nullif(v_prod.factor_conversion,0),1) <> 1 then v_prod.factor_conversion
    else 1 end;
  v_grp := coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto);

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'precioActual', v_prod.precio_venta,
    'costoActual',  round(coalesce(v_canon.precio_costo,0) * v_factor, 4),
    'factor', v_factor,
    'esCanonico', (v_canon.id_producto = v_prod.id_producto),
    'precios', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
               'valor', h.valor, 'valorAnterior', h.valor_anterior,
               'usuario', h.usuario, 'source', h.source, 'appOrigen', h.app_origen,
               'motivo', coalesce(h.meta->>'motivo','')) order by h.ts)
      from mos.historial_precio_costo h
      where h.tipo='PRECIO' and h.id_producto = v_prod.id_producto), '[]'::jsonb),
    -- COSTO del canónico ×factor · DEDUP: un punto por (ts, valor) — evita puntos apilados
    'costos', coalesce((
      select jsonb_agg(x.obj order by x.ts) from (
        select distinct on (h.ts, h.valor) h.ts,
               jsonb_build_object(
                 'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
                 'valor', round(h.valor * v_factor, 4), 'valorCanonico', h.valor,
                 'usuario', h.usuario, 'idGuia', h.id_guia, 'source', h.source, 'meta', h.meta) obj
        from mos.historial_precio_costo h
        where h.tipo='COSTO' and h.sku_base = v_grp
        order by h.ts, h.valor, h.id desc
      ) x), '[]'::jsonb)
  ));
end; $function$;

-- ── (2) wh.guia_preview: gate de app (parametrizado con la config de WH) + sin anon ──
create or replace function wh.guia_preview(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_g  record;
begin
  -- NOTA: wh._claim_ok() solo admite ''/warehouseMos; MOS llama con app=MOS (igual que
  -- zona_pickup_detalle, que tampoco usa claim). Hardening = quitar anon (abajo), no bloquear MOS.
  if v_id is null then return jsonb_build_object('ok',false,'error','idGuia requerido'); end if;
  select * into v_g from wh.guias where id_guia = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idGuia', v_g.id_guia,
    'fecha',  to_char(v_g.fecha at time zone 'America/Lima','YYYY-MM-DD'),
    'tipo',   coalesce(v_g.tipo,''),
    'proveedor', coalesce(nullif(btrim(v_g.ocr_razon_social),''), nullif(btrim(v_g.id_proveedor),''), '—'),
    'documento', coalesce(nullif(btrim(v_g.numero_documento),''),''),
    'monto',  v_g.monto_total,
    'nItems', (select count(*) from wh.guia_detalle d where d.id_guia = v_id),
    'items',  coalesce((
      select jsonb_agg(x.obj order by x.linea) from (
        select d.linea, jsonb_build_object(
                 'nombre', coalesce((select pr.descripcion from mos.productos pr
                                      where upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto)) limit 1),
                                    d.cod_producto),
                 'cantidad', coalesce(d.cant_recibida, d.cantidad_aplicada, d.cant_esperada, 0),
                 'precio', d.precio_unitario) obj
        from wh.guia_detalle d where d.id_guia = v_id order by d.linea limit 8
      ) x), '[]'::jsonb)
  ));
end; $fn$;

revoke all on function wh.guia_preview(jsonb) from public;
revoke execute on function wh.guia_preview(jsonb) from anon;
grant execute on function wh.guia_preview(jsonb) to authenticated, service_role;
notify pgrst, 'reload schema';
