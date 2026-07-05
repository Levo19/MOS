-- 382 · kill-GAS Tributación. Los bridges GAS (CentroTributario.gs) llamaban ME/WH GAS. Gran parte YA existe
-- en Supabase (me.tributario_ventas_mes 326, me.cpe_trazabilidad 272, Edge emitir-cpe op=consultar, wh.guardar_ocr_guia 63).
-- Faltaban: (1) IGV-favor por mes (compras), (2) resumen agregado, (3) limpiar ventas huérfanas.

-- ── 1) IGV recuperable del mes (crédito fiscal de compras = guías INGRESO_PROVEEDOR con comprobante OCR) ──
create or replace function wh.igv_favor_mes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_mes int := coalesce(mos._numn(p->>'mes')::int, extract(month from (now() at time zone 'America/Lima'))::int);
  v_anio int := coalesce(mos._numn(p->>'anio')::int, extract(year from (now() at time zone 'America/Lima'))::int);
  v_data jsonb; v_tot numeric; v_n int; v_conigv int; v_sinfoto int; v_sinigv int; v_ilegible int;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with g as (
    select * from wh.guias
     where upper(coalesce(tipo,'')) like 'INGRESO_PROVEEDOR%'
       and extract(month from (fecha at time zone 'America/Lima')) = v_mes
       and extract(year  from (fecha at time zone 'America/Lima')) = v_anio
  )
  select
    coalesce(sum(igv_recuperable),0),
    count(*),
    count(*) filter (where coalesce(igv_recuperable,0) > 0),
    count(*) filter (where btrim(coalesce(foto,'')) = ''),
    count(*) filter (where upper(coalesce(ocr_estado,'')) = 'SIN_IGV'),
    count(*) filter (where upper(coalesce(ocr_estado,'')) = 'ILEGIBLE'),
    coalesce(jsonb_agg(jsonb_build_object(
      'idGuia', id_guia, 'urlFoto', foto, 'tieneFoto', (btrim(coalesce(foto,'')) <> ''),
      'fecha', fecha, 'fechaComprobante', ocr_fecha_comprobante, 'serie', ocr_serie, 'numero', ocr_numero,
      'total', ocr_total, 'igvRecuperable', coalesce(igv_recuperable,0), 'ocrEstado', ocr_estado,
      'confidence', ocr_confidence) order by fecha desc), '[]'::jsonb)
  into v_tot, v_n, v_conigv, v_sinfoto, v_sinigv, v_ilegible, v_data
  from g;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'guias', v_data, 'totalIGVFavor', round(v_tot,2), 'totalGuias', v_n, 'totalGuiasConIGV', v_conigv,
    'totalGuiasSinFoto', v_sinfoto, 'totalGuiasSinIGV', v_sinigv, 'totalGuiasIlegibles', v_ilegible,
    'mes', v_mes, 'anio', v_anio));
end; $fn$;

-- ── 2) Resumen tributario del mes (combina ventas ME + IGV-favor WH + cálculos) ──
create or replace function mos.trib_resumen_mes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_mes int := coalesce(mos._numn(p->>'mes')::int, extract(month from (now() at time zone 'America/Lima'))::int);
  v_anio int := coalesce(mos._numn(p->>'anio')::int, extract(year from (now() at time zone 'America/Lima'))::int);
  v_ventas jsonb; v_favor jsonb; vf jsonb;
  v_igvem numeric; v_totv numeric; v_igvfav numeric;
  v_hoy date := (now() at time zone 'America/Lima')::date;
  v_diaAct int; v_ultDia int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_ventas := me.tributario_ventas_mes(v_mes, v_anio);         -- {status,totalVentas,totalIGVEmitido,cpe*}
  v_favor  := wh.igv_favor_mes(jsonb_build_object('mes',v_mes,'anio',v_anio));
  vf := coalesce(v_favor->'data','{}'::jsonb);
  v_igvem := coalesce(mos._numn(v_ventas->>'totalIGVEmitido'),0);
  v_totv  := coalesce(mos._numn(v_ventas->>'totalVentas'),0);
  v_igvfav:= coalesce(mos._numn(vf->>'totalIGVFavor'),0);
  -- progreso del mes (si es el mes en curso; si no, mes completo)
  v_ultDia := extract(day from (date_trunc('month', make_date(v_anio,v_mes,1)) + interval '1 month - 1 day'))::int;
  v_diaAct := case when v_mes = extract(month from v_hoy)::int and v_anio = extract(year from v_hoy)::int
                   then extract(day from v_hoy)::int else v_ultDia end;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'mes', v_mes, 'anio', v_anio,
    'igvFavor', round(v_igvfav,2), 'igvEmitido', round(v_igvem,2),
    'balanceNetoIGV', round(v_igvem - v_igvfav, 2),
    'totalVentas', round(v_totv,2), 'rentaMensual', round(v_totv * 0.015, 2),   -- MYPE 1.5%
    'diaActual', v_diaAct, 'ultimoDia', v_ultDia,
    'pctMes', round((v_diaAct::numeric / nullif(v_ultDia,0)) * 100)::int,
    'guiasMes', coalesce(mos._numn(vf->>'totalGuias'),0)::int,
    'guiasConIGV', coalesce(mos._numn(vf->>'totalGuiasConIGV'),0)::int,
    'guiasSinFoto', coalesce(mos._numn(vf->>'totalGuiasSinFoto'),0)::int,
    'guiasSinIGV', coalesce(mos._numn(vf->>'totalGuiasSinIGV'),0)::int,
    'guiasIlegibles', coalesce(mos._numn(vf->>'totalGuiasIlegibles'),0)::int,
    'cpeEmitidos', coalesce(mos._numn(v_ventas->>'cpeEmitidos'),0)::int,
    'cpePendientes', coalesce(mos._numn(v_ventas->>'cpePendientes'),0)::int,
    'cpeErrores', coalesce(mos._numn(v_ventas->>'cpeErrores'),0)::int,
    'cpeAnulados', coalesce(mos._numn(v_ventas->>'cpeAnulados'),0)::int,
    'cpeTotal', coalesce(mos._numn(v_ventas->>'cpeTotal'),0)::int));
end; $fn$;

-- ── 3) Limpiar ventas huérfanas (correlativo 'undefined-*' → HUERFANA_LIMPIADA). Escritura fiscal ──
create or replace function mos.limpiar_ventas_huerfanas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  update me.ventas set estado_envio = 'HUERFANA_LIMPIADA'
   where upper(coalesce(tipo_doc,'')) in ('BOLETA','FACTURA')
     and correlativo ilike 'undefined%'
     and coalesce(estado_envio,'') <> 'HUERFANA_LIMPIADA';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('limpiadas', v_n));
end; $fn$;

revoke all on function wh.igv_favor_mes(jsonb), mos.trib_resumen_mes(jsonb), mos.limpiar_ventas_huerfanas(jsonb) from public, anon;
grant execute on function wh.igv_favor_mes(jsonb), mos.trib_resumen_mes(jsonb), mos.limpiar_ventas_huerfanas(jsonb) to authenticated, service_role;
