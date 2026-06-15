-- 48_mos_catalogo_wh_rls.sql — [PASO 5 · B3/B4 backend] Catálogo (productos+equivalencias) para WH directo.
-- Reemplaza la parte central de descargarMaestros (hoy vía GAS). Devuelve filas CRUDAS (snake_case); el FRONT
-- mapea a shape-hoja con _CAT_SPECS invertido (bools → '1'/'0' vía tipo 'bool10', porque el front compara
-- p.estado!=='0' / String(p.esEnvasable)==='1' / _esActivoEquiv(activo) — NUNCA true/false).
-- Filtros = los de descargarMaestros: productos TODOS; equivalencias solo activas. Gate wh._claim_ok().
-- security definer: corre como owner (lee schema mos). El uso por-operación (enriquecer) es contra el cache local;
-- esta RPC es solo para la DESCARGA periódica del catálogo (offline-first preservado).

create or replace function mos.catalogo_wh_rls()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prod jsonb;
  v_equiv jsonb;
  v_prov jsonb;
  v_pers jsonb;
  v_impr jsonb;
  v_zonas jsonb;
begin
  if not wh._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- Filtros = los de descargarMaestros (WH). Bools (estado/activo) van CRUDOS (boolean) → el front mapea a '1'/'0'.
  -- adminPin NO se incluye: es el PIN dinámico 4+4 (reabrir guía va por mos.verificar_clave_admin). estaciones tampoco (solo servía al adminPin).
  select coalesce(jsonb_agg(to_jsonb(t) order by t.id_producto), '[]'::jsonb) into v_prod
    from mos.productos t;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.id_equiv), '[]'::jsonb) into v_equiv
    from mos.equivalencias e where e.activo = true;                 -- solo activas
  -- ⚠ SEGURIDAD: excluir datos bancarios (numero_cuenta/cci) — WH no los necesita para operar.
  select coalesce(jsonb_agg((to_jsonb(p) - 'numero_cuenta' - 'cci') order by p.id_proveedor), '[]'::jsonb) into v_prov
    from mos.proveedores p;                                          -- todos
  -- ⚠ SEGURIDAD: excluir pin y pin_hash del personal (NUNCA exponer PINs al navegador).
  select coalesce(jsonb_agg((to_jsonb(p) - 'pin' - 'pin_hash') order by p.id_personal), '[]'::jsonb) into v_pers
    from mos.personal p where p.estado = true;                       -- activos (String(estado)==='1')
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id_impresora), '[]'::jsonb) into v_impr
    from mos.impresoras i where lower(coalesce(i.app_origen,'')) = 'warehousemos' and i.activo = true;
  select coalesce(jsonb_agg(to_jsonb(z) order by z.id_zona), '[]'::jsonb) into v_zonas
    from mos.zonas z where z.estado = true;                          -- activas
  return jsonb_build_object('ok', true,
    'productos', v_prod, 'equivalencias', v_equiv, 'proveedores', v_prov,
    'personal', v_pers, 'impresoras', v_impr, 'zonas', v_zonas);
end;
$fn$;

revoke all on function mos.catalogo_wh_rls() from public;
grant execute on function mos.catalogo_wh_rls() to service_role, authenticated;
