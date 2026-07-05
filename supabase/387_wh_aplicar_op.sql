-- 387 · kill-GAS WH — motor OpLog (Mermas V2). Reemplaza el handler GAS `aplicarOp`.
-- OpLog solo encola MERMA_AGREGAR / MERMA_SOLUCIONAR (verificado en js/mermas.js). Idempotente por idOp
-- (AGREGAR: id_merma determinista = 'M_'||idOp; SOLUCIONAR: reusa wh.resolver_merma que dedup por local_id).
-- ⚠️ agregar merma NO mueve stock (solo registra); el descarte mueve stock al CERRAR la guía SALIDA_MERMA.
create or replace function wh.aplicar_op(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_idop text := nullif(btrim(coalesce(p->>'idOp','')),'');
  v_tipo text := upper(coalesce(p->>'tipo',''));
  v_usr  text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'almacen');
  v_pl   jsonb;
  v_idm  text; v_cod text; v_cant numeric; v_res jsonb;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idop is null then return jsonb_build_object('ok',false,'error','FALTA_idOp'); end if;
  -- payload llega como string (JSON.stringify) o como objeto → normalizar a jsonb
  begin
    v_pl := case when jsonb_typeof(p->'payload') = 'object' then p->'payload'
                 else (nullif(btrim(coalesce(p->>'payload','')),''))::jsonb end;
  exception when others then v_pl := '{}'::jsonb; end;
  v_pl := coalesce(v_pl, '{}'::jsonb);

  if v_tipo = 'MERMA_AGREGAR' then
    v_idm  := 'M_' || v_idop;                                  -- determinista → idempotente
    v_cod  := nullif(btrim(coalesce(v_pl->>'codigoProducto', v_pl->>'codigo_producto','')),'');
    v_cant := wh._num(v_pl->>'cantidadOriginal');
    if v_cod is null then return jsonb_build_object('ok',false,'error','FALTA_codigoProducto'); end if;
    if coalesce(v_cant,0) <= 0 then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
    -- dedup: idOp ya aplicado → merma existe
    if exists (select 1 from wh.mermas where id_merma = v_idm) then
      return jsonb_build_object('ok',true,'dedup',true,'data',jsonb_build_object('idMerma',v_idm,'fotoUrl',''));
    end if;
    insert into wh.mermas (id_merma, fecha_ingreso, origen, cod_producto, cantidad_original, cantidad_pendiente,
      cantidad_reparada, cantidad_desechada, motivo, usuario, estado, responsable, foto)
    values (v_idm, now(),
      coalesce(nullif(btrim(coalesce(v_pl->>'zonaResponsable','')),''),'ALMACEN'),
      v_cod, v_cant, v_cant, 0, 0,
      coalesce(v_pl->>'motivo',''), v_usr, 'EN_PROCESO',
      coalesce(v_pl->>'zonaResponsable',''), '')
    on conflict (id_merma) do nothing;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('idMerma',v_idm,'fotoUrl',''));

  elsif v_tipo = 'MERMA_SOLUCIONAR' then
    v_idm := nullif(btrim(coalesce(v_pl->>'idMerma','')),'');
    if v_idm is null then return jsonb_build_object('ok',false,'error','FALTA_idMerma'); end if;
    -- reusa la RPC atómica (crea línea SALIDA_MERMA, guard de estado, dedup por local_id=idOp)
    v_res := wh.resolver_merma(jsonb_build_object(
      'id_merma', v_idm,
      'cantidad_reparada', wh._num(v_pl->>'deltaRecuperado'),
      'cantidad_desechada', wh._num(v_pl->>'deltaDescartado'),
      'observacion_resolucion', coalesce(v_pl->>'observacion',''),
      'usuario', v_usr, 'local_id', v_idop));
    if coalesce((v_res->>'ok')::boolean,false) then
      return jsonb_build_object('ok',true,'data', coalesce(v_res->'data', v_res));
    end if;
    return v_res;   -- {ok:false,error} → OpLog reintenta/marca failed

  else
    return jsonb_build_object('ok',false,'error','TIPO_NO_SOPORTADO: '||v_tipo);
  end if;
end; $fn$;

revoke all on function wh.aplicar_op(jsonb) from public, anon;
grant execute on function wh.aplicar_op(jsonb) to authenticated, service_role;
