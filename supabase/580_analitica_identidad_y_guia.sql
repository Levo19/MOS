-- 580 · [Analítica precios · feedback del dueño] Identidad del producto + guía rica.
-- (1) historial_precio_costo: devolver nombre + código de barra + sku + canónico padre +
--     códigos EQUIVALENTES (el "dominio" que abarca ese precio) → el overlay muestra el
--     producto real, no el IDPRO interno.
-- (2) guia_preview: proveedor por NOMBRE (mos.proveedores), monto real (fallback a la suma
--     del detalle si monto_total=0), y FOTO del comprobante (para preview + link).

-- ── (1) historial_precio_costo: + identidad + equivalentes ─────────────────────────
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
    -- [580] identidad del producto consultado (para el header del overlay)
    'nombre',       coalesce(nullif(btrim(v_prod.descripcion),''), v_prod.id_producto),
    'codigoBarra',  coalesce(v_prod.codigo_barra,''),
    'skuBase',      coalesce(v_prod.sku_base,''),
    'esCanonico',   (v_canon.id_producto = v_prod.id_producto),
    'canonicoNombre',      case when v_canon.id_producto = v_prod.id_producto then null else coalesce(v_canon.descripcion,'') end,
    'canonicoCodigoBarra', case when v_canon.id_producto = v_prod.id_producto then null else coalesce(v_canon.codigo_barra,'') end,
    'equivalentes', coalesce((
      select jsonb_agg(distinct e.codigo_barra)
        from mos.equivalencias e
       where e.sku_base = v_grp and coalesce(e.activo, true)
         and coalesce(nullif(btrim(e.codigo_barra),''),'') <> ''), '[]'::jsonb),
    'factor', v_factor,
    'precioActual', v_prod.precio_venta,
    'costoActual',  round(coalesce(v_canon.precio_costo,0) * v_factor, 4),
    'precios', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
               'valor', h.valor, 'valorAnterior', h.valor_anterior,
               'usuario', h.usuario, 'source', h.source, 'appOrigen', h.app_origen,
               'motivo', coalesce(h.meta->>'motivo','')) order by h.ts)
      from mos.historial_precio_costo h
      where h.tipo='PRECIO' and h.id_producto = v_prod.id_producto), '[]'::jsonb),
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

-- ── (2) guia_preview: proveedor por nombre + monto real + foto del comprobante ─────
create or replace function wh.guia_preview(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_g  record; v_monto numeric;
begin
  if v_id is null then return jsonb_build_object('ok',false,'error','idGuia requerido'); end if;
  select * into v_g from wh.guias where id_guia = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  -- monto: el de la guía o, si es 0/null, la suma del detalle (cant × precio)
  v_monto := nullif(v_g.monto_total, 0);
  if v_monto is null then
    select sum(coalesce(d.cant_recibida, d.cantidad_aplicada, 0) * coalesce(d.precio_unitario,0))
      into v_monto from wh.guia_detalle d where d.id_guia = v_id;
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idGuia', v_g.id_guia,
    'fecha',  to_char(v_g.fecha at time zone 'America/Lima','YYYY-MM-DD'),
    'tipo',   coalesce(v_g.tipo,''),
    -- [580] proveedor por NOMBRE (mos.proveedores); fallback razón social OCR → id → —
    'proveedor', coalesce(
                   (select pv.nombre from mos.proveedores pv where pv.id_proveedor = v_g.id_proveedor and coalesce(nullif(btrim(pv.nombre),''),'') <> '' limit 1),
                   nullif(btrim(v_g.ocr_razon_social),''),
                   nullif(btrim(v_g.id_proveedor),''), '—'),
    'documento', coalesce(nullif(btrim(v_g.numero_documento),''),''),
    'monto',  coalesce(v_monto, 0),
    'foto',   coalesce(nullif(btrim(v_g.foto),''), ''),   -- [580] URL del comprobante (o '')
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
grant execute on function mos.historial_precio_costo(jsonb) to authenticated, service_role;
grant execute on function wh.guia_preview(jsonb) to authenticated, service_role;
notify pgrst, 'reload schema';
