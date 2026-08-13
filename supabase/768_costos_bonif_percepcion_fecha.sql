-- 768 · Paso 1 rediseñado — reglas del dueño (13-ago-2026):
--  (1) FECHA EFECTIVA del costo = fecha de la GUÍA (ya era así para WH [576]; ahora
--      también para compras EN ZONA, que viven en me.guias_cabecera). "El costo afecta
--      desde que entró la mercadería, lo haya registrado o no."
--  (2) meta.registradoEl = CUÁNDO se hizo el registro de verdad (y usuario ya viaja):
--      "con detalle de que recién hoy lo hice yo". Las barras de la Mesa (766) comparan
--      contra el REGISTRO, no contra la fecha efectiva — si no, un precio de hace 15
--      días contaría como puesto "después" de un costo cotejado hoy con fecha vieja.
--  (3) BONIFICACIÓN: mercadería regalada — la línea queda costeada (cuenta en la barra)
--      pero NO toca el costo del catálogo (decisión del dueño: lo regalado no cambia
--      el costo de reposición). Evento COSTO con valor = costo vigente y meta.bonificacion.
--  (4) PERCEPCIÓN / sin-IGV / modo: el front ya los resuelve en el costo final (percepción
--      SUMA al costo — decisión del dueño); acá solo quedan grabados en meta para auditoría.

-- ═══ (1)(2)(3)(4) aplicar_costos_compra ══════════════════════════════════════
CREATE OR REPLACE FUNCTION mos.aplicar_costos_compra(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_usr  text := coalesce(p->>'usuario','');
  v_guia_fecha timestamptz;
  it jsonb; v_cb text; v_costo numeric; v_bonif boolean; v_meta jsonb;
  v_prod record; v_canon record;
  v_factor numeric; v_costo_canon numeric; v_prev numeric;
  v_out jsonb := '[]'::jsonb;
  v_hist jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [724] GUARD DE ROL (doctrina: el costo lo pone MOS, donde viven admin y master).
  if not mos._rol_precio_ok(v_usr) then return jsonb_build_object('ok',false,'error','ROL_NO_AUTORIZADO'); end if;
  if jsonb_typeof(p->'items') <> 'array' then
    return jsonb_build_object('ok',false,'error','Requiere items[]');
  end if;

  -- [576] fecha de ORIGEN del costo = fecha de la GUÍA (no la de registro).
  -- [768] la guía puede vivir en WH (proveedor) o en ME (compra en zona). Fallback: now.
  if v_guia is not null then
    begin select g.fecha into v_guia_fecha from wh.guias g where g.id_guia = v_guia limit 1;
    exception when others then v_guia_fecha := null; end;
    if v_guia_fecha is null then
      begin select g.fecha into v_guia_fecha from me.guias_cabecera g where g.id_guia = v_guia limit 1;
      exception when others then v_guia_fecha := null; end;
    end if;
  end if;
  v_guia_fecha := coalesce(v_guia_fecha, now());

  for it in select * from jsonb_array_elements(p->'items') loop
    v_cb    := upper(btrim(coalesce(it->>'codProducto', it->>'codigoBarra','')));
    v_costo := mos._numn(it->>'costoUnitario');
    v_bonif := coalesce((it->>'bonificacion')::boolean, false);
    -- [768] bonificación entra con costo 0; lo demás exige costo > 0
    if v_cb = '' then continue; end if;
    if not v_bonif and (v_costo is null or v_costo <= 0) then continue; end if;

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
    v_prev := v_canon.precio_costo;

    -- [768] meta común: cuándo/cómo se registró de verdad + características de la entrada
    v_meta := jsonb_build_object(
      'compradoComo', v_prod.descripcion, 'factorAplicado', v_factor,
      'registradoEl', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))
      || case when v_bonif then jsonb_build_object('bonificacion', true) else '{}'::jsonb end
      || case when mos._numn(it->>'percepcionPct') > 0 then jsonb_build_object('percepcionPct', mos._numn(it->>'percepcionPct')) else '{}'::jsonb end
      || case when coalesce((it->>'sinIgv')::boolean,false) then jsonb_build_object('sinIgv', true) else '{}'::jsonb end
      || case when nullif(btrim(coalesce(it->>'modo','')),'') is not null then jsonb_build_object('modo', it->>'modo') else '{}'::jsonb end;

    if v_bonif then
      -- [768] BONIFICACIÓN: NO toca el costo del catálogo. Solo constancia en el
      -- historial (valor = costo vigente, para no craterizar las curvas de costo).
      begin
        insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, id_guia, ts, meta)
        values (v_canon.id_producto, coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
                'COSTO', coalesce(v_prev, 0), v_prev, v_usr, 'COMPRA', coalesce(v_guia,''), v_guia_fecha, v_meta);
      exception when others then null;
      end;
      v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', true, 'bonificacion', true,
        'idCanonico', v_canon.id_producto, 'descripcion', v_canon.descripcion, 'costoNuevo', v_prev);
      continue;
    end if;

    v_costo_canon := round(v_costo / nullif(v_factor,0), 4);

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

    -- [576] HISTORIAL de COSTO en tabla (fuente de la analítica). ts = fecha efectiva de la guía.
    begin
      insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, id_guia, ts, meta)
      values (v_canon.id_producto, coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
              'COSTO', v_costo_canon, v_prev, v_usr, 'COMPRA', coalesce(v_guia,''), v_guia_fecha, v_meta);
    exception when others then null;
    end;

    v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', true,
      'idCanonico', v_canon.id_producto, 'skuBase', coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
      'descripcion', v_canon.descripcion, 'costoAnterior', v_prev, 'costoNuevo', v_costo_canon);
  end loop;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v_out));
end; $function$;

-- ═══ (2) cotejo_costos_guias: comparar contra el REGISTRO, no la fecha efectiva ═══
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

  -- COSTO vivo por producto. [768] El "cuándo" del cotejo es meta.registradoEl (el acto
  -- real del admin); ts guarda la fecha EFECTIVA (guía) y puede ser semanas anterior.
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
                 max(coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts)) as cts,
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

-- ═══ (3) costos_registrados_guia: + flags para re-hidratar toggles ════════════
create or replace function mos.costos_registrados_guia(p jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
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
             mos._numn(h.meta->>'percepcionPct') as perc
        from mos.historial_precio_costo h
       where h.id_guia = v_guia
         and upper(btrim(coalesce(h.tipo,''))) = 'COSTO'
       order by coalesce(nullif(btrim(h.id_producto),''), h.sku_base),
                coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts) desc,
                h.id desc   -- desempate: dos registros en el mismo instante → gana el último
    ) z;

  return jsonb_build_object('ok', true, 'data', coalesce(v_out, '[]'::jsonb));
end;
$function$;
