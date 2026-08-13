-- 766 · La barra de PRECIOS cuenta COLOCACIONES reales (13-ago-2026, pedido del dueño).
-- Antes: "Precios 1/2" significaba "un precio YA CUADRABA con el margen objetivo" —
-- sin que nadie hiciera nada (caso compra NESTOR: comino figuraba ✓ con precio de
-- antes de julio). Ahora: un producto cuenta como "precio puesto" para una compra
-- SOLO si existe un evento PRECIO (colocación o confirmación) POSTERIOR al cotejo
-- de costo de ESA guía. Dos piezas:
--   (1) publicar_precio deja rastro TAMBIÉN cuando el precio se confirma sin cambio
--       (meta.confirmado=true) — antes esa acción era invisible.
--   (2) cotejo_costos_guias devuelve además `p` = productos de la guía con precio
--       colocado/confirmado después de su cotejo de costo.

-- índice para el EXISTS por sku+ts (la tabla crece con cada cambio de precio)
create index if not exists idx_hpc_tipo_sku_ts
  on mos.historial_precio_costo (tipo, sku_base, ts);

-- ═══ (1) publicar_precio: la confirmación sin cambio también es un acto ═══════
CREATE OR REPLACE FUNCTION mos.publicar_precio(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_pn   numeric := mos._numn(p->>'precioNuevo');
  v_id   text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_cod  text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_memb boolean := coalesce(nullif(btrim(coalesce(p->>'imprimirMembretes','')),'')::boolean, true);
  v_patch jsonb;
  v_res  jsonb;
  v_pa   numeric; v_pid text; v_psku text; v_pcod text; v_pdesc text;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_pn is null or v_pn <= 0 then return jsonb_build_object('ok',false,'error','Requiere precioNuevo válido'); end if;
  if v_id is null and v_cod is null and v_sku is null then
    return jsonb_build_object('ok',false,'error','Requiere idProducto, codigoBarra o skuBase');
  end if;

  begin
    select precio_venta, id_producto, sku_base, codigo_barra, descripcion
      into v_pa, v_pid, v_psku, v_pcod, v_pdesc
      from mos.productos
     where (v_id is not null and id_producto = v_id)
        or (v_cod is not null and codigo_barra = v_cod)
        or (v_sku is not null and sku_base = v_sku)
     limit 1;
  exception when others then null;
  end;

  v_patch := jsonb_build_object(
    'precioVenta', v_pn::text,
    'usuario',     coalesce(p->>'usuario',''),
    'motivoPrecio', coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'Publicación de precio')
  );
  if v_id  is not null then v_patch := v_patch || jsonb_build_object('idProducto', v_id); end if;
  if v_cod is not null then v_patch := v_patch || jsonb_build_object('codigoBarra', v_cod); end if;

  v_res := mos.actualizar_producto(v_patch);
  if not (v_res->>'ok')::boolean then return v_res; end if;

  -- [576/577] HISTORIAL de PRECIO. Best-effort + SOLO si hay id_producto real.
  -- [766] También cuando NO cambia: "confirmó el precio" es un acto del admin y es
  -- lo que la Mesa de compras cuenta como precio puesto. Sin esto, revisar y dejar
  -- el precio igual era invisible y la compra jamás llegaba a Finalizado.
  begin
    if coalesce(v_pid, v_id, '') <> '' then
      insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, app_origen, ts, meta)
      values (coalesce(v_pid, v_id), coalesce(v_psku, v_sku, ''), 'PRECIO', v_pn, v_pa,
              coalesce(p->>'usuario',''), coalesce(nullif(btrim(p->>'source'),''),'CATALOGO'),
              coalesce(nullif(btrim(p->>'appOrigen'),''),'MOS'), now(),
              jsonb_build_object('descripcion', coalesce(v_pdesc,''), 'motivo', coalesce(p->>'motivo',''))
              || case when v_pa is not distinct from v_pn
                      then jsonb_build_object('confirmado', true, 'motivo', 'Precio confirmado sin cambio')
                      else '{}'::jsonb end);
    end if;
  exception when others then null;
  end;

  begin
    if v_memb and v_pa is not null and v_pa <> v_pn then
      insert into mos.membretes_me_pendientes (id_alerta, fecha_cambio, fecha_ultimo_update, id_producto,
        sku_base, codigo_barra, descripcion, precio_anterior, precio_nuevo, usuario, estado, fecha_expira, fecha_impreso, id_lote)
      values ('MEM' || to_char(now(),'YYYYMMDDHH24MISSMS') || upper(substr(md5(random()::text),1,4)),
        now(), now(), coalesce(v_pid,''), coalesce(v_psku, v_sku, ''), coalesce(v_pcod, v_cod, ''),
        coalesce(v_pdesc,''), v_pa, v_pn, coalesce(p->>'usuario',''), 'PENDIENTE', now() + interval '7 days', null, '');
    end if;
  exception when others then null;
  end;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'precioNuevo', v_pn,
    'presentacionesActualizadas', coalesce((v_res->'data'->>'presentacionesActualizadas')::int, 0),
    'cambioPrecio', (v_pa is not null and v_pa <> v_pn),
    'precioAnterior', v_pa,
    'descripcion', coalesce(v_pdesc,''),
    'skuBase', coalesce(v_psku, v_sku, '')
  ));
end;
$function$;

-- ═══ (2) cotejo_costos_guias: + `p` = precios colocados DESPUÉS del costo de la guía ═══
CREATE OR REPLACE FUNCTION mos.cotejo_costos_guias(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if array_length(v_guias,1) > 400 then
    return jsonb_build_object('ok',false,'error','Demasiadas guías (máx 400)');
  end if;

  -- COSTO vivo por producto (último ts de esa guía) + [766] ¿hubo colocación de
  -- PRECIO del mismo producto/sku DESPUÉS de ese cotejo? (si el admin re-coteja el
  -- costo más tarde, el precio vuelve a "falta" — semántica correcta).
  select coalesce(jsonb_object_agg(g.id_guia, jsonb_build_object(
           'n',  g.n,
           'ts', g.ts,
           'p',  g.p
         )), '{}'::jsonb)
    into v_out
    from (
      select c.id_guia,
             count(*) as n,
             max(c.cts) as ts,
             count(*) filter (where exists (
               select 1 from mos.historial_precio_costo hp
                where upper(btrim(coalesce(hp.tipo,''))) = 'PRECIO'
                  and hp.ts >= c.cts
                  and ( (c.pid is not null and nullif(btrim(hp.id_producto),'') = c.pid)
                        or (c.sku is not null and nullif(btrim(hp.sku_base),'') = c.sku) )
             )) as p
        from (
          select h.id_guia,
                 coalesce(nullif(btrim(h.id_producto),''), h.sku_base) as key,
                 max(h.ts) as cts,
                 max(nullif(btrim(h.id_producto),'')) as pid,
                 max(nullif(btrim(h.sku_base),''))    as sku
            from mos.historial_precio_costo h
           where h.id_guia = any(v_guias)
             and upper(btrim(coalesce(h.tipo,''))) = 'COSTO'
           group by h.id_guia, coalesce(nullif(btrim(h.id_producto),''), h.sku_base)
        ) c
       group by c.id_guia
    ) g;

  return jsonb_build_object('ok', true, 'data', v_out);
end; $function$;
