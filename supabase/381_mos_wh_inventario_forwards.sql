-- 381 · kill-GAS (MOS) WH-INVENTARIO forwards → wrappers cross-app MONEY-SAFE.
-- Reusan los RPCs wh.* ATÓMICOS/IDEMPOTENTES ya en prod, SIN re-implementar la matemática de stock:
--   · wh.auditar_cuadre_stock()  (73, modelo CORTE+DELTA sobre stock_movimientos — NO el teórico-absoluto
--     que daba 419 falsos positivos; refresca las alertas ALAC_*)
--   · wh.aceptar_teorico_alerta(p) (68, ajuste atómico real→teórico por alerta; dedup local_id + guard revisado)
--   · wh.get_alertas_stock(p)      (157, lectura camelCase)
-- Gate mos._claim_ok() + ELEVACIÓN de claim a 'warehouseMos' (transaction-local) para que el reposo anidado
-- (wh._claim_ok) autorice con token MOS. El rollback revierte la elevación igual si algo lanza.

-- ── refresh del cuadre (wh_auditarStockGlobal) ── auditar_cuadre_stock NO gatea _claim_ok (service_role/definer).
create or replace function mos.wh_auditar_cuadre(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  perform set_config('statement_timeout','120s',true);
  return wh.auditar_cuadre_stock();
end; $fn$;

-- ── read: alertas de stock (camelCase) ──
create or replace function mos.wh_get_alertas_stock(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb, '{}'::jsonb);
  v_solo boolean := coalesce(nullif(btrim(coalesce(p->>'soloPendientes','')),'')::boolean, false);
  v_res jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app','warehouseMos'))::text, true);
  v_res := wh.get_alertas_stock(jsonb_build_object('soloPendientes', v_solo));
  perform set_config('request.jwt.claims', v_claims::text, true);
  return v_res;   -- {ok:true, data:[{idAlerta,codigoProducto,stockReal,stockTeorico,diferencia,revisado}]}
end; $fn$;

-- ── reconciliar UN producto: refresca cuadre + aplica la alerta de ese código (real→teórico) ──
create or replace function mos.wh_reconciliar_stock_producto(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb, '{}'::jsonb);
  v_cod  text := nullif(btrim(coalesce(p->>'codigoBarra', p->>'codigoProducto','')),'');
  v_por  text := coalesce(nullif(btrim(coalesce(p->>'autorizadoPor','')),''),'admin-mos');
  v_al text; v_sr numeric; v_st numeric; v_diff numeric; v_lid text; v_ts text; v_r jsonb; v_real numeric;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_cod is null then return jsonb_build_object('ok',false,'error','codigoBarra requerido'); end if;
  perform set_config('statement_timeout','120s',true);
  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app','warehouseMos'))::text, true);

  perform wh.auditar_cuadre_stock();   -- refresca ALAC_* con el modelo corte+delta
  -- SOLO alertas ALAC_ (las FRESCAS que auditar_cuadre acaba de calcular con corte+delta). Las AL_ huérfanas
  -- viejas (sync legacy de la Hoja) tienen diff ALMACENADO obsoleto → aplicarlas corrompería el stock.
  select id_alerta, coalesce(stock_real,0), coalesce(stock_teorico,0)
    into v_al, v_sr, v_st
    from wh.alertas_stock
   where btrim(coalesce(cod_producto,'')) = v_cod and coalesce(revisado,false) = false
     and id_alerta like 'ALAC\_%' escape '\'
   order by fecha desc limit 1;

  if v_al is null then
    -- sin alerta pendiente → real ya está dentro de 0.5 del esperado
    select coalesce(sum(cantidad_disponible),0) into v_real from wh.stock where btrim(coalesce(cod_producto,'')) = v_cod;
    perform set_config('request.jwt.claims', v_claims::text, true);
    return jsonb_build_object('ok',true,'data',jsonb_build_object('codigoBarra',v_cod,'real',v_real,'teorico',v_real,'diff',0,'accion','YA_CUADRA'));
  end if;

  v_diff := v_sr - v_st;
  v_lid := 'RECPRD_'||v_al;
  v_ts  := (extract(epoch from clock_timestamp())*1000)::bigint::text;
  v_r := wh.aceptar_teorico_alerta(jsonb_build_object('id_alerta',v_al,'usuario',v_por,'local_id',v_lid,
    'id_ajuste','AJ_'||v_lid, 'id_stock_nuevo','STK_'||v_lid, 'id_mov','MOV_'||v_lid||'_'||v_ts));
  perform set_config('request.jwt.claims', v_claims::text, true);

  if not coalesce((v_r->>'ok')::boolean,false) then
    return jsonb_build_object('ok',false,'error',coalesce(v_r->>'error','ajuste falló'));
  end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('codigoBarra',v_cod,'real',v_sr,'teorico',v_st,
    'diff',v_diff,'ajusteAplicado', -v_diff,
    'accion', case when abs(v_diff) <= 0.5 then 'YA_CUADRA' else 'CORREGIDO' end,
    'idAjuste', coalesce(v_r->>'idAjuste','AJ_'||v_lid)));
end; $fn$;

-- ── reconciliar MASIVO: refresca cuadre + aplica todas las alertas pendientes (con umbral/dryRun) ──
create or replace function mos.wh_reconciliar_stock_masivo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb, '{}'::jsonb);
  v_maxdiff numeric := coalesce(mos._numn(p->>'maxDiffAuto'),0);
  v_dry boolean := coalesce(nullif(btrim(coalesce(p->>'dryRun','')),'')::boolean, false);
  v_por text := coalesce(nullif(btrim(coalesce(p->>'autorizadoPor','')),''),'sistema-reconciliacion');
  v_corr int := 0; v_omit int := 0; v_err int := 0;
  rec record; v_diff numeric; v_lid text; v_ts text; v_r jsonb; v_det jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  perform set_config('statement_timeout','120s',true);
  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app','warehouseMos'))::text, true);

  perform wh.auditar_cuadre_stock();   -- 1) refrescar alertas (corte+delta)
  -- 2) aplicar por alerta pendiente (snapshot del cursor; aceptar marca revisado + mueve stock atómico)
  for rec in
    -- SOLO ALAC_ frescas (corte+delta). Las AL_ huérfanas viejas NO se auto-corrigen (diff obsoleto = corrupción).
    select id_alerta, cod_producto, coalesce(stock_real,0) sr, coalesce(stock_teorico,0) st
      from wh.alertas_stock
     where coalesce(revisado,false) = false and id_alerta like 'ALAC\_%' escape '\'
  loop
    v_diff := rec.sr - rec.st;
    if v_maxdiff > 0 and abs(v_diff) > v_maxdiff then
      v_omit := v_omit + 1;
      v_det := v_det || jsonb_build_object('codigoProducto',rec.cod_producto,'diff',v_diff,'accion','OMITIDA_UMBRAL');
      continue;
    end if;
    if v_dry then
      v_corr := v_corr + 1;
      v_det := v_det || jsonb_build_object('codigoProducto',rec.cod_producto,'diff',v_diff,'accion','DRY_RUN');
      continue;
    end if;
    v_lid := 'RECMAS_'||rec.id_alerta;
    v_ts  := (extract(epoch from clock_timestamp())*1000)::bigint::text;
    v_r := wh.aceptar_teorico_alerta(jsonb_build_object('id_alerta',rec.id_alerta,'usuario',v_por,'local_id',v_lid,
      'id_ajuste','AJ_'||v_lid, 'id_stock_nuevo','STK_'||v_lid, 'id_mov','MOV_'||v_lid||'_'||v_ts));
    if coalesce((v_r->>'ok')::boolean,false) then
      v_corr := v_corr + 1;
      v_det := v_det || jsonb_build_object('codigoProducto',rec.cod_producto,'diff',v_diff,'accion','CORREGIDO','idAjuste','AJ_'||v_lid);
    else
      v_err := v_err + 1;
      v_det := v_det || jsonb_build_object('codigoProducto',rec.cod_producto,'diff',v_diff,'accion','ERROR','error',v_r->>'error');
    end if;
  end loop;
  perform set_config('request.jwt.claims', v_claims::text, true);
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'corregidas',v_corr,'omitidas',v_omit,'errores',v_err,'dryRun',v_dry,'detalles',v_det));
end; $fn$;

revoke all on function mos.wh_auditar_cuadre(jsonb), mos.wh_get_alertas_stock(jsonb),
  mos.wh_reconciliar_stock_producto(jsonb), mos.wh_reconciliar_stock_masivo(jsonb) from public, anon;
grant execute on function mos.wh_auditar_cuadre(jsonb), mos.wh_get_alertas_stock(jsonb),
  mos.wh_reconciliar_stock_producto(jsonb), mos.wh_reconciliar_stock_masivo(jsonb) to authenticated, service_role;
