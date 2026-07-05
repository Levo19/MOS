-- 390 · kill-GAS MOS bloque 4: jalarProductosProveedor + probarNotificacion + setupAdhesivosBase(iconos).

-- ── jalar productos del proveedor: upsert proveedores_productos desde guías INGRESO del proveedor ──
create or replace function mos.jalar_productos_proveedor(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_prov text := nullif(btrim(coalesce(p->>'idProveedor','')),'');
  v_creados int := 0; v_act int := 0; v_omit int := 0; v_guias int := 0;
  rec record; v_sku text; v_desc text;
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
    if v_sku is null then v_omit := v_omit + 1; continue; end if;   -- paridad "no en master"
    update mos.proveedores_productos
       set precio_referencia = rec.pu, descripcion = coalesce(nullif(v_desc,''), descripcion), ultima_actualizacion = now()
     where id_proveedor = v_prov and sku_base = v_sku;
    if found then v_act := v_act + 1;
    else
      insert into mos.proveedores_productos (id_pp, id_proveedor, sku_base, codigo_barra, descripcion,
        precio_referencia, activa, ultima_actualizacion)
      values ('PP'||(extract(epoch from clock_timestamp())*1000)::bigint::text||'_'||left(v_sku,20),
        v_prov, v_sku, rec.cod, coalesce(v_desc,''), rec.pu, true, now());
      v_creados := v_creados + 1;
    end if;
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'creados',v_creados,'actualizados',v_act,'omitidos',v_omit,'total',v_creados+v_act,'totalGuias',v_guias));
end; $fn$;

-- ── probar notificación: arma título/cuerpo desde la config + emite push (soloAMi = solo al que prueba) ──
create or replace function mos.probar_notificacion(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idNotif','')),'');
  v_solo boolean := coalesce(nullif(btrim(coalesce(p->>'soloAMi','')),'')::boolean, false);
  v_usr text := nullif(btrim(coalesce(p->>'miUsuario','')),'');
  c record; v_aud jsonb; v_tit text; v_cue text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idNotif requerido'); end if;
  select icono, titulo, descripcion, audiencia_roles, audiencia_usuarios
    into c from mos.notificaciones_config where id_notif = v_id;
  if not found then return jsonb_build_object('ok',false,'error','notif no encontrada'); end if;
  v_tit := btrim(coalesce(c.icono,'') || ' ' || coalesce(c.titulo,'')) || ' (PRUEBA)';
  v_cue := 'Notificación de prueba · ' || coalesce(c.descripcion,'');
  if v_solo and v_usr is not null then
    v_aud := jsonb_build_object('usuarios', jsonb_build_array(v_usr));
  else
    v_aud := jsonb_build_object(
      'roles', (select coalesce(jsonb_agg(upper(btrim(x))),'[]'::jsonb) from regexp_split_to_table(coalesce(c.audiencia_roles,''),',') x where btrim(x)<>''),
      'usuarios', (select coalesce(jsonb_agg(btrim(x)),'[]'::jsonb) from regexp_split_to_table(coalesce(c.audiencia_usuarios,''),',') x where btrim(x)<>''));
  end if;
  perform mos.emitir_push(jsonb_build_object('audiencia', v_aud, 'titulo', v_tit, 'cuerpo', v_cue,
    'data', jsonb_build_object('tipo','notif_prueba','idNotif', v_id)));
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idNotif', v_id, 'enviada', true));
end; $fn$;

-- ── setupAdhesivosBase: upsert del hex de iconos (el bitmap lo genera el cliente determinísticamente) ──
create or replace function mos.adhesivo_iconos_upsert(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_tam int := coalesce(nullif(btrim(coalesce(p->>'tamano', p->>'tamano_dots','')),'')::int, 0); v_it record; v_n int := 0;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  for v_it in select key, value from jsonb_each_text(coalesce(p->'iconos','{}'::jsonb)) loop
    if nullif(btrim(v_it.value),'') is null then continue; end if;
    insert into mos.adhesivo_iconos (id_icono, tamano_dots, hex) values (v_it.key, v_tam, v_it.value)
    on conflict (id_icono, tamano_dots) do update set hex = excluded.hex;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('iconos', v_n));
end; $fn$;

revoke all on function mos.jalar_productos_proveedor(jsonb), mos.probar_notificacion(jsonb), mos.adhesivo_iconos_upsert(jsonb) from public, anon;
grant execute on function mos.jalar_productos_proveedor(jsonb), mos.probar_notificacion(jsonb), mos.adhesivo_iconos_upsert(jsonb) to authenticated, service_role;
