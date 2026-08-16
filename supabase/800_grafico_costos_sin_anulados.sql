-- 800_grafico_costos_sin_anulados.sql — [DUEÑO] "de qué sirve arreglar el margen si el
-- gráfico sigue mostrando la basura".
--
-- Con costos erróneos de S/712.80 / 604.10 / 320.00 conviviendo con los reales (10.30-13.20),
-- la curva precio·costo queda con la escala reventada: no se ve NADA de la variación real.
-- El dueño ya lo había pedido al arrancar esto: "así ese registro queda anulado y no malogra
-- ni mi gráfico de costos".
--
-- QUÉ HACE: marca como ANULADO todo costo cuya compra fue revertida y lo EXCLUYE de la serie
-- del gráfico. NO borra nada — la fila sigue en `mos.historial_precio_costo` para auditoría, y
-- la RPC la devuelve aparte en `costosAnulados` por si algún día se quiere ver el tachado.
--
-- REGLA DE ANULACIÓN (dos vías, ambas conservadoras):
--   (1) REVERTIDO: existe una fila `COMPRA_REVERSA` de la MISMA guía y del mismo grupo (sku)
--       posterior a ese costo → esa compra fue deshecha, su costo no es historia válida.
--   (2) INSANO: el costo registrado es >= al precio de venta vigente del canónico (vender por
--       debajo del costo no es el caso normal; es la firma del "monto del bulto" mal cargado).
--       Se aplica solo a costos que además tengan guía (vienen de una compra).
-- El costo VIGENTE del producto nunca se oculta, aunque sea insano: si el catálogo hoy tiene
-- ese costo, el dueño debe verlo para poder corregirlo.

create or replace function mos.historial_precio_costo(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idProducto','')),'');
  v_prod   record;
  v_canon  record;
  v_grp    text;
  v_factor numeric := 1;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select * into v_prod from mos.productos where id_producto = v_id limit 1;
  if v_prod.id_producto is null then return jsonb_build_object('ok',false,'error','PRODUCTO_NO_ENCONTRADO'); end if;

  select pr.* into v_canon from mos.productos pr
   where (pr.sku_base = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto)
          or pr.id_producto = v_prod.id_producto)
     and coalesce(nullif(pr.factor_conversion,0),1) = 1
   order by pr.codigo_barra limit 1;
  if v_canon.id_producto is null then v_canon := v_prod; end if;

  v_grp    := coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto);
  v_factor := coalesce(nullif(v_prod.factor_conversion,0),1);

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idProducto',   v_prod.id_producto,
    'descripcion',  v_prod.descripcion,
    'codigoBarra',  v_prod.codigo_barra,
    'skuBase',      v_grp,
    'factor',       v_factor,
    'precioActual', coalesce(v_prod.precio_venta,0),
    'hermanos', coalesce((
      select count(*) from mos.productos e
       where e.sku_base = v_grp), 0),   -- [800] mos.productos no tiene columna `activo`
    'costoActual',  round(coalesce(v_canon.precio_costo,0) * v_factor, 4),
    'precios', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
        'valor', h.valor, 'valorAnterior', h.valor_anterior,
        'usuario', h.usuario, 'source', h.source, 'appOrigen', h.app_origen,
        'motivo', coalesce(h.meta->>'motivo','')) order by h.ts)
      from mos.historial_precio_costo h
      where h.tipo='PRECIO' and h.id_producto = v_prod.id_producto), '[]'::jsonb),
    -- [800] SERIE LIMPIA: sin los costos anulados (compra revertida o monto de bulto).
    'costos', coalesce((
      select jsonb_agg(x.obj order by x.ts) from (
        select h.ts,
          jsonb_build_object(
            'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
            'valor', round(h.valor * v_factor, 4), 'valorAnterior', round(coalesce(h.valor_anterior,0) * v_factor, 4),
            'usuario', h.usuario, 'idGuia', h.id_guia, 'source', h.source, 'meta', h.meta) obj
        from mos.historial_precio_costo h
        where h.tipo='COSTO' and h.sku_base = v_grp
          and not mos._costo_anulado(h.id, h.sku_base, h.id_guia, h.valor, h.ts, h.source, coalesce(v_canon.precio_venta,0), coalesce(v_canon.precio_costo,0))
        order by h.ts, h.valor, h.id desc
      ) x), '[]'::jsonb),
    -- [800] los anulados NO se pierden: viajan aparte (auditoría / futuro "ver descartados").
    'costosAnulados', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
        'valor', round(h.valor * v_factor, 4), 'usuario', h.usuario,
        'idGuia', h.id_guia, 'source', h.source,
        -- [800] POR QUÉ salió del gráfico (mismo orden de reglas que _costo_anulado)
        'motivo', case when upper(coalesce(h.source,'')) <> 'COMPRA_REVERSA' and exists (
                         select 1 from mos.historial_precio_costo r
                          where r.sku_base = h.sku_base and r.id_guia = h.id_guia
                            and upper(coalesce(r.source,'')) = 'COMPRA_REVERSA' and r.ts >= h.ts)
                       then 'COMPRA_REVERTIDA' else 'MONTO_DE_BULTO' end) order by h.ts)
      from mos.historial_precio_costo h
      where h.tipo='COSTO' and h.sku_base = v_grp
        and mos._costo_anulado(h.id, h.sku_base, h.id_guia, h.valor, h.ts, h.source, coalesce(v_canon.precio_venta,0), coalesce(v_canon.precio_costo,0))), '[]'::jsonb)
  ));
end;
$function$;

-- Helper de anulación (estable, reutilizable por cualquier lectura del historial de costos).
create or replace function mos._costo_anulado(
  p_id bigint, p_sku text, p_guia text, p_valor numeric, p_ts timestamptz,
  p_source text, p_precio_venta numeric, p_costo_vigente numeric)
returns boolean language sql stable security definer set search_path to '' as $$
  select
    -- nunca ocultar el costo que HOY está en el catálogo: si es basura, el dueño debe verla.
    case when p_costo_vigente > 0 and abs(p_valor - p_costo_vigente) < 0.005 then false
    -- (1) la compra que trajo este costo fue revertida después
    when p_guia is not null and p_guia <> '' and upper(coalesce(p_source,'')) <> 'COMPRA_REVERSA'
         and exists (
           select 1 from mos.historial_precio_costo r
            where r.sku_base = p_sku and r.id_guia = p_guia
              and upper(coalesce(r.source,'')) = 'COMPRA_REVERSA'
              and r.ts >= p_ts
         ) then true
    -- (2) monto de bulto cargado como unitario: costo >= precio de venta
    when p_precio_venta > 0 and p_valor >= p_precio_venta
         and p_guia is not null and p_guia <> '' then true
    else false end;
$$;

grant execute on function mos._costo_anulado(bigint,text,text,numeric,timestamptz,text,numeric,numeric)
  to anon, authenticated, service_role;
