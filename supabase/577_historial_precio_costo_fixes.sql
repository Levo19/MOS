-- 577 · [Analítica precios · Fase 1 · fixes de la revisión 50x] Correcciones cosméticas.
-- (1) READ devuelve `motivo` en precios[] (estaba en meta pero no se surface → tooltip vacío).
-- (2) Migración: las filas COSTO migradas sin guía-fecha se castearon naive bajo sesión UTC (-5h →
--     fecha del punto podía correr un día). Re-migración tz-aware (borra migrado + re-inserta).
-- (3) publicar_precio: no loguear PRECIO si no hay id_producto real (evita fila huérfana id='').
-- (4) Grant: revocar anon en la READ (paridad con 431; sigue authenticated/service_role + _claim_ok).

-- ── (1)+(3): READ con motivo + publicar_precio con guardia de id ──────────────────
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

  -- [576/577] HISTORIAL de PRECIO. Best-effort + SOLO si hay id_producto real (no fila huérfana).
  begin
    if (v_pa is distinct from v_pn) and coalesce(v_pid, v_id, '') <> '' then
      insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, app_origen, ts, meta)
      values (coalesce(v_pid, v_id), coalesce(v_psku, v_sku, ''), 'PRECIO', v_pn, v_pa,
              coalesce(p->>'usuario',''), coalesce(nullif(btrim(p->>'source'),''),'CATALOGO'),
              coalesce(nullif(btrim(p->>'appOrigen'),''),'MOS'), now(),
              jsonb_build_object('descripcion', coalesce(v_pdesc,''), 'motivo', coalesce(p->>'motivo','')));
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

-- ── READ: + motivo en precios[] ───────────────────────────────────────────────────
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
    'precioActual', v_prod.precio_venta,
    'costoActual',  round(coalesce(v_canon.precio_costo,0) * v_factor, 4),
    'factor', v_factor,
    'esCanonico', (v_canon.id_producto = v_prod.id_producto),
    'precios', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
               'valor', h.valor, 'valorAnterior', h.valor_anterior,
               'usuario', h.usuario, 'source', h.source, 'appOrigen', h.app_origen,
               'motivo', coalesce(h.meta->>'motivo','')) order by h.ts)
      from mos.historial_precio_costo h
      where h.tipo='PRECIO' and h.id_producto = v_prod.id_producto), '[]'::jsonb),
    'costos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
               'valor', round(h.valor * v_factor, 4), 'valorCanonico', h.valor,
               'usuario', h.usuario, 'idGuia', h.id_guia, 'source', h.source, 'meta', h.meta) order by h.ts)
      from mos.historial_precio_costo h
      where h.tipo='COSTO' and h.sku_base = v_grp), '[]'::jsonb)
  ));
end; $function$;

-- ── (2): re-migración tz-aware de los COSTO migrados (borra + re-inserta correcto) ──
delete from mos.historial_precio_costo where tipo='COSTO' and coalesce(meta->>'migrado','')='true';
insert into mos.historial_precio_costo (id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, id_guia, ts, meta)
select pr.id_producto,
       coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto),
       'COSTO',
       mos._numn(e->>'precioCosto'),
       mos._numn(e->>'costoAnterior'),
       e->>'usuario',
       'COMPRA',
       e->>'idGuia',
       coalesce(g.fecha, (nullif(e->>'ts','')::timestamp) at time zone 'America/Lima', now()),  -- tz-aware
       jsonb_build_object('compradoComo', e->>'compradoComo', 'factorAplicado', mos._numn(e->>'factorAplicado'), 'migrado', true)
from mos.productos pr
cross join lateral jsonb_array_elements(coalesce(pr.historial_cambios,'[]'::jsonb)) e
left join wh.guias g on g.id_guia = nullif(e->>'idGuia','')
where e->>'accion' = 'COSTO' and mos._numn(e->>'precioCosto') is not null;

-- ── (4): revocar anon en la READ (paridad 431) ────────────────────────────────────
revoke execute on function mos.historial_precio_costo(jsonb) from anon;
notify pgrst, 'reload schema';
