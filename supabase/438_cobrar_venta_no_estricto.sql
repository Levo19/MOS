-- 438 · reverificar 5-arg (p_strict) + cobrar_venta_directo en modo verifica-si-viene (RPC mixta).

create or replace function mos.reverificar_clave_admin(p_clave text, p_accion text, p_ref text, p_app text, p_strict boolean)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_res jsonb;
begin
  if p_clave is null or btrim(p_clave)='' then
    if p_strict and coalesce((select valor from mos.config where clave='MOS_STRICT_ADMIN_REVERIFY' limit 1),'0')='1' then
      return jsonb_build_object('ok',false,'autorizado',false,'error','Requiere clave admin (8 dígitos)');
    end if;
    return null;
  end if;
  v_res := mos._validar_clave_admin_core(btrim(p_clave), coalesce(nullif(btrim(p_accion),''),'GENERICA'), coalesce(p_ref,''), coalesce(nullif(p_app,''),'MOS'));
  if coalesce((v_res->>'autorizado')::boolean,false) then return null; end if;
  return jsonb_build_object('ok',false,'autorizado',false,'error',coalesce(v_res->>'error','Clave incorrecta o rol insuficiente'));
end; $fn$;
revoke all on function mos.reverificar_clave_admin(text,text,text,text,boolean) from public, anon;
grant execute on function mos.reverificar_clave_admin(text,text,text,text,boolean) to authenticated, service_role;

CREATE OR REPLACE FUNCTION me.cobrar_venta_directo(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_met   text := nullif(btrim(coalesce(p->>'metodo','')),'');
  v_caja  text := nullif(btrim(coalesce(p->>'cajaId','')),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_mot   text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_ant   text; v_cajaAnt text; v_hist jsonb; v_cambios jsonb;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'COBRAR_VENTA', coalesce(p->>'idVenta',p->>'idVentaNV',p->>'idGuia',p->>'nombre',''), coalesce(p->>'app','MOS'), false);
  if v_rvf is not null then return v_rvf; end if;
  if v_app not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_id  is null then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;
  if v_met is null then return jsonb_build_object('ok',false,'error','metodo requerido'); end if;

  -- lock por VENTA (mismo namespace que confirmar/directo/anular) → un COBRAR_VENTA no corre en
  -- paralelo con un cobro/anulación de la misma venta. Leo bajo el lock (FOR UPDATE).
  perform pg_advisory_xact_lock(hashtext('cobro:'||v_id));
  select forma_pago, coalesce(id_caja,''), historial_cambios into v_ant, v_cajaAnt, v_hist
  from me.ventas where id_venta = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Venta '||v_id||' no encontrada'); end if;

  -- ANULADO% es terminal (paridad GAS): no se cobra ni se revierte una venta anulada.
  if upper(coalesce(v_ant,'')) like 'ANULADO%' then
    return jsonb_build_object('ok',false,'error','La venta está ANULADA — no se puede cambiar su forma de pago');
  end if;

  v_cambios := jsonb_build_array(jsonb_build_object('campo','FormaPago','antes',coalesce(v_ant,''),'despues',v_met));
  if v_caja is not null and v_caja <> coalesce(v_cajaAnt,'') then
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object('campo','ID_Caja','antes',coalesce(v_cajaAnt,''),'despues',v_caja));
  end if;

  update me.ventas
     set forma_pago = v_met,
         id_caja = case when v_caja is not null then v_caja else id_caja end,   -- solo si viene cajaId (paridad GAS)
         historial_cambios = me._venta_hist_append(v_hist, jsonb_build_object(
           'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
           'source','ME_COBRAR_VENTA','accion','cobrar_venta',
           'cambios', v_cambios, 'autorizadoPor', v_auth, 'motivo', v_mot)),
         updated_at = now()
   where id_venta = v_id;

  return jsonb_build_object('ok',true,'via','directo','mensaje','Venta cobrada correctamente',
    'idVenta',v_id,'antes',coalesce(v_ant,''),'despues',v_met);
end;
$function$
;
