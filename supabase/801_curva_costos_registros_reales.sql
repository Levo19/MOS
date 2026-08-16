-- 801_curva_costos_registros_reales.sql — [DUEÑO] "si separaste los que fueron anulados,
-- ¿por qué los muestras aquí en registros? La idea es mostrar los registros que están en el
-- gráfico".
--
-- Tenía razón. El 800 sacó de la curva los costos anulados, pero dejó dentro tres clases de
-- ruido que el dueño vio en la lista de Registros del glutamato 1KG (LEV009):
--
--  (A) LAS FILAS DE ANULACIÓN. Nueve filas con `source='COMPRA_REVERSA'` seguían en la curva:
--      el 800 las excluía a propósito de la regla (para no anular la anulación). Pero una fila
--      COMPRA_REVERSA **no es un costo**: es el acto de deshacer uno. Aparecían como "Jesus ·
--      15-ago 7:24 p.m. · S/12.10", indistinguibles de una compra real. Salen de la curva.
--
--  (B) LA GUARDIA DEL COSTO VIGENTE, DEMASIADO ANCHA. El 800 decía "nunca ocultes una fila cuyo
--      valor sea el costo de hoy" para que la basura vigente fuera visible y corregible. Pero
--      protegía a CUALQUIER fila con ese valor: seis filas de S/12.10 del 30-jul, de una guía
--      REVERTIDA, se colaban solo por coincidir con el costo actual. Ahora la guardia aplica
--      únicamente a la regla del monto de bulto (donde su motivo es real: si hoy el catálogo
--      tiene un costo insano, el dueño debe verlo). Una compra revertida es un hecho probado
--      por la reversa: no admite excepción.
--
--  (C) DUPLICADOS DE LA MISMA COMPRA. Una guía escribe una fila de costo por línea, así que una
--      sola compra dejaba 6 registros idénticos (mismo segundo, mismo valor, misma guía). Se
--      agrupan en UN punto con `veces` = cuántas filas lo respaldan — se colapsa el ruido sin
--      esconder que hubo N aplicaciones.
--
-- Resultado en LEV009: la curva pasa de 22 puntos (18 de ellos ruido) a los DOS eventos de
-- costo que de verdad sobreviven sin revertir: 22-jul S/12.10 → 12-ago S/13.20.
--
-- `_costo_anulado` (booleano) se reemplaza por `_costo_anulacion`, que devuelve el MOTIVO (o
-- null si el costo es válido): una sola fuente de verdad para las dos listas de la RPC.

create or replace function mos._costo_anulacion(
  p_sku text, p_guia text, p_valor numeric, p_ts timestamptz,
  p_source text, p_precio_venta numeric, p_costo_vigente numeric)
returns text language sql stable security definer set search_path to '' as $$
  select case
    -- (A) la fila ES la anulación, no un costo: jamás es un punto de la curva.
    when upper(coalesce(p_source,'')) = 'COMPRA_REVERSA' then 'REVERSION'
    -- (1) la compra que trajo este costo fue deshecha después. Hecho probado: sin excepciones.
    when coalesce(p_guia,'') <> '' and exists (
           select 1 from mos.historial_precio_costo r
            where r.sku_base = p_sku and r.id_guia = p_guia
              and upper(coalesce(r.source,'')) = 'COMPRA_REVERSA'
              and r.ts >= p_ts
         ) then 'COMPRA_REVERTIDA'
    -- (2) monto del bulto cargado como unitario (costo >= precio de venta, con guía).
    --     (B) salvo que sea EXACTAMENTE el costo que hoy tiene el catálogo: esa basura tiene
    --     que verse, es la única forma de que el dueño sepa que hay algo que corregir.
    when p_precio_venta > 0 and p_valor >= p_precio_venta and coalesce(p_guia,'') <> ''
         and not (p_costo_vigente > 0 and abs(p_valor - p_costo_vigente) < 0.005)
         then 'MONTO_DE_BULTO'
    else null end;
$$;

grant execute on function mos._costo_anulacion(text,text,numeric,timestamptz,text,numeric,numeric)
  to anon, authenticated, service_role;

create or replace function mos.historial_precio_costo(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idProducto','')),'');
  v_prod   record;
  v_canon  record;
  v_grp    text;
  v_factor numeric := 1;
  v_pv     numeric := 0;
  v_pc     numeric := 0;
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
  v_pv     := coalesce(v_canon.precio_venta,0);
  v_pc     := coalesce(v_canon.precio_costo,0);

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idProducto',   v_prod.id_producto,
    'descripcion',  v_prod.descripcion,
    'codigoBarra',  v_prod.codigo_barra,
    'skuBase',      v_grp,
    'factor',       v_factor,
    'precioActual', coalesce(v_prod.precio_venta,0),
    'hermanos', coalesce((select count(*) from mos.productos e where e.sku_base = v_grp), 0),
    'costoActual',  round(v_pc * v_factor, 4),
    'precios', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
        'valor', h.valor, 'valorAnterior', h.valor_anterior,
        'usuario', h.usuario, 'source', h.source, 'appOrigen', h.app_origen,
        'motivo', coalesce(h.meta->>'motivo','')) order by h.ts)
      from mos.historial_precio_costo h
      where h.tipo='PRECIO' and h.id_producto = v_prod.id_producto), '[]'::jsonb),

    -- [801] LA CURVA = eventos de costo reales, uno por (fecha, valor, guía).
    'costos', coalesce((
      select jsonb_agg(x.obj order by x.ts) from (
        select h.ts,
          jsonb_build_object(
            'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
            'valor', round(h.valor * v_factor, 4),
            'valorAnterior', round(coalesce((array_agg(h.valor_anterior order by h.id))[1],0) * v_factor, 4),
            'usuario', (array_agg(h.usuario order by h.id))[1],
            'idGuia',  h.id_guia,
            'source',  (array_agg(h.source order by h.id))[1],
            'meta',    (array_agg(h.meta order by h.id))[1],
            'veces',   count(*)) obj      -- [801] cuántas líneas de la guía escribieron este costo
        from mos.historial_precio_costo h
        where h.tipo='COSTO' and h.sku_base = v_grp
          and mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc) is null
        group by h.ts, h.valor, h.id_guia
      ) x), '[]'::jsonb),

    -- [801] Los descartados, también agrupados y con el motivo. No se borran: se muestran aparte.
    'costosAnulados', coalesce((
      select jsonb_agg(y.obj order by y.ts desc) from (
        select h.ts,
          jsonb_build_object(
            'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
            'valor', round(h.valor * v_factor, 4),
            'usuario', (array_agg(h.usuario order by h.id))[1],
            'idGuia', h.id_guia,
            'source', (array_agg(h.source order by h.id))[1],
            'motivo', mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc),
            'veces',  count(*)) obj
        from mos.historial_precio_costo h
        where h.tipo='COSTO' and h.sku_base = v_grp
          and mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc) is not null
        group by h.ts, h.valor, h.id_guia, h.sku_base, h.source
      ) y), '[]'::jsonb)
  ));
end;
$function$;

-- el booleano del 800 queda sin usuarios: se retira para que nadie lo tome como fuente de verdad.
drop function if exists mos._costo_anulado(bigint,text,text,numeric,timestamptz,text,numeric,numeric);
