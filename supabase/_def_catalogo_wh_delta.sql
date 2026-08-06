CREATE OR REPLACE FUNCTION mos.catalogo_wh_delta(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_desde timestamptz := nullif(btrim(coalesce(p->>'desde','')),'')::timestamptz;
  v_prod jsonb; v_equiv jsonb; v_prov jsonb; v_pers jsonb; v_impr jsonb; v_zonas jsonb; v_elim jsonb; v_nprod int;
  v_ts timestamptz := now();   -- [race-safe] corte ANTES de leer
begin
  if not (wh._claim_ok() or mos._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_desde is null then return jsonb_build_object('ok', false, 'error', 'DESDE_REQUERIDO'); end if;
  -- [500x HIGH] filtro `>=` (no `>`) + el server_ts devuelto lleva margen (-2s) → solape idempotente que
  -- cierra la ventana de pérdida en el borde del corte (un writer que commitea con updated_at<=corte).
  select coalesce(jsonb_agg((to_jsonb(t) - 'created_at' - 'updated_at') order by t.id_producto), '[]'::jsonb), count(*)
    into v_prod, v_nprod
    from mos.productos t where t.updated_at >= v_desde;
  -- borrados desde el corte (que NO fueron recreados) → el front los saca del cache
  select coalesce(jsonb_agg(ts.id_producto), '[]'::jsonb) into v_elim
    from mos.catalogo_tombstones ts
   where ts.deleted_at >= v_desde
     and not exists (select 1 from mos.productos pp where pp.id_producto = ts.id_producto);
  -- tablas chicas: completas (son ~50KB juntas y cambian poco; evita lógica de merge por tabla)
  select coalesce(jsonb_agg(to_jsonb(e) order by e.id_equiv), '[]'::jsonb) into v_equiv from mos.equivalencias e where e.activo = true;
  select coalesce(jsonb_agg((to_jsonb(pr) - 'numero_cuenta' - 'cci') order by pr.id_proveedor), '[]'::jsonb) into v_prov from mos.proveedores pr;
  select coalesce(jsonb_agg((to_jsonb(pe) - 'pin' - 'pin_hash') order by pe.id_personal), '[]'::jsonb) into v_pers from mos.personal pe where pe.estado = true;
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id_impresora), '[]'::jsonb) into v_impr from mos.impresoras i where lower(coalesce(i.app_origen,'')) = 'warehousemos' and i.activo = true;
  select coalesce(jsonb_agg(to_jsonb(z) order by z.id_zona), '[]'::jsonb) into v_zonas from mos.zonas z where z.estado = true;
  return jsonb_build_object('ok', true, 'delta', true,
    'server_ts', to_char((v_ts - interval '2 seconds') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'productos_cambiados', v_nprod, 'eliminados', v_elim,
    'productos', v_prod, 'equivalencias', v_equiv, 'proveedores', v_prov,
    'personal', v_pers, 'impresoras', v_impr, 'zonas', v_zonas);
end;
$function$
