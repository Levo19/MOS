-- 273_cpe_reconciliador_batch.sql — Reconciliación BATCH del estado SUNAT, 100% Supabase (cero-GAS).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- Cierra el último hueco cero-GAS del CPE: hoy el flip PENDIENTE→EMITIDO (cuando SUNAT acepta async)
-- solo lo hacía un cron GAS que leía la Hoja. Ahora un pg_cron Supabase-native dispara el Edge
-- `reconciliar-cpe` (token NubeFact en secret), que re-consulta SUNAT y persiste vía me.set_cpe_nf.
--
-- Token EN SECRET (no en DB): el cron NO toca NubeFact; solo hace net.http_post al Edge con un secreto
-- compartido (Vault). El Edge tiene el token. Mantiene la decisión del dueño ("debe quedar en Edge").
--
-- GATED OFF: flag CPE_RECON_ON='0' → me.cpe_reconciliar_cron() no-opera. Se prende en el cutover (miércoles)
-- junto con el token de producción. El pg_cron queda programado pero inerte hasta el flip.
-- Additivo, idempotente, money/fiscal-safe (solo lee + patcha nf_*; no toca dinero/stock).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1. set_cpe_nf: aceptar el camino service_role (el Edge reconciliador escribe con la service key) ──
-- Se agrega SOLO la condición role=service_role; app mosExpress/MOS sigue igual. Todo lo demás intacto
-- (whitelist de estados, EMITIDO_NO_DEGRADABLE, merge de trazabilidad).
create or replace function me.set_cpe_nf(p_ref_local text, p_nf jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app  text := me.jwt_app();
  v_role text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','');
  v_ref  text := nullif(btrim(coalesce(p_ref_local,'')),'');
  v_new  text := upper(coalesce(p_nf->>'nf_estado',''));
  v_cur  me.ventas%rowtype;
  v_n    int;
  v_acep boolean := case when p_nf ? 'aceptada' then (p_nf->>'aceptada')::boolean
                         when p_nf ? 'nf_aceptada_sunat' then (p_nf->>'nf_aceptada_sunat')::boolean
                         else null end;
begin
  if v_app not in ('mosExpress','MOS') and v_role <> 'service_role' then
    return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA');
  end if;
  if not me._cpe_directo_on() then return jsonb_build_object('status','error','error','CPE_DIRECTO_DESACTIVADO'); end if;
  if v_ref is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  if v_new <> '' and v_new not in ('PENDIENTE','EMITIDO','RECHAZADO','BAJA') then
    return jsonb_build_object('status','error','error','NF_ESTADO_INVALIDO');
  end if;

  select * into v_cur from me.ventas where ref_local = v_ref limit 1;
  if not found then return jsonb_build_object('status','success','actualizadas',0); end if;
  if v_cur.tipo_doc not in ('BOLETA','FACTURA') then
    return jsonb_build_object('status','error','error','NO_ES_CPE');
  end if;
  if coalesce(v_cur.nf_estado,'') = 'EMITIDO' and v_new <> '' and v_new <> 'EMITIDO' and v_new <> 'BAJA' then
    return jsonb_build_object('status','error','error','EMITIDO_NO_DEGRADABLE');
  end if;

  update me.ventas
     set nf_estado = case when v_new <> '' then v_new else nf_estado end,
         nf_hash   = coalesce(p_nf->>'nf_hash',   nf_hash),
         nf_enlace = coalesce(p_nf->>'nf_enlace', nf_enlace),
         nf_qr     = coalesce(nullif(p_nf->>'nf_qr',''), nullif(p_nf->>'qr',''), nullif(p_nf->>'qrString',''), nf_qr),
         nf_aceptada_sunat = coalesce(v_acep, nf_aceptada_sunat),
         nf_sunat_code  = coalesce(nullif(p_nf->>'sunat_code',''), nullif(p_nf->>'nf_sunat_code',''), nf_sunat_code),
         nf_sunat_desc  = coalesce(nullif(p_nf->>'sunat_desc',''), nullif(p_nf->>'sunatDescription',''), nullif(p_nf->>'nf_sunat_desc',''), nf_sunat_desc),
         nf_enlace_xml  = coalesce(nullif(p_nf->>'enlace_xml',''), nullif(p_nf->>'nf_enlace_xml',''), nf_enlace_xml),
         nf_enlace_cdr  = coalesce(nullif(p_nf->>'enlace_cdr',''), nullif(p_nf->>'nf_enlace_cdr',''), nf_enlace_cdr),
         nf_orden_sunat = coalesce(nullif(p_nf->>'numero_orden_sunat',''), nullif(p_nf->>'nf_orden_sunat',''), nf_orden_sunat),
         nf_ultima_consulta = case when p_nf ? 'consultado' or v_acep is not null or coalesce(p_nf->>'nf_estado','')<>''
                                   then now() else nf_ultima_consulta end
   where ref_local = v_ref;
  get diagnostics v_n = row_count;
  return jsonb_build_object('status','success','actualizadas', v_n);
end;
$fn$;
revoke all on function me.set_cpe_nf(text, jsonb) from public;
grant execute on function me.set_cpe_nf(text, jsonb) to authenticated, service_role;

-- ── 2. Backfill del huérfano: un CPE con correlativo consumido pero nf_estado NULL = al menos PENDIENTE ──
-- (fue creado; el reconciliador determinará su estado SUNAT real). Idempotente.
update me.ventas
   set nf_estado = 'PENDIENTE'
 where tipo_doc in ('BOLETA','FACTURA')
   and coalesce(nf_estado,'') = ''
   and coalesce(correlativo,'') <> '';

-- ── 3. Flag de activación del cron (inerte hasta el cutover) ──
insert into mos.config (clave, valor) values ('CPE_RECON_ON','0')
on conflict (clave) do nothing;

-- ── 4. Secreto compartido cron↔Edge en Vault (idempotente; el MISMO valor va como secret del Edge) ──
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'cpe_cron_secret') then
    perform vault.create_secret('88aee18025ddb70b5947dd0763b3c69e7d648624a537df5b', 'cpe_cron_secret',
      'Secreto compartido pg_cron→Edge reconciliar-cpe (header x-cpe-cron). Igual al secret CPE_CRON_SECRET del Edge.');
  end if;
end $$;

-- ── 5. Disparador del cron: gated por flag, lee el secreto de Vault, net.http_post al Edge ──
create or replace function me.cpe_reconciliar_cron()
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare
  v_on   text;
  v_sec  text;
  v_req  bigint;
  v_url  text := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/reconciliar-cpe';
begin
  select valor into v_on from mos.config where clave = 'CPE_RECON_ON' limit 1;
  if coalesce(v_on,'0') <> '1' then return -1; end if;   -- inerte hasta el cutover
  select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'cpe_cron_secret' limit 1;
  if v_sec is null then return -2; end if;
  select net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type','application/json','x-cpe-cron', v_sec),
    body    := jsonb_build_object('dias', 7, 'limite', 50)
  ) into v_req;
  return v_req;
end;
$fn$;
revoke all on function me.cpe_reconciliar_cron() from public, anon, authenticated;

-- ── 6. Programar el pg_cron (cada hora al minuto 23; inerte mientras CPE_RECON_ON='0') ──
select cron.unschedule('cpe-reconciliar') where exists (select 1 from cron.job where jobname = 'cpe-reconciliar');
select cron.schedule('cpe-reconciliar', '23 * * * *', $$select me.cpe_reconciliar_cron();$$);

notify pgrst, 'reload schema';
