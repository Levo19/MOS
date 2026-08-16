-- 799_reversa_costo_sana.sql — [DINERO] la reversa de costo dejaba de restaurar basura.
--
-- SÍNTOMA (15-ago, en vivo): el dueño borraba el costo y volvía. Historial real de LEV009:
--   20:15:36 | LEV009 | 13.20 → 712.80 | COMPRA_REVERSA   ← la "reversa" SUBIÓ el costo a basura
--
-- CAUSA — el bucle se auto-envenena:
--   1. Se aplica el costo del BULTO como unitario (712.80 en un producto que se vende a 14.50).
--   2. Se revierte: `quitar_costo_compra` restaura el `costoAnterior` de la entrada de esa guía
--      y BORRA esas entradas del historial del producto.
--   3. Al reabrir/guardar la compra, el costo se RE-APLICA y se graba una entrada nueva cuyo
--      `costoAnterior` es el costo vigente en ese momento… que ya estaba contaminado (712.80).
--   4. La siguiente reversa "restaura" 712.80. Y así, cada vuelta refuerza la basura.
--   Agravante: las entradas de una misma guía comparten `ts` al segundo (16-jul 07:22:20), así que
--   `order by e->>'ts' asc limit 1` elegía una de las dos de forma indeterminista.
--
-- FIX (defensa en dos capas, sin cambiar el flujo normal):
--   (a) Desempate determinista: entre entradas del mismo `ts` gana el `costoAnterior` MENOR
--       (el más antiguo real es el que traía el costo sano; el contaminado siempre es el grande).
--   (b) FILTRO DE SANIDAD: un costo a restaurar que sea >= al precio de venta es basura casi
--       siempre (vender por debajo del costo no es el caso normal). Si el valor candidato es
--       insano, se busca en `mos.historial_precio_costo` el último costo SANO (de otra fuente,
--       menor al precio de venta). Si no existe ninguno, se deja el producto SIN costo (0) — que
--       es la verdad ("no sé cuánto costó") y no envenena el margen ni el gráfico.
--   El resto del comportamiento (marcador COSTO_REVERTIDO, limpieza de entradas de la guía,
--   registro en mos.historial_precio_costo) queda igual.

create or replace function mos._costo_restaurable(p_id_producto text, p_guia text)
returns numeric language plpgsql stable security definer set search_path to ''
as $$
declare
  v_pv   numeric;
  v_cand numeric;
  v_sano numeric;
begin
  select precio_venta into v_pv from mos.productos where id_producto = p_id_producto limit 1;

  -- (a) candidato = costoAnterior de la entrada COSTO·COMPRA más antigua de esa guía;
  --     desempate determinista por el valor MENOR (el sano es el chico).
  select min((e->>'costoAnterior')::numeric) into v_cand
    from mos.productos pr, jsonb_array_elements(coalesce(pr.historial_cambios,'[]'::jsonb)) e
   where pr.id_producto = p_id_producto
     and upper(coalesce(e->>'accion','')) = 'COSTO'
     and upper(coalesce(e->>'source','')) = 'COMPRA'
     and coalesce(e->>'idGuia','') = p_guia
     and (e->>'costoAnterior') ~ '^[0-9.]+$';

  -- (b) ¿es sano? (hay precio de venta y el costo queda por debajo)
  if v_cand is not null and (coalesce(v_pv,0) <= 0 or v_cand < v_pv) then
    return v_cand;
  end if;

  -- candidato insano → último costo SANO registrado que NO venga de esta guía
  select h.valor into v_sano
    from mos.historial_precio_costo h
   where h.id_producto = p_id_producto
     and h.tipo = 'COSTO'
     and coalesce(h.id_guia,'') <> p_guia
     and h.valor > 0
     and (coalesce(v_pv,0) <= 0 or h.valor < v_pv)
   order by h.ts desc
   limit 1;

  -- sin nada sano a la vista → 0 = "sin costo" (honesto; el margen usa el estimado y no miente)
  return coalesce(v_sano, 0);
end;
$$;

grant execute on function mos._costo_restaurable(text,text) to anon, authenticated, service_role;

-- ── quitar_costo_compra: usa el selector sano ──
do $$
declare
  v_src text;
  v_new text;
begin
  select prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'quitar_costo_compra';
  if v_src is null then
    raise exception '[799] mos.quitar_costo_compra no existe';
  end if;

  -- Reemplaza EXACTAMENTE el SELECT que elegía el valor a restaurar por la llamada al helper.
  v_new := replace(v_src,
$old$    select (e->>'costoAnterior')::numeric into v_restore
      from mos.productos pr, jsonb_array_elements(coalesce(pr.historial_cambios,'[]'::jsonb)) e
     where pr.id_producto = v_canon.id_producto
       and upper(coalesce(e->>'accion','')) = 'COSTO'
       and upper(coalesce(e->>'source','')) = 'COMPRA'
       and coalesce(e->>'idGuia','') = v_guia
     order by e->>'ts' asc
     limit 1;$old$,
$new$    -- [799] selector SANO: desempate determinista + rechazo de valores basura
    -- (costo >= precio de venta) + caída a "sin costo" antes que envenenar el margen.
    if exists (
      select 1 from mos.productos pr, jsonb_array_elements(coalesce(pr.historial_cambios,'[]'::jsonb)) e
       where pr.id_producto = v_canon.id_producto
         and upper(coalesce(e->>'accion','')) = 'COSTO'
         and upper(coalesce(e->>'source','')) = 'COMPRA'
         and coalesce(e->>'idGuia','') = v_guia
    ) then
      v_restore := mos._costo_restaurable(v_canon.id_producto, v_guia);
    else
      v_restore := null;
    end if;$new$);

  if v_new = v_src then
    raise exception '[799] no se pudo parchear quitar_costo_compra: el bloque objetivo cambió';
  end if;

  execute 'create or replace function mos.quitar_costo_compra(p jsonb) returns jsonb language plpgsql security definer set search_path to '''' as $fn$'
          || v_new || '$fn$';
  raise notice '[799] quitar_costo_compra parcheada con el selector sano';
end $$;
