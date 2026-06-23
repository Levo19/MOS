-- ════════════════════════════════════════════════════════════════════════════
-- fac_03_anular_reconciliar.sql · Baja (anulación) + reconciliación + lookup doc
-- ════════════════════════════════════════════════════════════════════════════

-- ── Verificación de clave admin SERVER-SIDE (no confiar solo en el front) ──
create or replace function fac._admin_ok(p_clave text, p_accion text, p_ref text)
returns boolean language plpgsql security definer set search_path = '' as $fn$
declare v jsonb;
begin
  if coalesce(p_clave,'') = '' then return false; end if;
  v := mos.verificar_clave_admin(p_clave, p_accion, coalesce(p_ref,''), fac._app(), '', '', null, null);
  return coalesce((v->>'ok')::boolean, false);
end;
$fn$;
revoke all on function fac._admin_ok(text, text, text) from public;

-- ── ANULAR (comunicación de baja a SUNAT vía NubeFact: generar_anulacion) ──
-- Gate: app_ok + flag ON + CLAVE ADMIN server-side (operación destructiva e irreversible).
-- STUB → marca BAJA local. REAL+EMITIDO → http a NubeFact.
create or replace function fac.anular_comprobante(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'id','')), '');
  v_local text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_mot   text := left(coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'Anulación'), 250);
  v_cmp   fac.comprobantes%rowtype;
  v_cfg   fac.config%rowtype;
  v_real  boolean; v_resp text; v_j jsonb;
begin
  if not fac._app_ok() then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not fac._on()     then return jsonb_build_object('status','error','error','FAC_DESACTIVADO'); end if;
  if v_id is null and v_local is null then return jsonb_build_object('status','error','error','ID_REQUERIDO'); end if;
  if not fac._admin_ok(p->>'clave_admin','FAC_ANULAR', coalesce(v_id, v_local)) then
    return jsonb_build_object('status','error','error','CLAVE_ADMIN_INVALIDA'); end if;

  select * into v_cmp from fac.comprobantes
   where (v_id is not null and id = v_id) or (v_id is null and local_id = v_local)
   limit 1 for update;
  if not found then return jsonb_build_object('status','error','error','NO_ENCONTRADO'); end if;
  if v_cmp.estado = 'BAJA' then return jsonb_build_object('status','success','ya',true,'id',v_cmp.id); end if;

  select * into v_cfg from fac.config where id = 1;
  v_real := v_cfg.activo and coalesce(v_cfg.nubefact_ruta,'') <> '' and coalesce(v_cfg.nubefact_token,'') <> '';

  if v_real and v_cmp.estado = 'EMITIDO' then
    begin
      v_resp := fac._http_nf(jsonb_build_object(
        'operacion','generar_anulacion','tipo_de_comprobante',v_cmp.tipo,
        'serie',v_cmp.serie,'numero',v_cmp.numero,'motivo',v_mot));
    exception when others then
      raise exception 'NUBEFACT_BAJA_SIN_RESPUESTA: %', SQLERRM;
    end;
    v_j := v_resp::jsonb;
    -- NubeFact responde con número de ticket SUNAT (la baja es async en SUNAT, NubeFact la gestiona)
    if coalesce(v_j->>'errors','') <> '' and coalesce((v_j->>'aceptada_por_sunat')::boolean,false) is not true
       and coalesce(v_j->>'numero_ticket_sunat','') = '' then
      return jsonb_build_object('status','error','error','NUBEFACT_RECHAZO_BAJA','detalle',v_j->>'errors');
    end if;
  elsif v_real and v_cmp.estado = 'RECHAZADO' then
    -- un rechazado por SUNAT no existe como válido → no se "anula", se marca local nomás
    null;
  end if;

  update fac.comprobantes
     set estado='BAJA', anulado_at=now(), anulado_motivo=v_mot,
         errores = coalesce(nullif(v_resp,''), errores)
   where id = v_cmp.id;
  return jsonb_build_object('status','success','id',v_cmp.id,'estado','BAJA');
end;
$fn$;

-- ── RECONCILIACIÓN (red de seguridad) ──
-- La emisión es SÍNCRONA → no hay PENDIENTE huérfana. Esto re-chequea RECHAZADO/PENDIENTE
-- por si SUNAT los aceptó después (o un timeout dejó el estado dudoso). Solo en modo real.
create or replace function fac.reconciliar(p_dias int default 7)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_cfg fac.config%rowtype; v_real boolean;
  v_row fac.comprobantes%rowtype; v_j jsonb;
  v_rev int := 0; v_emit int := 0;
begin
  select * into v_cfg from fac.config where id = 1;
  v_real := v_cfg.activo and coalesce(v_cfg.nubefact_ruta,'') <> '' and coalesce(v_cfg.nubefact_token,'') <> '';
  if not v_real then return jsonb_build_object('status','skip','motivo','config inactiva'); end if;

  for v_row in
    select * from fac.comprobantes
     where estado in ('PENDIENTE','RECHAZADO')
       and (creado_at at time zone 'America/Lima')::date >= ((now() at time zone 'America/Lima')::date - p_dias)
     order by creado_at
  loop
    v_rev := v_rev + 1;
    v_j := fac._consultar(v_row.serie, v_row.numero, v_row.tipo);
    if v_j is not null and coalesce((v_j->>'aceptada_por_sunat')::boolean,false) then
      update fac.comprobantes
         set estado='EMITIDO', nf_hash=v_j->>'codigo_hash', nf_enlace_pdf=v_j->>'enlace_del_pdf',
             nf_enlace_xml=v_j->>'enlace_del_xml', nf_qr=v_j->>'cadena_para_codigo_qr',
             sunat_descripcion=v_j->>'sunat_description', errores=null
       where id = v_row.id;
      v_emit := v_emit + 1;
    end if;
  end loop;
  return jsonb_build_object('status','success','revisados',v_rev,'reconciliados_emitidos',v_emit);
end;
$fn$;

-- pg_cron: reconciliar cada hora (no-op si config inactiva). Idempotente al re-aplicar.
select cron.unschedule('fac-reconciliar') where exists (select 1 from cron.job where jobname='fac-reconciliar');
select cron.schedule('fac-reconciliar', '7 * * * *', $$ select fac.reconciliar(7) $$);

-- ── LOOKUP RUC/DNI (API externa, GET Bearer) — detecta por longitud ──
create or replace function fac.consultar_documento(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_cfg fac.config%rowtype;
  v_n   text := regexp_replace(coalesce(p->>'numero',''), '\D', '', 'g');
  v_tipo text; v_url text; v_resp text; v_j jsonb; v_nombre text;
begin
  if not fac._app_ok() then return jsonb_build_object('ok',false,'motivo','no_autorizado'); end if;
  select * into v_cfg from fac.config where id = 1;
  if length(v_n) = 8 then v_tipo := '1'; v_url := coalesce(nullif(v_cfg.lookup_url_dni,''), v_cfg.lookup_url_ruc);
  elsif length(v_n) = 11 then v_tipo := '6'; v_url := coalesce(nullif(v_cfg.lookup_url_ruc,''), v_cfg.lookup_url_dni);
  else return jsonb_build_object('ok',false,'motivo','manual'); end if;
  if coalesce(v_url,'') = '' or coalesce(v_cfg.lookup_token,'') = '' then
    return jsonb_build_object('ok',false,'motivo','sin_config'); end if;
  begin
    perform set_config('statement_timeout','15000', true);
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT','12');
    select content into v_resp from extensions.http(('GET', v_url || v_n,
      array[extensions.http_header('Authorization','Bearer '||v_cfg.lookup_token)], NULL, NULL)::extensions.http_request);
    v_j := v_resp::jsonb;
  exception when others then return jsonb_build_object('ok',false,'motivo','no_encontrado'); end;
  v_nombre := coalesce(v_j->>'razonSocial', v_j->>'nombre',
                btrim(concat_ws(' ', v_j->>'nombres', v_j->>'apellidoPaterno', v_j->>'apellidoMaterno')));
  if coalesce(v_nombre,'') = '' then return jsonb_build_object('ok',false,'motivo','no_encontrado'); end if;
  return jsonb_build_object('ok',true,'doc_tipo',v_tipo,'doc_numero',v_n,'nombre',v_nombre,'direccion',coalesce(v_j->>'direccion',''));
end;
$fn$;

revoke all on function fac.anular_comprobante(jsonb) from public;
revoke all on function fac.reconciliar(int) from public;
revoke all on function fac.consultar_documento(jsonb) from public;
grant execute on function fac.anular_comprobante(jsonb) to authenticated;
grant execute on function fac.consultar_documento(jsonb) to authenticated;
