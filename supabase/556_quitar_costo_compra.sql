-- ════════════════════════════════════════════════════════════════════
-- 556 — QUITAR (deshacer) el costo que una compra aplicó al catálogo.
--
-- Pedido del dueño: al escribir un monto en el Paso 1, el costo se aplica al
-- catálogo (mos.aplicar_costos_compra → precio_costo del canónico + historial).
-- Si el usuario borra el monto (× del chip), debe ser RETROACTIVO: revertir el
-- precio_costo al valor que tenía ANTES de que ESTA guía lo tocara, y limpiar
-- del historial las entradas COSTO·COMPRA de esta guía.
--
-- Semántica = UNDO preciso (no "poner 0"): restaura el `costoAnterior` de la
-- entrada MÁS ANTIGUA de esta guía (el valor previo real; puede ser 0 o un costo
-- legítimo anterior de OTRA compra). Deja un marcador COSTO_REVERTIDO.
-- ════════════════════════════════════════════════════════════════════

create or replace function mos.quitar_costo_compra(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_usr  text := coalesce(p->>'usuario','');
  it jsonb; v_cb text;
  v_prod record; v_canon record;
  v_restore numeric; v_prev numeric; v_n int;
  v_out jsonb := '[]'::jsonb; v_hist jsonb; v_nuevo_hist jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_guia is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;
  if jsonb_typeof(p->'items') <> 'array' then return jsonb_build_object('ok',false,'error','Requiere items[]'); end if;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_cb := upper(btrim(coalesce(it->>'codProducto', it->>'codigoBarra','')));
    if v_cb = '' then continue; end if;

    -- localizar producto (cb directo o equivalencia) y su canónico (misma lógica que aplicar_costos_compra)
    select pr.* into v_prod from mos.productos pr where upper(btrim(coalesce(pr.codigo_barra,''))) = v_cb limit 1;
    if v_prod.id_producto is null then
      select pr.* into v_prod from mos.productos pr
       join mos.equivalencias e on e.activo and upper(btrim(e.codigo_barra)) = v_cb
        and pr.sku_base = e.sku_base and coalesce(nullif(pr.factor_conversion,0),1) = 1 limit 1;
    end if;
    if v_prod.id_producto is null then
      v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', false, 'error', 'NO_EN_CATALOGO'); continue;
    end if;
    select pr.* into v_canon from mos.productos pr
     where (pr.sku_base = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto)
            or pr.id_producto = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto))
       and coalesce(nullif(pr.factor_conversion,0),1) = 1
       and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = ''
     order by pr.codigo_barra limit 1;
    if v_canon.id_producto is null then v_canon := v_prod; end if;

    v_prev := v_canon.precio_costo;

    -- valor a restaurar = costoAnterior de la entrada COSTO·COMPRA MÁS ANTIGUA de esta guía.
    -- (si no hay entrada de esta guía, no hay nada que deshacer → dejamos el costo tal cual.)
    select (e->>'costoAnterior')::numeric into v_restore
      from mos.productos pr, jsonb_array_elements(coalesce(pr.historial_cambios,'[]'::jsonb)) e
     where pr.id_producto = v_canon.id_producto
       and upper(coalesce(e->>'accion','')) = 'COSTO'
       and upper(coalesce(e->>'source','')) = 'COMPRA'
       and coalesce(e->>'idGuia','') = v_guia
     order by e->>'ts' asc
     limit 1;

    if v_restore is null then
      v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', true, 'sinCambio', true,
        'idCanonico', v_canon.id_producto, 'costoActual', v_prev);
      continue;
    end if;

    -- historial nuevo = quitar TODAS las entradas COSTO·COMPRA de esta guía + marcador REVERTIDO
    v_hist := jsonb_build_object('ts', to_char(now() at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
      'accion','COSTO_REVERTIDO', 'usuario', v_usr, 'source','COMPRA', 'idGuia', v_guia,
      'costoAnterior', v_prev, 'precioCosto', v_restore, 'compradoComo', v_canon.descripcion);
    select coalesce(jsonb_agg(e order by ord), '[]'::jsonb) into v_nuevo_hist
      from mos.productos pr, jsonb_array_elements(coalesce(pr.historial_cambios,'[]'::jsonb)) with ordinality x(e,ord)
     where pr.id_producto = v_canon.id_producto
       and not (upper(coalesce(e->>'accion','')) = 'COSTO'
                and upper(coalesce(e->>'source','')) = 'COMPRA'
                and coalesce(e->>'idGuia','') = v_guia);

    update mos.productos
       set precio_costo = v_restore,
           historial_cambios = case
             when jsonb_array_length(v_nuevo_hist || v_hist) >= 50 then
               (select jsonb_agg(e order by ord) from jsonb_array_elements(v_nuevo_hist || v_hist)
                  with ordinality x(e, ord) where ord > 1)
             else v_nuevo_hist || v_hist end,
           updated_at = now()
     where id_producto = v_canon.id_producto;
    get diagnostics v_n = row_count;

    v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', (v_n > 0),
      'idCanonico', v_canon.id_producto, 'skuBase', coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
      'descripcion', v_canon.descripcion, 'costoAnterior', v_prev, 'costoRestaurado', v_restore);
  end loop;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v_out));
end; $function$;

grant execute on function mos.quitar_costo_compra(jsonb) to anon, authenticated, service_role;
