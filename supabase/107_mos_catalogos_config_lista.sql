-- 107_mos_catalogos_config_lista.sql — [Optimización MOS · lecturas directas personal/zonas/estaciones/impresoras/series]
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- RPCs de lectura directa, shape camelCase paritario con _CAT_SPECS. Gate _claim_ok + frescura. Bools '1'/'0'.
-- ⚠️ REVISIÓN 40x (2026-06-16) — CORRECCIONES vs versión inicial:
--   🔴 SEGURIDAD: getEstaciones (Config.gs:141) BORRA adminPin salvo params.incluirPin → estaciones_lista
--      ahora hace LO MISMO (omite adminPin por defecto; solo si p.incluirPin=true). NO filtrar el PIN admin.
--   🟠 FILTROS: los getters filtran (getEstaciones idZona/appOrigen/activo; getImpresoras +idEstacion/tipo;
--      getSeries idEstacion/idZona/tipoDocumento/activo; getZonas soloActivas) → replicados para paridad.
--   personal_master: getPersonalMaster NO expone pin_hash (no está en _CAT_SPECS) → ya correcto. pin sí (lo usa el front).

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

-- zonas_lista → getZonas (filtro soloActivas)
create or replace function mos.zonas_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_solo boolean := coalesce((p->>'soloActivas')::boolean, false); v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idZona', coalesce(z.id_zona,''), 'nombre', coalesce(z.nombre,''), 'descripcion', coalesce(z.descripcion,''),
    'direccion', coalesce(z.direccion,''), 'responsable', coalesce(z.responsable,''),
    'estado', case when coalesce(z.estado,false) then '1' else '0' end,
    'politicaJSON', coalesce(z.politica_json::text,'')
  ) order by z.nombre), '[]'::jsonb) into v_arr
  from mos.zonas z
  where (not v_solo or coalesce(z.estado,false) = true);
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.zonas_lista(jsonb) from public;
grant execute on function mos.zonas_lista(jsonb) to anon, authenticated, service_role;

-- estaciones_lista → getEstaciones (filtros idZona/appOrigen/activo). ⚠️ adminPin SOLO si p.incluirPin=true.
create or replace function mos.estaciones_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_zona text := nullif(btrim(coalesce(p->>'idZona','')), '');
  v_app  text := nullif(btrim(coalesce(p->>'appOrigen','')), '');
  v_act  text := nullif(btrim(coalesce(p->>'activo','')), '');
  v_pin  boolean := coalesce((p->>'incluirPin')::boolean, false);
  v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(obj order by nom), '[]'::jsonb) into v_arr from (
    select coalesce(e.nombre,'') as nom,
      (jsonb_build_object(
        'idEstacion', coalesce(e.id_estacion,''), 'idZona', coalesce(e.id_zona,''), 'nombre', coalesce(e.nombre,''),
        'tipo', coalesce(e.tipo,''), 'appOrigen', coalesce(e.app_origen,''),
        'activo', case when coalesce(e.activo,false) then '1' else '0' end, 'descripcion', coalesce(e.descripcion,'')
      ) || case when v_pin then jsonb_build_object('adminPin', coalesce(e.admin_pin,'')) else '{}'::jsonb end) as obj
    from mos.estaciones e
    where (v_zona is null or e.id_zona = v_zona)
      and (v_app  is null or e.app_origen = v_app)
      and (v_act  is null or (case when coalesce(e.activo,false) then '1' else '0' end) = v_act)
  ) s;
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.estaciones_lista(jsonb) from public;
grant execute on function mos.estaciones_lista(jsonb) to anon, authenticated, service_role;

-- impresoras_lista → getImpresoras (filtros appOrigen/idEstacion/idZona/tipo/activo)
create or replace function mos.impresoras_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_app text := nullif(btrim(coalesce(p->>'appOrigen','')), '');
  v_est text := nullif(btrim(coalesce(p->>'idEstacion','')), '');
  v_zon text := nullif(btrim(coalesce(p->>'idZona','')), '');
  v_tip text := nullif(btrim(coalesce(p->>'tipo','')), '');
  v_act text := nullif(btrim(coalesce(p->>'activo','')), '');
  v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idImpresora', coalesce(i.id_impresora,''), 'nombre', coalesce(i.nombre,''), 'printNodeId', coalesce(i.printnode_id,''),
    'tipo', coalesce(i.tipo,''), 'idEstacion', coalesce(i.id_estacion,''), 'idZona', coalesce(i.id_zona,''),
    'appOrigen', coalesce(i.app_origen,''), 'activo', case when coalesce(i.activo,false) then '1' else '0' end,
    'descripcion', coalesce(i.descripcion,'')
  ) order by i.nombre), '[]'::jsonb) into v_arr
  from mos.impresoras i
  where (v_app is null or i.app_origen = v_app)
    and (v_est is null or i.id_estacion = v_est)
    and (v_zon is null or i.id_zona = v_zon)
    and (v_tip is null or i.tipo = v_tip)
    and (v_act is null or (case when coalesce(i.activo,false) then '1' else '0' end) = v_act);
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.impresoras_lista(jsonb) from public;
grant execute on function mos.impresoras_lista(jsonb) to anon, authenticated, service_role;

-- series_lista → getSeries (filtros idEstacion/idZona/tipoDocumento/activo)
create or replace function mos.series_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_est text := nullif(btrim(coalesce(p->>'idEstacion','')), '');
  v_zon text := nullif(btrim(coalesce(p->>'idZona','')), '');
  v_doc text := nullif(btrim(coalesce(p->>'tipoDocumento','')), '');
  v_act text := nullif(btrim(coalesce(p->>'activo','')), '');
  v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idSerie', coalesce(s.id_serie,''), 'idEstacion', coalesce(s.id_estacion,''), 'idZona', coalesce(s.id_zona,''),
    'tipoDocumento', coalesce(s.tipo_documento,''), 'serie', coalesce(s.serie,''),
    'correlativo', coalesce(s.correlativo,0)::int, 'activo', case when coalesce(s.activo,false) then '1' else '0' end
  ) order by s.serie), '[]'::jsonb) into v_arr
  from mos.series_documentales s
  where (v_est is null or s.id_estacion = v_est)
    and (v_zon is null or s.id_zona = v_zon)
    and (v_doc is null or s.tipo_documento = v_doc)
    and (v_act is null or (case when coalesce(s.activo,false) then '1' else '0' end) = v_act);
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.series_lista(jsonb) from public;
grant execute on function mos.series_lista(jsonb) to anon, authenticated, service_role;
