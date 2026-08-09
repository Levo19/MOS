-- ════════════════════════════════════════════════════════════════════
-- 721 — COTEJO DE COSTOS POR GUÍA (lectura pura, para la Mesa de Compras).
--
-- DIRECTRIZ DEL DUEÑO (2026-08-08): "en zonas se registra una guía y es lo mismo
-- que en WH: solo un registro, una PRESUNCIÓN. Es en MOS donde el admin registra
-- y coteja costos, y es admin/master quien pone precios."
--
-- El problema que arregla: la Mesa marcaba una compra EN ZONA como costeada
-- leyendo el CATÁLOGO (mos.productos.precio_costo). Como casi todo producto ya
-- tiene costo, TODAS las compras de zona nacían "1/1 completas" sin que ningún
-- admin las hubiera cotejado. Eso contradice la directriz.
--
-- Fuente de verdad correcta: mos.historial_precio_costo, que YA registra con
-- id_guia cada costo confirmado por el admin desde el Paso 1
-- (mos.aplicar_costos_compra, 431 — y 556 los retira al deshacer).
--
-- Esta RPC NO calcula dinero ni escribe nada: sólo cuenta, por guía, cuántos
-- productos distintos tienen un COSTO confirmado vivo. La completitud de la
-- Mesa pasa a salir de acá.
-- ════════════════════════════════════════════════════════════════════

create or replace function mos.cotejo_costos_guias(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_guias text[];
  v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(p->'idGuias') <> 'array' then
    return jsonb_build_object('ok',false,'error','Requiere idGuias[]');
  end if;

  select array_agg(btrim(x)) into v_guias
    from jsonb_array_elements_text(p->'idGuias') t(x)
   where btrim(coalesce(x,'')) <> '';

  if v_guias is null or array_length(v_guias,1) is null then
    return jsonb_build_object('ok',true,'data', '{}'::jsonb);
  end if;
  -- techo defensivo: la Mesa pagina; nunca pedimos miles de guías de un golpe
  if array_length(v_guias,1) > 400 then
    return jsonb_build_object('ok',false,'error','Demasiadas guías (máx 400)');
  end if;

  -- COSTO vivo = entrada COSTO de esa guía cuyo producto no fue revertido después
  -- (556 borra las entradas al deshacer, así que basta con contar lo que queda).
  select coalesce(jsonb_object_agg(g.id_guia, jsonb_build_object(
           'n',  g.n,
           'ts', g.ts
         )), '{}'::jsonb)
    into v_out
    from (
      select h.id_guia,
             count(distinct coalesce(nullif(btrim(h.id_producto),''), h.sku_base)) as n,
             max(h.ts) as ts
        from mos.historial_precio_costo h
       where h.id_guia = any(v_guias)
         and upper(btrim(coalesce(h.tipo,''))) = 'COSTO'
       group by h.id_guia
    ) g;

  return jsonb_build_object('ok', true, 'data', v_out);
end; $function$;

grant execute on function mos.cotejo_costos_guias(jsonb) to anon, authenticated, service_role;
