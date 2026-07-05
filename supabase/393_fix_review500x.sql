-- 393 · FIXES de la revisión adversarial 500x (bugs reales de la sesión).

-- ── FIX CRÍTICO (385): el update de precio_costo ocurría ANTES de publicar_precio. Si publicar_precio falla
--    (flag OFF/excepción), el costo quedaba cambiado pero la venta no → margen corrompido sin rollback.
--    Ahora: publicar venta PRIMERO; solo si ok, tocar el costo. ──
create or replace function mos.aplicar_respuesta_jefa(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_g     text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_clave text := coalesce(p->>'claveAdmin','');
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_verif jsonb; v_por text;
  v_it jsonb; v_sku text; v_vn numeric; v_mg numeric; v_cn numeric;
  v_costo numeric; v_venta numeric; v_res jsonb; rd jsonb;
  v_aplic int := 0; v_err jsonb := '[]'::jsonb; v_cambios jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(v_items) <> 'array' then return jsonb_build_object('ok',false,'error','items debe ser array'); end if;
  v_verif := mos.verificar_clave_admin(v_clave, 'APLICAR_RESPUESTA_JEFA', coalesce(v_g,''), 'MOS', '', 'Respuesta jefa');
  if not coalesce((v_verif->>'autorizado')::boolean,false) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error',coalesce(v_verif->>'error','Clave incorrecta')));
  end if;
  v_por := coalesce(nullif(btrim(coalesce(v_verif->>'nombre','')),''),'admin');

  for v_it in select * from jsonb_array_elements(v_items) loop
    v_sku := nullif(btrim(coalesce(v_it->>'skuBase','')),'');
    v_vn  := mos._numn(v_it->>'ventaNueva');
    v_mg  := mos._numn(v_it->>'margenNuevoPct');
    v_cn  := mos._numn(v_it->>'costoNuevo');
    if v_sku is null then continue; end if;
    if v_vn is null and v_mg is null then continue; end if;
    if v_cn is not null and v_cn > 0 then v_costo := v_cn;
    else select precio_costo into v_costo from mos.productos
          where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku
          order by (coalesce(factor_conversion,1)=1 and btrim(coalesce(codigo_producto_base,''))='') desc limit 1;
    end if;
    v_costo := coalesce(v_costo,0);
    if v_vn is not null and v_vn > 0 then v_venta := round(v_vn, 2);
    elsif v_mg is not null and v_mg > -0.5 and v_mg < 0.99 and v_costo > 0 then v_venta := round(v_costo / (1 - v_mg), 2);
    else
      v_err := v_err || jsonb_build_object('skuBase',v_sku,'error','datos insuficientes (venta/margen inválido o sin costo)');
      continue;
    end if;

    -- [FIX 393] aplicar la VENTA primero; solo si ok, tocar el COSTO (evita catálogo con costo nuevo + venta vieja).
    v_res := mos.publicar_precio(jsonb_build_object('skuBase', v_sku, 'precioNuevo', v_venta,
      'motivo', 'Respuesta jefa · guía '||coalesce(v_g,''), 'usuario', v_por));
    if coalesce((v_res->>'ok')::boolean,false) then
      if v_cn is not null and v_cn > 0 then
        update mos.productos set precio_costo = v_cn, updated_at = now()
         where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku
           and coalesce(factor_conversion,1) = 1 and btrim(coalesce(codigo_producto_base,'')) = '';
      end if;
      rd := coalesce(v_res->'data','{}'::jsonb);
      v_aplic := v_aplic + 1;
      v_cambios := v_cambios || jsonb_build_object('skuBase', v_sku, 'descripcion', rd->>'descripcion',
        'ventaAnterior', rd->>'precioAnterior', 'ventaNueva', v_venta, 'costo', v_costo,
        'presentaciones', coalesce((rd->>'presentacionesActualizadas')::int,0));
    else
      v_err := v_err || jsonb_build_object('skuBase',v_sku,'error',coalesce(v_res->>'error','publicar_precio falló'));
    end if;
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'autorizado', true, 'aplicados', v_aplic, 'errores', v_err, 'cambios', v_cambios,
    'autorizadoPor', v_por, 'ticketImpreso', false));
end; $fn$;

-- ── FIX ALTO (378): contar recomputadas por ÉXITO REAL (recomputar_dia devuelve OFF sin 'skipped' → antes
--    se contaba como recomputada = falso positivo). ──
create or replace function mos.backfill_liquidaciones_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_dias   int  := greatest(1, least(370, coalesce(mos._numn(p->>'dias'),30)::int));
  v_hoy    date := (now() at time zone 'America/Lima')::date;
  v_desde  date; rec record; v_reco int := 0; v_salt int := 0; v_res jsonb; v_off boolean := false;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  perform set_config('statement_timeout', '120s', true);
  v_desde := v_hoy - (v_dias - 1);
  for rec in
    select id_personal, (fecha at time zone 'America/Lima')::date as dia
      from mos.liquidaciones_dia
     where (fecha at time zone 'America/Lima')::date between v_desde and v_hoy
       and upper(coalesce(rol,'')) not in ('MASTER','ADMIN','ADMINISTRADOR')
  loop
    v_res := mos.recomputar_dia(jsonb_build_object('idPersonal', rec.id_personal, 'fecha', rec.dia::text));
    if coalesce((v_res->>'ok')::boolean,false) and coalesce(v_res->>'skipped','') = '' then
      v_reco := v_reco + 1;
    else
      v_salt := v_salt + 1;
      if coalesce(v_res->>'error','') = 'MOS_ACCESOS_DIRECTO_OFF' then v_off := true; end if;
    end if;
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'recomputadas', v_reco, 'saltadas', v_salt, 'dias', v_dias, 'desde', v_desde, 'hasta', v_hoy,
    'motorApagado', v_off));
end; $fn$;

-- ── FIX ALTO (390): índice único (id_proveedor, sku_base) + upsert atómico (antes UPDATE-then-INSERT = dup bajo concurrencia). ──
create unique index if not exists ux_mos_provprod_prov_sku
  on mos.proveedores_productos (id_proveedor, sku_base)
  where sku_base is not null and btrim(sku_base) <> '';

create or replace function mos.jalar_productos_proveedor(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_prov text := nullif(btrim(coalesce(p->>'idProveedor','')),'');
  v_creados int := 0; v_act int := 0; v_omit int := 0; v_guias int := 0;
  rec record; v_sku text; v_desc text; v_ins boolean;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_prov is null then return jsonb_build_object('ok',false,'error','idProveedor requerido'); end if;
  select count(distinct id_guia) into v_guias from wh.guias
   where id_proveedor = v_prov and upper(coalesce(tipo,'')) like 'INGRESO%';
  for rec in
    with d as (
      select btrim(dd.cod_producto) cod, dd.precio_unitario pu,
             row_number() over (partition by btrim(dd.cod_producto) order by gg.fecha desc nulls last) rn
        from wh.guia_detalle dd join wh.guias gg on gg.id_guia = dd.id_guia
       where gg.id_proveedor = v_prov and upper(coalesce(gg.tipo,'')) like 'INGRESO%'
         and upper(coalesce(dd.observacion,'')) <> 'ANULADO' and btrim(coalesce(dd.cod_producto,'')) <> '')
    select cod, pu from d where rn = 1
  loop
    v_sku := null;
    select coalesce(nullif(btrim(sku_base),''), id_producto), descripcion into v_sku, v_desc
      from mos.productos where codigo_barra = rec.cod limit 1;
    if v_sku is null then v_omit := v_omit + 1; continue; end if;
    insert into mos.proveedores_productos (id_pp, id_proveedor, sku_base, codigo_barra, descripcion,
        precio_referencia, activa, ultima_actualizacion)
    values ('PP'||(extract(epoch from clock_timestamp())*1000)::bigint::text||'_'||left(v_sku,20),
        v_prov, v_sku, rec.cod, coalesce(v_desc,''), rec.pu, true, now())
    on conflict (id_proveedor, sku_base) where (sku_base is not null and btrim(sku_base) <> '')
      do update set precio_referencia = excluded.precio_referencia,
                    descripcion = coalesce(nullif(excluded.descripcion,''), mos.proveedores_productos.descripcion),
                    codigo_barra = excluded.codigo_barra, ultima_actualizacion = now()
    returning (xmax = 0) into v_ins;   -- xmax=0 ⇒ fue INSERT
    if v_ins then v_creados := v_creados + 1; else v_act := v_act + 1; end if;
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'creados',v_creados,'actualizados',v_act,'omitidos',v_omit,'total',v_creados+v_act,'totalGuias',v_guias));
end; $fn$;

-- ── FIX MEDIO (386): cron_status.ultima_corrida debe ser el OBJETO (el front lee ultima.wh_cerradas/duracion_ms/...),
--    antes era el string ts_inicio → contadores en 0. ──
create or replace function mos.cron_status(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_job record; v_total int; v_ult jsonb; v_last jsonb; v_ahora text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_ahora := to_char(now() at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI:SS');
  select j.schedule, j.active into v_job
    from cron.job j where j.jobname ilike '%cierre%noct%' or j.jobname ilike '%nocturn%' limit 1;
  select count(*) into v_total from mos.cron_log where job ilike '%cierre%' or job ilike '%noct%';
  select coalesce(jsonb_agg(row order by ts desc), '[]'::jsonb) into v_ult from (
    select jsonb_build_object(
      'ts_inicio', to_char(ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
      'ts_fin', coalesce(resultado->>'ts_fin', to_char(ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS')),
      'duracion_ms', coalesce((resultado->>'duracion_ms')::int, 0),
      'wh_cerradas', coalesce((resultado->>'wh_cerradas')::int, 0),
      'wh_omitidas', coalesce((resultado->>'wh_omitidas')::int, 0),
      'wh_errores', coalesce((resultado->>'wh_errores')::int, 0),
      'me_cerradas', coalesce((resultado->>'me_cerradas')::int, 0),
      'me_errores', coalesce((resultado->>'me_errores')::int, 0),
      'dev_marcados', coalesce((resultado->>'dev_marcados')::int, 0),
      'dev_omitidos', coalesce((resultado->>'dev_omitidos')::int, 0),
      'dev_errores', coalesce((resultado->>'dev_errores')::int, 0),
      'ok', coalesce(ok, false),
      'detalles_json', coalesce(resultado::text, '{}')) as row, ts
    from mos.cron_log where job ilike '%cierre%' or job ilike '%noct%' order by ts desc limit 5
  ) q;
  v_last := v_ult->0;   -- objeto (o null)
  return jsonb_build_object('ok',true,'data', jsonb_build_object('cierreNocturno', jsonb_build_object(
    'trigger_instalado', (v_job.schedule is not null),
    'hora_programada', coalesce(v_job.schedule, 'pg_cron'),
    'tz_script', 'America/Lima', 'ahora_script', v_ahora,
    'total_corridas', coalesce(v_total,0),
    'ultima_corrida', v_last,   -- [FIX 393] objeto completo, no string
    'ultimas_5', v_ult)));
end; $fn$;
