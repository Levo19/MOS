-- [885] el IGV a favor del mes suma también el buzón (facturas sin guía, válidas y no duplicadas)
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('wh.igv_favor_mes'::regproc);
  if position($q$'totalIGVFavor', round(v_tot,2),$q$ in v_def) = 0 then raise notice 'ancla no'; return; end if;
  -- declarar y calcular el buzón, y sumarlo al total + exponerlo
  v_def := replace(v_def,
    'v_data jsonb; v_tot numeric; v_n int; v_conigv int; v_sinfoto int; v_sinigv int; v_ilegible int;',
    'v_data jsonb; v_tot numeric; v_n int; v_conigv int; v_sinfoto int; v_sinigv int; v_ilegible int; v_buzon numeric; v_buzon_n int;');
  v_def := replace(v_def,
    $q$  return jsonb_build_object('ok',true,'data',jsonb_build_object($q$,
    $q$  select coalesce(sum(igv) filter (where estado='VALIDA'),0), count(*)
       into v_buzon, v_buzon_n
       from wh.igv_buzon where anio = v_anio and mes = v_mes;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'igvBuzon', round(coalesce(v_buzon,0),2), 'buzonItems', coalesce(v_buzon_n,0),$q$);
  -- el total a favor = guías + buzón
  v_def := replace(v_def, $q$'totalIGVFavor', round(v_tot,2),$q$,
                          $q$'totalIGVFavor', round(coalesce(v_tot,0) + coalesce(v_buzon,0),2), 'totalIGVFavorGuias', round(v_tot,2),$q$);
  execute v_def;
end $$;
select (wh.igv_favor_mes(jsonb_build_object('mes',8,'anio',2026))->'data'->>'totalIGVFavor') total, (wh.igv_favor_mes(jsonb_build_object('mes',8,'anio',2026))->'data'->>'igvBuzon') buzon;
