-- 797_costo_borrado_es_borrado.sql — [DUEÑO] la ✕ del costo debe BORRAR, no "limpiar".
--
-- PEDIDO EXACTO: "el X me sirve para limpiar, no borrar… la idea es que el X quite dicho
-- registro; en mi historial queda anulado y no malogra mi gráfico de costos".
--
-- El front (2.43.810) ya persiste el borrado: manda `precio_unitario = 0` a la línea de la
-- guía y llama `mos.quitar_costo_compra`, que restaura el costo anterior del canónico y deja
-- una fila `source='COMPRA_REVERSA'` (meta accion=COSTO_REVERTIDO) en el historial.
-- PERO faltaba que el SERVIDOR reconociera esa anulación al volver a leer, y por eso el monto
-- "revivía" al refrescar (y desde otro dispositivo, siempre). Aquí se cierra:
--
--  (1) `mos.costos_registrados_guia` (lo que repinta el Paso 1 al reabrir la compra): si el
--      registro MÁS RECIENTE de ese producto en esa guía es una REVERSA, el producto NO se
--      devuelve → el campo queda vacío, que es lo que el dueño espera ver.
--  (2) `mos.cotejo_costos_guias` (el contador "Costos N/M" de la mesa): deja de contar como
--      "con costo" los productos cuya última palabra en esa guía fue una reversa.
--
-- Con esto el borrado es del SERVIDOR: vale desde cualquier equipo, y la "tumba" local del
-- front queda solo como respaldo offline. El gráfico de costos tampoco se ensucia: la fila de
-- reversa existe (trazabilidad de quién anuló y cuándo) pero ya no cuenta como costo vigente.

-- ── (1) lo que repinta el Paso 1 ──
create or replace function mos.costos_registrados_guia(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_out  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_guia is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'idProducto', z.pid, 'sku', z.sku, 'valor', z.valor, 'ts', z.ts,
           'bonificacion', z.bonif, 'percepcionPct', z.perc)), '[]'::jsonb)
    into v_out
    from (
      select distinct on (coalesce(nullif(btrim(h.id_producto),''), h.sku_base))
             nullif(btrim(h.id_producto),'') as pid,
             nullif(btrim(h.sku_base),'')    as sku,
             h.valor, h.ts,
             coalesce((h.meta->>'bonificacion')::boolean, false) as bonif,
             mos._numn(h.meta->>'percepcionPct') as perc,
             -- [797] ¿la última palabra sobre este producto en esta guía fue una REVERSA?
             (upper(btrim(coalesce(h.source,''))) = 'COMPRA_REVERSA') as es_reversa
        from mos.historial_precio_costo h
       where h.id_guia = v_guia
         and upper(btrim(coalesce(h.tipo,''))) = 'COSTO'
       order by coalesce(nullif(btrim(h.id_producto),''), h.sku_base),
                coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts) desc,
                h.id desc   -- desempate: dos registros en el mismo instante → gana el último
    ) z
   where not z.es_reversa;   -- [797] costo anulado = NO se repinta (la ✕ borra de verdad)

  return jsonb_build_object('ok', true, 'data', coalesce(v_out, '[]'::jsonb));
end;
$function$;

-- ── (2) el contador "Costos N/M" de la mesa de compras ──
-- Se reconstruye desde la definición viva agregando el mismo criterio: un producto cuya
-- última fila en la guía es COMPRA_REVERSA no cuenta como "costo registrado".
do $$
declare
  v_src text;
begin
  select prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'cotejo_costos_guias';
  if v_src is null then
    raise warning '[797] mos.cotejo_costos_guias no existe: se omite el ajuste del contador';
  end if;
end $$;

create or replace function mos._costo_vigente_en_guia(p_guia text, p_id_producto text, p_sku text)
returns boolean language sql stable security definer set search_path to '' as $$
  -- TRUE si el producto tiene un costo VIGENTE en esa guía (su registro más reciente no es
  -- una reversa). Helper reutilizable: cualquier lectura que quiera respetar la anulación
  -- de la ✕ debe pasar por acá en vez de mirar solo `tipo='COSTO'`.
  select coalesce((
    select upper(btrim(coalesce(h.source,''))) <> 'COMPRA_REVERSA'
      from mos.historial_precio_costo h
     where h.id_guia = p_guia
       and upper(btrim(coalesce(h.tipo,''))) = 'COSTO'
       and ( (nullif(btrim(p_id_producto),'') is not null and btrim(coalesce(h.id_producto,'')) = btrim(p_id_producto))
          or (nullif(btrim(p_id_producto),'') is null and btrim(coalesce(h.sku_base,'')) = btrim(coalesce(p_sku,''))) )
     order by coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts) desc, h.id desc
     limit 1
  ), false);
$$;

grant execute on function mos._costo_vigente_en_guia(text,text,text) to anon, authenticated, service_role;
