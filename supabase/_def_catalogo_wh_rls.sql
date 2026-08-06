CREATE OR REPLACE FUNCTION mos.catalogo_wh_rls()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_prod jsonb; v_equiv jsonb; v_prov jsonb; v_pers jsonb; v_impr jsonb; v_zonas jsonb;
        v_ts timestamptz := now();   -- [race-safe] corte ANTES de leer: lo que cambie durante el query lo re-trae el próximo delta
begin
  if not (wh._claim_ok() or mos._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg((to_jsonb(t) - 'created_at' - 'updated_at') order by t.id_producto), '[]'::jsonb) into v_prod from mos.productos t;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.id_equiv), '[]'::jsonb) into v_equiv from mos.equivalencias e where e.activo = true;
  select coalesce(jsonb_agg((to_jsonb(p) - 'numero_cuenta' - 'cci') order by p.id_proveedor), '[]'::jsonb) into v_prov from mos.proveedores p;
  select coalesce(jsonb_agg((to_jsonb(p) - 'pin' - 'pin_hash') order by p.id_personal), '[]'::jsonb) into v_pers from mos.personal p where p.estado = true;
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id_impresora), '[]'::jsonb) into v_impr from mos.impresoras i where lower(coalesce(i.app_origen,'')) = 'warehousemos' and i.activo = true;
  select coalesce(jsonb_agg(to_jsonb(z) order by z.id_zona), '[]'::jsonb) into v_zonas from mos.zonas z where z.estado = true;
  return jsonb_build_object('ok', true, 'server_ts', to_char((v_ts - interval '2 seconds') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'productos', v_prod, 'equivalencias', v_equiv, 'proveedores', v_prov,
    'personal', v_pers, 'impresoras', v_impr, 'zonas', v_zonas);
end;
$function$
