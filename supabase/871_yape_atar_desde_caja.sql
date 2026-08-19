-- 871 · Modo Cajero: cuando el cajero cobra VIRTUAL con el Yape a la vista, se ata en el acto.
--
-- La estación ya muestra "Olivia yapeó S/ 5.60" sobre el botón VIRTUAL. Pero al cobrar, el
-- ticket NO quedaba verificado: la pantalla decía "✅ verificado con el Yape de Olivia" y en
-- realidad el vínculo lo hacía el cron yape-matchear cada 2 min, por monto — y si en esos
-- minutos entraban dos tickets de S/ 5.60, los marcaba AMBIGUO y ninguno quedaba verificado.
-- El cajero tenía el contexto que le falta al cron (ESTE cliente está pagando ESTE ticket) y
-- no se usaba.
--
-- mos.yape_resolver ya hace el vínculo, pero su guardia mos._claim_ok() rechaza la app
-- mosExpress (trampa conocida: 848d, 855c). Este es el espejo para la caja, con guardia propia
-- y las mismas reglas: un ticket, un solo Yape; el Yape tiene que estar libre.

begin;

create or replace function me.yape_atar_cobro(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id   bigint := nullif(p->>'id','')::bigint;
  v_vta  text   := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_por  text   := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'CAJERO');
  v_est  text; v_monto numeric; v_zona text; v_zona_v text; v_forma text; v_total numeric;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS')
     and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','') <> 'service_role' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null or v_vta is null then return jsonb_build_object('ok', false, 'error', 'id e idVenta requeridos'); end if;

  select estado, monto, zona into v_est, v_monto, v_zona from mos.yapes_entrantes where id = v_id for update;
  if v_est is null then return jsonb_build_object('ok', false, 'error', 'Ese Yape no existe'); end if;
  if v_est <> 'NUEVO' and v_est <> 'AMBIGUO' then
    return jsonb_build_object('ok', false, 'error', 'Ese Yape ya está usado');
  end if;

  select forma_pago, total, k.zona_id into v_forma, v_total, v_zona_v
    from me.ventas v left join me.cajas k on k.id_caja = v.id_caja where v.id_venta = v_vta;
  if v_forma is null then return jsonb_build_object('ok', false, 'error', 'Ese ticket no existe'); end if;
  -- el ticket tiene que estar cobrado por medio virtual (o la parte VIR de un mixto)
  if me._monto_virtual(v_forma, v_total) is null then
    return jsonb_build_object('ok', false, 'error', 'El ticket no está pagado por medio virtual');
  end if;
  -- el monto tiene que calzar a UN decimal (Yape mueve un decimal)
  if round(me._monto_virtual(v_forma, v_total), 1) <> round(v_monto, 1) then
    return jsonb_build_object('ok', false, 'error', 'El monto no calza');
  end if;
  -- misma zona que el celular que capturó el Yape (si el Yape trae zona)
  if coalesce(v_zona,'') <> '' and upper(btrim(coalesce(v_zona_v,''))) <> upper(btrim(v_zona)) then
    return jsonb_build_object('ok', false, 'error', 'El Yape es de otra zona');
  end if;
  if exists (select 1 from mos.yapes_entrantes where id_venta = v_vta and id <> v_id) then
    return jsonb_build_object('ok', false, 'error', 'Ese ticket ya está verificado por otro Yape');
  end if;

  update mos.yapes_entrantes
     set estado = 'MATCHEADO', id_venta = v_vta, match_ts = now(), match_por = v_por,
         meta = coalesce(meta,'{}'::jsonb) || jsonb_build_object('resueltoEnCaja', true)
   where id = v_id;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('id', v_id, 'idVenta', v_vta));
end $$;

revoke all on function me.yape_atar_cobro(jsonb) from public;
grant execute on function me.yape_atar_cobro(jsonb) to anon, authenticated, service_role;

commit;
