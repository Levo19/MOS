-- 234_review_fixes_100x.sql — Fixes de la revisión 100x integral (2026-06-23).
-- #2 (ALTO): crear_pickup_desde_ventas usaba `coalesce(estado::text,'1')<>'0'` pero mos.productos.estado es
--    BOOLEAN → 'false'<>'0' siempre true → incluía productos INACTIVOS en el mapeo canónico. → `estado is not false`.
-- #7 (BAJO): login_pin_wh comparaba `pin=v_pin` sin trim del lado almacenado → lockout si el pin guardado tiene
--    espacios. → `btrim(pin)=v_pin`.

create or replace function wh.crear_pickup_desde_ventas(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idcaja text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_zona   text := coalesce(p->>'idZona','');
  v_cajero text := coalesce(p->>'cajero','');
  v_items  jsonb := case when jsonb_typeof(p->'items')='array' then p->'items' else '[]'::jsonb end;
  v_pk     text; v_built jsonb;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idcaja is null then return jsonb_build_object('ok',false,'error','idCaja requerido'); end if;
  v_pk := 'PK-VENTAS-' || v_idcaja;
  if exists (select 1 from wh.pickups where id_pickup = v_pk) then
    return jsonb_build_object('ok',true,'dedup',true,'data',jsonb_build_object('idPickup',v_pk));
  end if;

  with entrada as (
    select btrim(coalesce(e->>'codBarra', e->>'cod_barras','')) cod,
           coalesce(mos._numn(e->>'cantidad'),0) cant
    from jsonb_array_elements(v_items) e
  ),
  ent2 as (select cod, cant from entrada where cod <> '' and cant > 0),
  resuelto as (
    select en.cod, en.cant,
      coalesce(pr.sku_base, pi.sku_base, eq.sku_base, en.cod) as sku,
      coalesce(pr.factor_conversion, pi.factor_conversion, 1)::numeric as factor
    from ent2 en
    left join lateral (select sku_base, factor_conversion from mos.productos
        where codigo_barra = en.cod and estado is not false order by factor_conversion limit 1) pr on true
    left join lateral (select sku_base, factor_conversion from mos.productos
        where id_producto = en.cod limit 1) pi on true
    left join lateral (select sku_base from mos.equivalencias
        where codigo_barra = en.cod and coalesce(activo,true) limit 1) eq on true
  ),
  agrupado as (
    select sku, sum(cant * coalesce(factor,1)) as solicitado from resuelto group by sku
  ),
  items as (
    select coalesce(jsonb_agg(jsonb_build_object(
        'skuBase', a.sku,
        'nombre', coalesce(nullif(can.descripcion,''), a.sku),
        'solicitado', a.solicitado,
        'despachado', 0,
        'codigosOriginales', (
          select coalesce(jsonb_agg(distinct z.cod), '[]'::jsonb) from (
            select can.codigo_barra cod where coalesce(can.codigo_barra,'') <> ''
            union
            select codigo_barra from mos.equivalencias where sku_base = a.sku and coalesce(activo,true) and coalesce(codigo_barra,'') <> ''
          ) z
        )
      ) order by a.sku), '[]'::jsonb) as arr
    from agrupado a
    left join lateral (select codigo_barra, descripcion from mos.productos
        where sku_base = a.sku and factor_conversion = 1 and estado is not false
        order by length(coalesce(descripcion,'')) desc limit 1) can on true
    where a.solicitado > 0
  )
  select arr into v_built from items;

  if v_built is null or jsonb_array_length(v_built) = 0 then
    return jsonb_build_object('ok',true,'vacio',true,'data',jsonb_build_object('idPickup',v_pk,'items',0));
  end if;

  insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
  values (v_pk, 'ME_CIERRE_CAJA', 'PENDIENTE', v_built, v_zona, 'Auto cierre de caja · '||v_idcaja, v_cajero, now(), now())
  on conflict (id_pickup) do nothing;

  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup',v_pk,'items',jsonb_array_length(v_built)));
end;
$fn$;

-- #7: login_pin_wh — btrim del lado almacenado (evita lockout por pin con espacios)
create or replace function mos.login_pin_wh(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_pin text := nullif(btrim(coalesce(p->>'pin','')), '');
  v_op  mos.personal%rowtype;
  v_dia date := (now() at time zone 'America/Lima')::date;
  v_hora text := to_char(now() at time zone 'America/Lima', 'HH24:MI:SS');
  v_fini timestamptz := ((v_dia::text || ' 00:00:00')::timestamp at time zone 'America/Lima');
  v_ses wh.sesiones%rowtype; v_sid text;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_pin is null then return jsonb_build_object('ok',false,'error','PIN requerido'); end if;
  select * into v_op from mos.personal
    where btrim(coalesce(pin,'')) = v_pin and coalesce(estado,false) = true
    order by (lower(coalesce(app_origen,'')) like '%warehouse%') desc
    limit 1;
  if not found then return jsonb_build_object('ok',false,'error','PIN incorrecto'); end if;

  select * into v_ses from wh.sesiones
    where id_personal = v_op.id_personal::text and upper(coalesce(estado,'')) = 'ACTIVA'
      and (fecha_inicio at time zone 'America/Lima')::date = v_dia
    order by fecha_inicio desc limit 1;
  if found then
    return jsonb_build_object('ok',true,'data', jsonb_build_object(
      'idSesion', v_ses.id_sesion, 'idPersonal', v_op.id_personal, 'nombre', v_op.nombre,
      'apellido', v_op.apellido, 'rol', v_op.rol, 'color', v_op.color, 'foto', v_op.foto,
      'horaInicio', v_ses.hora_inicio, 'yaEnSesionHoy', true, 'bienvenidaImpresa', true));
  end if;

  v_sid := 'SES-' || to_char(now(),'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text || v_op.id_personal), 1, 6);
  insert into wh.sesiones (id_sesion, id_personal, fecha_inicio, hora_inicio, minutos_activos, estado)
  values (v_sid, v_op.id_personal::text, v_fini, v_hora, 0, 'ACTIVA');
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'idSesion', v_sid, 'idPersonal', v_op.id_personal, 'nombre', v_op.nombre, 'apellido', v_op.apellido,
    'rol', v_op.rol, 'color', v_op.color, 'foto', v_op.foto,
    'horaInicio', v_hora, 'yaEnSesionHoy', false, 'bienvenidaImpresa', false));
end;
$fn$;
