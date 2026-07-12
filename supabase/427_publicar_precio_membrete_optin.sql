-- 427 · [catálogo v4 · fix revisión contratos] mos.publicar_precio: el hook de alerta
-- membrete-ME (339b) insertaba INCONDICIONALMENTE en cada cambio real de precio — el
-- toggle "🖨 Imprimir membretes de los que cambien" del modal cascada era un no-op.
-- Cambio ÚNICO: el insert ahora respeta p->>'imprimirMembretes' con DEFAULT TRUE
-- (los callers que no mandan el campo — precios sugeridos, respuesta jefa, costos guía —
-- conservan su comportamiento de siempre). Resto de la función IDÉNTICO a 339b/339c.
create or replace function mos.publicar_precio(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_pn   numeric := mos._numn(p->>'precioNuevo');
  v_id   text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_cod  text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  -- [427] opt-out de la alerta membrete (default TRUE = paridad con callers viejos)
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

  -- return IDÉNTICO a 339c (superset estricto — nada se pierde)
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
