-- [974] FASE 2 · Reconciliador venta↔ajuste. Al cerrar caja, `zona_descontar_venta` resta TODAS las ventas
--  del día. Pero si el operador hizo un AJUSTE (conteo) a la hora T durante el día, las ventas ANTERIORES a T
--  ya están reflejadas en el número contado → restarlas otra vez = doble descuento. Solución: por producto,
--  sumar de vuelta las ventas previas al último conteo (movimiento AJUSTE_RECONCILIACION, visible en kardex).
--  Neto = conteo − (ventas posteriores al conteo). Idempotente por refId (RECON-VENTA:caja:cod) + el guard
--  caja-nivel que ya evita re-correr todo. NO cambia el descuento normal cuando no hubo ajuste.
create or replace function me.zona_descontar_venta(p jsonb DEFAULT '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_caja   text := btrim(coalesce(p->>'idCaja',''));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_kres   jsonb;
  v_aplicados int := 0;
  v_dedup     int := 0;
  v_resultado jsonb := '[]'::jsonb;
  v_adj_ts timestamptz;   -- [F2] hora del último ajuste/conteo del producto en la zona
  v_preadj numeric;       -- [F2] ventas de la caja ANTERIORES al conteo (a devolver)
  v_kres2  jsonb;         -- [F2] resultado del kardex de reconciliación (para gate por dedup)
  v_recon  int := 0;      -- [F2] cuántas reconciliaciones se emitieron
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_caja = '' then return jsonb_build_object('ok',false,'error','Requiere idCaja'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  if exists (select 1 from me.stock_movimientos where ref_id like 'VENTA-CAJA:'||v_caja||':%') then
    return jsonb_build_object('ok', true, 'idCaja', v_caja, 'zona', v_zona, 'dedupCaja', true,
      'aplicados', 0, 'dedup', 0, 'mensaje', 'Caja ya descontada (guard caja-nivel)');
  end if;

  create temp table _venta_agg (cod_barra text primary key, cant numeric) on commit drop;
  insert into _venta_agg(cod_barra, cant)
  select cv.canon_cod, sum(cv.cant)
    from me.ventas v join me.ventas_detalle vd on vd.id_venta = v.id_venta
    cross join lateral mos._venta_canonico(vd.cod_barras, vd.cantidad::numeric, vd.unidad_medida) cv
   where v.id_caja = v_caja and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
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

      -- [F2 RECONCILIADOR] ventas de ESTA caja anteriores al último conteo → ya están en el número contado.
      select max(ts) into v_adj_ts from me.zona_ajuste_log
        where upper(btrim(zona_id)) = v_zona and btrim(cod_barras) = v_cb;
      if v_adj_ts is not null then
        select coalesce(sum(cv.cant),0) into v_preadj
          from me.ventas vv join me.ventas_detalle vdd on vdd.id_venta = vv.id_venta
          cross join lateral mos._venta_canonico(vdd.cod_barras, vdd.cantidad::numeric, vdd.unidad_medida) cv
         where vv.id_caja = v_caja and upper(coalesce(vv.forma_pago,'')) not like 'ANULADO%'
           and cv.canon_cod = v_cb and cv.cant > 0 and vv.fecha < v_adj_ts;
        if coalesce(v_preadj,0) > 0 then
          v_kres2 := me.zona_kardex_registrar(jsonb_build_object(
            'zona', v_zona, 'codBarra', v_cb, 'tipo', 'AJUSTE_RECONCILIACION', 'delta', v_preadj,
            'refTipo','RECON','refId','RECON-VENTA:'||v_caja||':'||v_cb,
            'usuario','reconciliador-venta','origen',v_origen));
          if not coalesce((v_kres2->>'dedup')::boolean, false) then
            insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
              values (v_cb, v_zona, v_preadj, 'reconciliador-venta', now())
            on conflict (cod_barras, zona_id) do update
              set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_preadj, fecha_ultimo_registro = now();
            v_recon := v_recon + 1;
          end if;
        end if;
      end if;
    end if;
    v_resultado := v_resultado || jsonb_build_object('codBarra', v_cb, 'cantidad', v_cant,
      'aplicado', not coalesce((v_kres->>'dedup')::boolean,false));
  end loop;

  return jsonb_build_object('ok', true, 'idCaja', v_caja, 'zona', v_zona,
    'aplicados', v_aplicados, 'dedup', v_dedup, 'reconciliados', v_recon, 'detalle', v_resultado);
end;
$function$;

select '974 fase2 reconciliador listo' as ok;
