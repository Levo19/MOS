-- 806_costo_vigente_derivado_de_la_ultima_fecha.sql
--
-- [DUEÑO, textual] «No importa si alguien entró a una fecha anterior. Lo que importa es el último
-- costo registrado, o sea el de la ÚLTIMA FECHA. Si esa está vacía va a la anterior, y así. Así
-- el costo de hoy sea de un mes anterior no importa, queda como historial, porque lo que importa
-- es la última fecha que ingresó la mercadería.»
--
-- El 805 puso un CANDADO en la escritura (una guía vieja no pisa el costo vigente). Eso arreglaba
-- el caso concreto, pero NO es la regla completa: si el costo más nuevo se anula después —una
-- reversa, o una compra que resulta ser monto de bulto— el campo se queda con lo que tenía y
-- nadie lo hace "caer al anterior". La regla del dueño no es un candado, es una DERIVACIÓN.
--
-- Acá se implementa tal cual: el costo vigente NO se escribe a mano nunca más; se RECALCULA desde
-- el historial cada vez que ese historial cambia.
--
--   costo vigente = valor de la fila de COSTO **válida** más reciente por FECHA DE GUÍA
--                   (desempate: la escrita más tarde). Si no hay ninguna válida, no se toca nada
--                   (que el admin decida; mentir un costo es peor que dejarlo a la vista).
--
-- "Válida" = la misma definición que ya usa el gráfico (`mos._costo_anulacion`): no es una fila de
-- reversa, su compra no fue revertida, y no es un monto de bulto cargado como unitario. Se le pasa
-- costo_vigente = 0 a propósito: la excepción "nunca ocultes el costo de hoy" existe para que la
-- basura VIGENTE se vea en el gráfico, pero jamás debe servir para ELEGIR el costo vigente.
--
-- Con esto se cumplen los tres casos que planteó el dueño:
--   · la última fecha tiene costo válido      → ese es el vigente
--   · la última fecha quedó vacía o anulada   → cae solo a la anterior, y así hacia atrás
--   · el costo vigente termina siendo de hace un mes → correcto, es la última mercadería que entró

create or replace function mos.costo_vigente_de(p_sku text)
returns numeric language sql stable security definer set search_path to '' as $$
  -- Último costo VÁLIDO del grupo, por fecha de guía. NULL si no hay ninguno.
  select h.valor
    from mos.historial_precio_costo h
    join lateral (
      select coalesce(pr.precio_venta, 0) pv
        from mos.productos pr
       where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = p_sku
         and coalesce(nullif(pr.factor_conversion,0),1) = 1
       order by pr.codigo_barra limit 1
    ) c on true
   where h.tipo = 'COSTO'
     and h.sku_base = p_sku
     and h.valor > 0
     and mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, c.pv, 0) is null
   order by h.ts desc, h.id desc
   limit 1
$$;

grant execute on function mos.costo_vigente_de(text) to anon, authenticated, service_role;

create or replace function mos.recalcular_costo_vigente(p_sku text)
returns numeric language plpgsql security definer set search_path to '' as $$
declare v_costo numeric;
begin
  if coalesce(btrim(p_sku),'') = '' then return null; end if;
  v_costo := mos.costo_vigente_de(p_sku);
  if v_costo is null or v_costo <= 0 then return null; end if;   -- sin costo válido: no se inventa
  update mos.productos
     set precio_costo = v_costo
   where coalesce(nullif(btrim(sku_base),''), id_producto) = p_sku
     and coalesce(nullif(factor_conversion,0),1) = 1
     and coalesce(precio_costo,0) is distinct from v_costo;
  return v_costo;
end $$;

grant execute on function mos.recalcular_costo_vigente(text) to anon, authenticated, service_role;

-- ── Enganche en los DOS caminos que mueven el historial de costo ──
create or replace function mos._mig806_patch(p_fn text, p_old text, p_new text, p_veces int)
returns void language plpgsql as $$
declare v_def text; v_new text; v_oid oid; v_n int;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = p_fn order by p.oid limit 1;
  if v_oid is null then raise exception '[806] mos.% no existe', p_fn; end if;
  v_def := pg_get_functiondef(v_oid);
  v_n := (length(v_def) - length(replace(v_def, p_old, ''))) / nullif(length(p_old), 0);
  if v_n <> p_veces then
    raise exception '[806] mos.%: se esperaban % ocurrencias y hay %', p_fn, p_veces, v_n;
  end if;
  v_new := replace(v_def, p_old, p_new);
  execute v_new;
end $$;

-- (1) al APLICAR un costo: se registra la historia y recién ahí se deriva el vigente.
select mos._mig806_patch('aplicar_costos_compra',
$old$    v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', true,
      'idCanonico', v_canon.id_producto, 'skuBase', coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
      'descripcion', v_canon.descripcion, 'costoAnterior', v_prev, 'costoNuevo', v_costo_canon);$old$,
$new$    -- [806] El costo vigente NO es "lo último que se escribió", es el de la ÚLTIMA FECHA con
    -- costo válido. Se deriva del historial recién ahora, que ya incluye esta compra.
    v_costo_canon := coalesce(
      mos.recalcular_costo_vigente(coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto)),
      v_costo_canon);

    v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', true,
      'idCanonico', v_canon.id_producto, 'skuBase', coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
      'descripcion', v_canon.descripcion, 'costoAnterior', v_prev, 'costoNuevo', v_costo_canon);$new$, 1);

-- (2) al QUITAR un costo (la ✕ del Paso 1): la reversa ya quedó en el historial, así que el
--     vigente debe CAER SOLO a la fecha anterior. Esto es "si esa fecha está vacía, va a la
--     anterior" funcionando de verdad.
select mos._mig806_patch('quitar_costo_compra',
$old$    v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', (v_n > 0),
      'idCanonico', v_canon.id_producto, 'skuBase', coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
      'descripcion', v_canon.descripcion, 'costoAnterior', v_prev, 'costoRestaurado', v_restore);$old$,
$new$    -- [806] tras la reversa, el vigente cae solo a la última fecha que SÍ tiene costo válido.
    v_restore := coalesce(
      mos.recalcular_costo_vigente(coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto)),
      v_restore);

    v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', (v_n > 0),
      'idCanonico', v_canon.id_producto, 'skuBase', coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
      'descripcion', v_canon.descripcion, 'costoAnterior', v_prev, 'costoRestaurado', v_restore);$new$, 1);

drop function mos._mig806_patch(text,text,text,int);
