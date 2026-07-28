-- 576 · [Analítica de precios · FASE 1] Historial de PRECIO+COSTO en tabla dedicada.
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEMA: el gráfico (historial_precio_costo) leía las 2 series de productos.historial_cambios,
-- pero NADIE escribía el precio ahí (publicar_precio→actualizar_producto no historiaba) y el costo
-- solo se logueaba en el CANÓNICO → los hijos (presentación/derivado) salían doblemente vacíos.
-- Además el JSON está capado a 50 y sin provenance rico. Modelo del dueño:
--   · COSTO = "como lo compré" → fecha de la GUÍA (origen), cae en CASCADA al grupo.
--   · PRECIO = "el que le pongo de ahora" → momento (now, con hora); por PRODUCTO (canónico/deriv/pres).
-- SOLUCIÓN: tabla append-only mos.historial_precio_costo. PRECIO keyeado por id_producto (único);
-- COSTO keyeado por sku_base del canónico (grupo) → la RPC lo escala ×factor para cada hijo.
-- Best-effort en los INSERT (un log JAMÁS rompe el publish de precio/costo). Cero-GAS.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1) TABLA ──────────────────────────────────────────────────────────────────
create table if not exists mos.historial_precio_costo (
  id             bigint generated always as identity primary key,
  id_producto    text,                 -- PRECIO: producto propio · COSTO: el canónico
  sku_base       text,                 -- grupo (para el cascade de COSTO)
  tipo           text not null,        -- 'PRECIO' | 'COSTO'
  valor          numeric not null,     -- precio de venta · o costo del CANÓNICO (unidad canónica)
  valor_anterior numeric,
  usuario        text,
  source         text,                 -- CATALOGO | COMPRA_PASO2 | COMPRA | SEED
  app_origen     text,
  id_guia        text,                 -- solo COSTO
  ts             timestamptz not null default now(),  -- COSTO: fecha guía · PRECIO: now
  meta           jsonb
);
create index if not exists ix_hpc_precio on mos.historial_precio_costo (id_producto, ts) where tipo = 'PRECIO';
create index if not exists ix_hpc_costo  on mos.historial_precio_costo (sku_base, ts)    where tipo = 'COSTO';

-- ── 2) MIGRACIÓN: COSTO ya existentes en historial_cambios → tabla (una sola vez) ──
-- Back-datea a la fecha de la GUÍA (wh.guias) cuando existe; si no, la fecha del historial.
insert into mos.historial_precio_costo (id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, id_guia, ts, meta)
select pr.id_producto,
       coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto),
       'COSTO',
       mos._numn(e->>'precioCosto'),
       mos._numn(e->>'costoAnterior'),
       e->>'usuario',
       'COMPRA',
       e->>'idGuia',
       coalesce(g.fecha, nullif(e->>'ts','')::timestamptz, now()),
       jsonb_build_object('compradoComo', e->>'compradoComo', 'factorAplicado', mos._numn(e->>'factorAplicado'), 'migrado', true)
from mos.productos pr
cross join lateral jsonb_array_elements(coalesce(pr.historial_cambios,'[]'::jsonb)) e
left join wh.guias g on g.id_guia = nullif(e->>'idGuia','')
where e->>'accion' = 'COSTO'
  and mos._numn(e->>'precioCosto') is not null
  and not exists (  -- idempotente: no re-migrar si ya corrió
    select 1 from mos.historial_precio_costo h
     where h.id_producto = pr.id_producto and h.tipo='COSTO'
       and coalesce(h.meta->>'migrado','') = 'true'
       and h.valor = mos._numn(e->>'precioCosto')
       and coalesce(h.id_guia,'') = coalesce(e->>'idGuia',''));

-- ── 3) publicar_precio: + log PRECIO (best-effort). Base = def viva 427 + INSERT. ──
create or replace function mos.publicar_precio(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
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

  -- [576] HISTORIAL de PRECIO (append-only, por PRODUCTO). Best-effort: NUNCA rompe el publish.
  begin
    if v_pa is distinct from v_pn then
      insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, app_origen, ts, meta)
      values (coalesce(v_pid, v_id, ''), coalesce(v_psku, v_sku, ''), 'PRECIO', v_pn, v_pa,
              coalesce(p->>'usuario',''), coalesce(nullif(btrim(p->>'source'),''),'CATALOGO'),
              coalesce(nullif(btrim(p->>'appOrigen'),''),'MOS'), now(),
              jsonb_build_object('descripcion', coalesce(v_pdesc,''), 'motivo', coalesce(p->>'motivo','')));
    end if;
  exception when others then null;
  end;

  -- [hook membrete · best-effort · 427: respeta el toggle] NUNCA rompe el publish.
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

-- ── 4) aplicar_costos_compra: costo con FECHA DE GUÍA + log COSTO en tabla. Base = def viva. ──
create or replace function mos.aplicar_costos_compra(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_usr  text := coalesce(p->>'usuario','');
  v_guia_fecha timestamptz;
  it jsonb; v_cb text; v_costo numeric;
  v_prod record; v_canon record;
  v_factor numeric; v_costo_canon numeric; v_prev numeric;
  v_out jsonb := '[]'::jsonb;
  v_hist jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(p->'items') <> 'array' then
    return jsonb_build_object('ok',false,'error','Requiere items[]');
  end if;

  -- [576] fecha de ORIGEN del costo = fecha de la GUÍA (no la de registro). Fallback: now.
  if v_guia is not null then
    begin select g.fecha into v_guia_fecha from wh.guias g where g.id_guia = v_guia limit 1;
    exception when others then v_guia_fecha := null; end;
  end if;
  v_guia_fecha := coalesce(v_guia_fecha, now());

  for it in select * from jsonb_array_elements(p->'items') loop
    v_cb    := upper(btrim(coalesce(it->>'codProducto', it->>'codigoBarra','')));
    v_costo := mos._numn(it->>'costoUnitario');
    if v_cb = '' or v_costo is null or v_costo <= 0 then continue; end if;

    select pr.* into v_prod from mos.productos pr
     where upper(btrim(coalesce(pr.codigo_barra,''))) = v_cb limit 1;
    if v_prod.id_producto is null then
      select pr.* into v_prod from mos.productos pr
       join mos.equivalencias e on e.activo and upper(btrim(e.codigo_barra)) = v_cb
        and pr.sku_base = e.sku_base and coalesce(nullif(pr.factor_conversion,0),1) = 1
       limit 1;
    end if;
    if v_prod.id_producto is null then
      v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', false, 'error', 'NO_EN_CATALOGO');
      continue;
    end if;

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
    v_costo_canon := round(v_costo / nullif(v_factor,0), 4);
    v_prev := v_canon.precio_costo;

    -- historial_cambios (jsonb, cap 50) — se mantiene para consumidores existentes; ts = fecha guía.
    v_hist := jsonb_build_object('ts', to_char(v_guia_fecha at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
      'accion','COSTO', 'usuario', v_usr, 'source','COMPRA', 'idGuia', coalesce(v_guia,''),
      'costoAnterior', v_prev, 'precioCosto', v_costo_canon,
      'compradoComo', v_prod.descripcion, 'factorAplicado', v_factor);
    update mos.productos
       set precio_costo = v_costo_canon,
           historial_cambios = case
             when jsonb_array_length(coalesce(historial_cambios,'[]'::jsonb)) >= 50 then
               (select jsonb_agg(e order by ord)
                  from jsonb_array_elements(coalesce(historial_cambios,'[]'::jsonb) || v_hist)
                       with ordinality x(e, ord)
                 where ord > 1)
             else coalesce(historial_cambios,'[]'::jsonb) || v_hist
           end
     where id_producto = v_canon.id_producto;

    -- [576] HISTORIAL de COSTO en tabla (fuente de la analítica). sku_base = grupo del canónico.
    -- Best-effort: un fallo de log NO rompe la aplicación del costo.
    begin
      insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, id_guia, ts, meta)
      values (v_canon.id_producto, coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
              'COSTO', v_costo_canon, v_prev, v_usr, 'COMPRA', coalesce(v_guia,''), v_guia_fecha,
              jsonb_build_object('compradoComo', v_prod.descripcion, 'factorAplicado', v_factor));
    exception when others then null;
    end;

    v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', true,
      'idCanonico', v_canon.id_producto, 'skuBase', coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
      'descripcion', v_canon.descripcion, 'costoAnterior', v_prev, 'costoNuevo', v_costo_canon);
  end loop;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v_out));
end; $function$;

-- ── 5) historial_precio_costo (READ) reescrita: resuelve canónico+factor; precio propio, costo ×factor ──
create or replace function mos.historial_precio_costo(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_id text := nullif(btrim(coalesce(p->>'idProducto','')),'');
  v_prod record; v_canon record; v_factor numeric; v_grp text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select * into v_prod from mos.productos where id_producto = v_id limit 1;
  if v_prod.id_producto is null then return jsonb_build_object('ok',false,'error','PRODUCTO_NO_ENCONTRADO'); end if;

  -- canónico del grupo + factor del producto consultado (misma lógica que aplicar_costos_compra)
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
    -- PRECIO: historial del PRODUCTO propio (por id_producto, único)
    'precios', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
               'valor', h.valor, 'valorAnterior', h.valor_anterior,
               'usuario', h.usuario, 'source', h.source, 'appOrigen', h.app_origen) order by h.ts)
      from mos.historial_precio_costo h
      where h.tipo='PRECIO' and h.id_producto = v_prod.id_producto), '[]'::jsonb),
    -- COSTO: del CANÓNICO (grupo) escalado ×factor (cascada al hijo)
    'costos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
               'valor', round(h.valor * v_factor, 4), 'valorCanonico', h.valor,
               'usuario', h.usuario, 'idGuia', h.id_guia, 'source', h.source, 'meta', h.meta) order by h.ts)
      from mos.historial_precio_costo h
      where h.tipo='COSTO' and h.sku_base = v_grp), '[]'::jsonb)
  ));
end; $function$;

revoke all on function mos.historial_precio_costo(jsonb), mos.publicar_precio(jsonb), mos.aplicar_costos_compra(jsonb) from public;
grant execute on function mos.historial_precio_costo(jsonb) to anon, authenticated, service_role;
grant execute on function mos.publicar_precio(jsonb), mos.aplicar_costos_compra(jsonb) to authenticated, service_role;
notify pgrst, 'reload schema';
