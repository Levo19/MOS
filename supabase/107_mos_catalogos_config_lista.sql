-- 107_mos_catalogos_config_lista.sql — [Optimización MOS · lecturas directas personal/zonas/estaciones/impresoras/series]
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- RPCs de lectura directa para los catálogos/config restantes. Shape camelCase paritario con el mapeo
-- canónico _CAT_SPECS (MigracionCatalogo.gs). Gate _claim_ok + frescura. Bools como '1'/'0' (el front
-- compara con String(...); boolean rompería filtros/orden). Fechas ISO. pin/adminPin se incluyen (el front
-- los usa; RLS claim=MOS protege) pero pin_hash NO se expone (no está en _CAT_SPECS, no lo usa el front).

-- personal_master_lista → getPersonalMaster (filtros tipo/appOrigen/estado). NO incluye pin_hash.
create or replace function mos.personal_master_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_tipo text := nullif(btrim(coalesce(p->>'tipo','')), '');
  v_app  text := nullif(btrim(coalesce(p->>'appOrigen','')), '');
  v_est  text := nullif(btrim(coalesce(p->>'estado','')), '');
  v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idPersonal', coalesce(x.id_personal,''), 'nombre', coalesce(x.nombre,''), 'apellido', coalesce(x.apellido,''),
    'tipo', coalesce(x.tipo,''), 'appOrigen', coalesce(x.app_origen,''), 'rol', coalesce(x.rol,''),
    'pin', coalesce(x.pin,''), 'color', coalesce(x.color,''), 'tarifaHora', coalesce(x.tarifa_hora,0),
    'montoBase', coalesce(x.monto_base,0), 'estado', case when coalesce(x.estado,false) then '1' else '0' end,
    'fechaIngreso', mos._iso_z(x.fecha_ingreso::timestamptz), 'foto', coalesce(x.foto,''),
    'Ultima_Conexion', mos._iso_z(x.ultima_conexion)
  ) order by x.nombre, x.apellido), '[]'::jsonb) into v_arr
  from mos.personal x
  where (v_tipo is null or x.tipo = v_tipo)
    and (v_app  is null or x.app_origen = v_app)
    and (v_est  is null or (case when coalesce(x.estado,false) then '1' else '0' end) = v_est);
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.personal_master_lista(jsonb) from public;
grant execute on function mos.personal_master_lista(jsonb) to anon, authenticated, service_role;

-- zonas_lista → getZonas
create or replace function mos.zonas_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idZona', coalesce(z.id_zona,''), 'nombre', coalesce(z.nombre,''), 'descripcion', coalesce(z.descripcion,''),
    'direccion', coalesce(z.direccion,''), 'responsable', coalesce(z.responsable,''),
    'estado', case when coalesce(z.estado,false) then '1' else '0' end,
    'politicaJSON', coalesce(z.politica_json::text,'')
  ) order by z.nombre), '[]'::jsonb) into v_arr from mos.zonas z;
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.zonas_lista(jsonb) from public;
grant execute on function mos.zonas_lista(jsonb) to anon, authenticated, service_role;

-- estaciones_lista → getEstaciones (adminPin incluido, RLS protege)
create or replace function mos.estaciones_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idEstacion', coalesce(e.id_estacion,''), 'idZona', coalesce(e.id_zona,''), 'nombre', coalesce(e.nombre,''),
    'tipo', coalesce(e.tipo,''), 'appOrigen', coalesce(e.app_origen,''), 'adminPin', coalesce(e.admin_pin,''),
    'activo', case when coalesce(e.activo,false) then '1' else '0' end, 'descripcion', coalesce(e.descripcion,'')
  ) order by e.nombre), '[]'::jsonb) into v_arr from mos.estaciones e;
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.estaciones_lista(jsonb) from public;
grant execute on function mos.estaciones_lista(jsonb) to anon, authenticated, service_role;

-- impresoras_lista → getImpresoras
create or replace function mos.impresoras_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idImpresora', coalesce(i.id_impresora,''), 'nombre', coalesce(i.nombre,''), 'printNodeId', coalesce(i.printnode_id,''),
    'tipo', coalesce(i.tipo,''), 'idEstacion', coalesce(i.id_estacion,''), 'idZona', coalesce(i.id_zona,''),
    'appOrigen', coalesce(i.app_origen,''), 'activo', case when coalesce(i.activo,false) then '1' else '0' end,
    'descripcion', coalesce(i.descripcion,'')
  ) order by i.nombre), '[]'::jsonb) into v_arr from mos.impresoras i;
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.impresoras_lista(jsonb) from public;
grant execute on function mos.impresoras_lista(jsonb) to anon, authenticated, service_role;

-- series_lista → getSeries
create or replace function mos.series_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idSerie', coalesce(s.id_serie,''), 'idEstacion', coalesce(s.id_estacion,''), 'idZona', coalesce(s.id_zona,''),
    'tipoDocumento', coalesce(s.tipo_documento,''), 'serie', coalesce(s.serie,''),
    'correlativo', coalesce(s.correlativo,0)::int, 'activo', case when coalesce(s.activo,false) then '1' else '0' end
  ) order by s.serie), '[]'::jsonb) into v_arr from mos.series_documentales s;
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.series_lista(jsonb) from public;
grant execute on function mos.series_lista(jsonb) to anon, authenticated, service_role;
