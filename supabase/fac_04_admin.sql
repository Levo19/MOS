-- ════════════════════════════════════════════════════════════════════════════
-- fac_04_admin.sql · Config (tokens), numeración, series, historial
-- ════════════════════════════════════════════════════════════════════════════
-- Gate: app_ok (el admin se valida en el front con verificar_clave_admin). NO requieren
-- el flag _on() porque config/numeración se preparan ANTES de prender la emisión real.

-- ── Guardar config NubeFact (parche parcial: '' NO borra el valor existente) ──
create or replace function fac.admin_set_config(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not fac._app_ok() then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not fac._admin_ok(p->>'clave_admin','FAC_CONFIG','') then return jsonb_build_object('status','error','error','CLAVE_ADMIN_INVALIDA'); end if;
  update fac.config set
    nubefact_ruta  = coalesce(nullif(p->>'nubefact_ruta','' ), nubefact_ruta),
    nubefact_token = coalesce(nullif(p->>'nubefact_token',''), nubefact_token),
    auth_header    = coalesce(nullif(p->>'auth_header','' ), auth_header),
    lookup_url_dni = coalesce(p->>'lookup_url_dni', lookup_url_dni),
    lookup_url_ruc = coalesce(p->>'lookup_url_ruc', lookup_url_ruc),
    lookup_token   = coalesce(nullif(p->>'lookup_token',''), lookup_token),
    modo           = coalesce(nullif(p->>'modo','' ), modo),
    activo         = coalesce((p->>'activo')::boolean, activo),
    actualizado_at = now()
  where id = 1;
  return jsonb_build_object('status','success');
end;
$fn$;
-- Nota: mandar un token '' (o no mandarlo) CONSERVA el existente; mandar un valor real lo reemplaza.

-- ── Leer config SIN exponer tokens (solo flags + numeración) ──
create or replace function fac.get_config(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_cfg fac.config%rowtype; v_series jsonb;
begin
  if not fac._app_ok() then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  select * into v_cfg from fac.config where id = 1;
  select coalesce(jsonb_object_agg(serie, jsonb_build_object('tipo',tipo,'correlativo',correlativo,'proximo',correlativo+1,'activa',activa)), '{}'::jsonb)
    into v_series from fac.series;
  return jsonb_build_object('status','success',
    'tiene_nubefact', coalesce(v_cfg.nubefact_ruta,'')<>'' and coalesce(v_cfg.nubefact_token,'')<>'',
    'tiene_lookup',   coalesce(v_cfg.lookup_token,'')<>'' and (coalesce(v_cfg.lookup_url_dni,'')<>'' or coalesce(v_cfg.lookup_url_ruc,'')<>''),
    'auth_header',    v_cfg.auth_header,  -- plantilla (no incluye el token)
    'ruta_set',       coalesce(v_cfg.nubefact_ruta,'')<>'',
    'modo',           v_cfg.modo, 'activo', v_cfg.activo,
    'serie_boleta',   v_cfg.serie_boleta, 'serie_factura', v_cfg.serie_factura,
    'flag_on',        fac._on(),
    'series',         v_series);
end;
$fn$;

-- ── Alinear correlativo de una serie (migración: poner el último nº ya emitido) ──
create or replace function fac.admin_alinear_correlativo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_serie text := nullif(btrim(coalesce(p->>'serie','')),''); v_num bigint := coalesce((p->>'numero')::bigint, -1);
begin
  if not fac._app_ok() then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not fac._admin_ok(p->>'clave_admin','FAC_ALINEAR', v_serie) then return jsonb_build_object('status','error','error','CLAVE_ADMIN_INVALIDA'); end if;
  if v_serie is null then return jsonb_build_object('status','error','error','SERIE_REQUERIDA'); end if;
  if v_num < 0 then return jsonb_build_object('status','error','error','NUMERO_INVALIDO'); end if;
  update fac.series set correlativo = v_num where serie = v_serie;
  if not found then return jsonb_build_object('status','error','error','SERIE_NO_EXISTE'); end if;
  return jsonb_build_object('status','success','serie',v_serie,'correlativo',v_num,'proximo',v_num+1);
end;
$fn$;

-- ── Fijar series activas (valida B+3 / F+3, crea si faltan) ──
create or replace function fac.admin_set_series(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_b text := upper(btrim(coalesce(p->>'boleta',''))); v_f text := upper(btrim(coalesce(p->>'factura','')));
begin
  if not fac._app_ok() then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not fac._admin_ok(p->>'clave_admin','FAC_SERIES','') then return jsonb_build_object('status','error','error','CLAVE_ADMIN_INVALIDA'); end if;
  if v_b !~ '^B[0-9A-Z]{3}$' then return jsonb_build_object('status','error','error','SERIE_BOLETA_INVALIDA'); end if;
  if v_f !~ '^F[0-9A-Z]{3}$' then return jsonb_build_object('status','error','error','SERIE_FACTURA_INVALIDA'); end if;
  insert into fac.series(serie,tipo,correlativo) values (v_b,2,0) on conflict (serie) do nothing;
  insert into fac.series(serie,tipo,correlativo) values (v_f,1,0) on conflict (serie) do nothing;
  update fac.config set serie_boleta=v_b, serie_factura=v_f, actualizado_at=now() where id=1;
  return jsonb_build_object('status','success','serie_boleta',v_b,'serie_factura',v_f);
end;
$fn$;

-- ── Historial de comprobantes (por rango, tz Lima) ──
create or replace function fac.listar_comprobantes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_desde date := coalesce((p->>'desde')::date, (now() at time zone 'America/Lima')::date - 30);
        v_hasta date := coalesce((p->>'hasta')::date, (now() at time zone 'America/Lima')::date);
        v_out jsonb;
begin
  if not fac._app_ok() then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'tipo',tipo,'serie',serie,'numero',numero,'correlativo',serie||'-'||lpad(numero::text,6,'0'),
    'cliente_doc',cliente_doc,'cliente_nombre',cliente_nombre,'total',total,'estado',estado,
    'pdf',nf_enlace_pdf,'qr',nf_qr,'hash',nf_hash,'app',app,'origen',origen,
    'creado_at',creado_at,'creado_por',creado_por) order by creado_at desc), '[]'::jsonb)
   into v_out from fac.comprobantes
   where (creado_at at time zone 'America/Lima')::date between v_desde and v_hasta;
  return jsonb_build_object('status','success','comprobantes',v_out);
end;
$fn$;

revoke all on function fac.admin_set_config(jsonb) from public;
revoke all on function fac.get_config(jsonb) from public;
revoke all on function fac.admin_alinear_correlativo(jsonb) from public;
revoke all on function fac.admin_set_series(jsonb) from public;
revoke all on function fac.listar_comprobantes(jsonb) from public;
grant execute on function fac.admin_set_config(jsonb)        to authenticated;
grant execute on function fac.get_config(jsonb)              to authenticated;
grant execute on function fac.admin_alinear_correlativo(jsonb) to authenticated;
grant execute on function fac.admin_set_series(jsonb)        to authenticated;
grant execute on function fac.listar_comprobantes(jsonb)     to authenticated;
