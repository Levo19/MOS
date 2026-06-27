-- 143 · me.zona_descontar_venta — ENDURECIMIENTO R1: guard idempotente a NIVEL DE CAJA.
-- Antes la idempotencia era por línea (refId canónico). Si una caja vieja (refId de presentación)
-- se re-procesara con la función nueva (refId canónico), no haría dedup -> doble descuento.
-- Este guard bloquea cualquier re-proceso de una caja que YA tiene CUALQUIER descuento VENTA-CAJA.
create or replace function me.zona_descontar_venta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_caja   text := btrim(coalesce(p->>'idCaja',''));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_cb     text;
  v_cant   numeric(20,3);
  v_kres   jsonb;
  v_aplicados int := 0;
  v_dedup     int := 0;
  v_resultado jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_caja = '' then return jsonb_build_object('ok',false,'error','Requiere idCaja'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  -- [R1] guard caja-level: si esta caja YA tiene cualquier descuento VENTA-CAJA (viejo o nuevo)
  -- no re-procesar -> doble descuento imposible aunque el refId histórico sea de presentación.
  if exists (select 1 from me.stock_movimientos
               where ref_id like 'VENTA-CAJA:'||replace(replace(v_caja,'%','\%'),'_','\_')||':%') then
    return jsonb_build_object('ok',true,'idCaja',v_caja,'zona',v_zona,
      'dedup_caja',true,'aplicados',0,'dedup',0);
  end if;

  create temp table _venta_agg (cod_barra text primary key, cant numeric) on commit drop;
  -- poblar desde me.ventas_detalle resolviendo al CANÓNICO (regla peso/unidad vía helper).
  insert into _venta_agg(cod_barra, cant)
  select cv.canon_cod, sum(cv.cant)
    from me.ventas v join me.ventas_detalle vd on vd.id_venta = v.id_venta
    cross join lateral mos._venta_canonico(vd.cod_barras, vd.cantidad::numeric, vd.unidad_medida) cv
   where v.id_caja = v_caja and upper(coalesce(v.forma_pago,'')) <> 'ANULADO'
     and coalesce(nullif(btrim(cv.canon_cod),''),'') <> '' and cv.cant > 0
   group by cv.canon_cod
  on conflict (cod_barra) do update set cant = _venta_agg.cant + excluded.cant;

  for v_cb, v_cant in select cod_barra, cant from _venta_agg loop
    v_kres := me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb, 'tipo', 'SALIDA_VENTA', 'delta', (-v_cant),
      'refTipo', 'VENTA', 'refId', 'VENTA-CAJA:'||v_caja||':'||v_cb, 'usuario', v_user, 'origen', v_origen));
    if coalesce((v_kres->>'dedup')::boolean, false) then
      v_dedup := v_dedup + 1;
    else
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_cb, v_zona, -v_cant, v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) - v_cant,
            usuario = excluded.usuario, fecha_ultimo_registro = now();
      v_aplicados := v_aplicados + 1;
    end if;
    v_resultado := v_resultado || jsonb_build_object('codBarra', v_cb, 'cantidad', v_cant,
      'aplicado', not coalesce((v_kres->>'dedup')::boolean,false));
  end loop;

  return jsonb_build_object('ok', true, 'idCaja', v_caja, 'zona', v_zona,
    'aplicados', v_aplicados, 'dedup', v_dedup, 'detalle', v_resultado);
end;
$fn$;
