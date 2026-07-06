-- 396 · FIXES de la revisión 200x de la extensión v2.
-- CRÍTICO-1: la cascada seteaba forzar_logout pero NADIE lo honra → inerte. Señal self-contained: el estado
--   CERRADA de accesos_dispositivos. Nueva RPC extension_debe_cerrar que el equipo-extensión pollea.
-- ALTO-2: extension_qr_emitir no validaba que el llamador fuera el PRINCIPAL de esa sesión.

-- ── ALTO-2: solo el principal (device registrado es_principal de esa sesión) puede emitir/rotar el QR ──
create or replace function mos.extension_qr_emitir(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_idreq text := btrim(coalesce(p->>'idReq',''));
  v_cod   text := btrim(coalesce(p->>'codigo',''));
  v_dev   text := btrim(coalesce(p->>'deviceId',''));
  r mos.extension_requests%rowtype; v_tok text;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF'); end if;
  select * into r from mos.extension_requests where id_req = v_idreq for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  -- [FIX 396 ALTO-2] el emisor debe ser el PRINCIPAL de la sesión de esa solicitud (o no haber principal registrado aún)
  if v_dev <> '' and exists (select 1 from mos.accesos_dispositivos where id_dia = r.id_dia and es_principal and upper(coalesce(estado,''))='ACTIVA')
     and not exists (select 1 from mos.accesos_dispositivos where id_dia = r.id_dia and device_id = v_dev and es_principal and upper(coalesce(estado,''))='ACTIVA')
  then return jsonb_build_object('ok',false,'error','NO_SOS_EL_PRINCIPAL'); end if;
  if upper(coalesce(r.estado,'')) not in ('PENDIENTE','QR') then return jsonb_build_object('ok',false,'error','YA_'||upper(r.estado)); end if;
  if now() > r.expira then update mos.extension_requests set estado='EXPIRADA' where id_req=v_idreq;
    return jsonb_build_object('ok',false,'error','EXPIRADA'); end if;
  if v_cod <> '' and v_cod <> r.codigo then return jsonb_build_object('ok',false,'error','CODIGO_NO_COINCIDE'); end if;
  v_tok := substr(md5(random()::text || clock_timestamp()::text || v_idreq), 1, 12);
  update mos.extension_requests
     set estado='QR', qr_token=v_tok, qr_expira=now() + interval '90 seconds',
         expira = greatest(expira, now() + interval '5 minutes')
   where id_req = v_idreq;
  return jsonb_build_object('ok',true,'qrPayload','EXTQR:'||v_idreq||':'||v_tok,'qrToken',v_tok,'expiraSeg',90);
end; $fn$;

-- ── CRÍTICO-1: el equipo-extensión pollea esto; si su acceso ya no está ACTIVA (el principal cerró la sesión
--   con la cascada) o no existe → debe cerrar sesión. Self-contained + self-clearing (nueva sesión re-inserta ACTIVA). ──
create or replace function mos.extension_debe_cerrar(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_iddia text := nullif(btrim(coalesce(p->>'idDia','')),'');
  v_dev   text := btrim(coalesce(p->>'deviceId',''));
  v_estado text; v_ses_activa boolean;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_iddia is null or v_dev = '' then return jsonb_build_object('ok',true,'debeCerrar',false); end if;
  select upper(coalesce(estado,'')) into v_estado from mos.accesos_dispositivos where id_dia=v_iddia and device_id=v_dev limit 1;
  select exists(select 1 from mos.liquidaciones_dia where id_dia=v_iddia and upper(coalesce(estado_sesion,''))='ACTIVA') into v_ses_activa;
  -- cerrar si: mi acceso fue CERRADO, o no existe, o la sesión del principal ya no está ACTIVA
  return jsonb_build_object('ok',true,'debeCerrar',
    (v_estado is null or v_estado = 'CERRADA' or not coalesce(v_ses_activa,false)));
end; $fn$;

revoke all on function mos.extension_debe_cerrar(jsonb) from public, anon;
grant execute on function mos.extension_qr_emitir(jsonb), mos.extension_debe_cerrar(jsonb) to authenticated, service_role;
