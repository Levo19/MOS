-- 165_mos_provprod_update_sin_idprov.sql — [CUTOVER ESCRITURA · proveedores_productos]
-- FIX: mos.upsert_proveedor_producto exigía idProveedor SIEMPRE (línea 446 del 81), incluso para un
--   UPDATE-por-idPP donde el front solo manda {idPP, precioReferencia, ...} (paridad actualizarProductoProveedor
--   de GAS, que NO requiere idProveedor para editar). Eso hacía que el gate GAS directo-puro de
--   actualizarProductoProveedor cayera SIEMPRE a la HOJA → no delete-safe para ediciones.
--
-- CAMBIO MÍNIMO Y SEGURO: mover la exigencia de idProveedor a DESPUÉS de resolver el target del upsert.
--   · UPDATE (target resuelto por idPP existente, o por prov+sku): NO exige idProveedor.
--   · INSERT (no hay target): SIGUE exigiendo idProveedor (no se puede crear una fila sin proveedor).
-- El resto del cuerpo es IDÉNTICO al 81 (idempotencia local_id/PK, patch parcial, grants). Re-crea la fn.
-- Idempotente: create or replace. No cambia ninguna semántica de creación; solo habilita el update sin idProveedor.

create or replace function mos.upsert_proveedor_producto(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_idpp  text := nullif(btrim(coalesce(p->>'idPP','')), '');
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_cod   text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');   -- texto SIEMPRE
  v_target text;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PROVPROD_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PROVPROD_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- IDEMPOTENCIA por local_id (gesto de creación): ya existe → dedup.
  if v_local is not null then
    select id_pp into v_existe from mos.proveedores_productos where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_existe, 'accion','existente')); end if;
  end if;

  -- Resolver el target del upsert: idPP explícito → por (prov+sku) → ninguno (insert).
  if v_idpp is not null and exists (select 1 from mos.proveedores_productos where id_pp = v_idpp) then
    v_target := v_idpp;
  elsif v_prov is not null and v_sku is not null then
    select id_pp into v_target from mos.proveedores_productos
      where id_proveedor = v_prov and sku_base = v_sku limit 1;
  end if;

  -- ── UPDATE (patch parcial, paridad actualizarProductoProveedor) — NO exige idProveedor ──────────────
  if v_target is not null then
    update mos.proveedores_productos t set
      sku_base            = case when p ? 'skuBase'          then nullif(btrim(coalesce(p->>'skuBase','')),'')          else t.sku_base end,
      codigo_barra        = case when p ? 'codigoBarra'      then nullif(btrim(coalesce(p->>'codigoBarra','')),'')      else t.codigo_barra end,
      descripcion         = case when p ? 'descripcion'      then nullif(btrim(coalesce(p->>'descripcion','')),'')      else t.descripcion end,
      precio_referencia   = case when p ? 'precioReferencia' then coalesce(mos._numn(p->>'precioReferencia'),0)         else t.precio_referencia end,
      minimo_compra       = case when p ? 'minimoCompra'     then coalesce(mos._numn(p->>'minimoCompra'),0)             else t.minimo_compra end,
      dias_entrega        = case when p ? 'diasEntrega'      then coalesce(mos._numn(p->>'diasEntrega'),0)              else t.dias_entrega end,
      activa              = case when p ? 'activa'           then ((p->>'activa') not in ('false','0','f'))             else t.activa end,
      notas               = case when p ? 'notas'            then nullif(btrim(coalesce(p->>'notas','')),'')            else t.notas end,
      unidades_por_bulto  = case when p ? 'unidadesPorBulto' then coalesce(mos._numn(p->>'unidadesPorBulto'),1)         else t.unidades_por_bulto end,
      ultima_actualizacion = now()
    where id_pp = v_target;
    return jsonb_build_object('ok',true,'data', jsonb_build_object('idPP', v_target, 'accion','actualizado'));
  end if;

  -- ── INSERT (paridad agregarProductoProveedor) — AQUÍ SÍ exige idProveedor + skuBase ──────────────────
  if v_prov is null then return jsonb_build_object('ok',false,'error','idProveedor requerido'); end if;
  if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;

  v_idpp := coalesce(v_idpp, 'PP'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.proveedores_productos (
    id_pp, id_proveedor, sku_base, codigo_barra, descripcion, precio_referencia, minimo_compra,
    dias_entrega, ultima_actualizacion, activa, notas, unidades_por_bulto, local_id
  ) values (
    v_idpp, v_prov, v_sku, v_cod,
    nullif(btrim(coalesce(p->>'descripcion','')),''),
    coalesce(mos._numn(p->>'precioReferencia'),0),
    coalesce(mos._numn(p->>'minimoCompra'),0),
    coalesce(mos._numn(p->>'diasEntrega'),0),
    now(),
    case when p ? 'activa' then ((p->>'activa') not in ('false','0','f')) else true end,
    nullif(btrim(coalesce(p->>'notas','')),''),
    coalesce(mos._numn(p->>'unidadesPorBulto'),1),
    v_local
  )
  on conflict (id_pp) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    if v_local is not null then
      select id_pp into v_existe from mos.proveedores_productos where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_existe, 'accion','existente')); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_idpp, 'accion','existente'));
  end if;

  return jsonb_build_object('ok',true,'data', jsonb_build_object('idPP', v_idpp, 'accion','creado'));
exception
  when unique_violation then
    if v_local is not null then
      select id_pp into v_existe from mos.proveedores_productos where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_existe, 'accion','existente')); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_idpp, 'accion','existente'));
end;
$fn$;
revoke all on function mos.upsert_proveedor_producto(jsonb) from public;
grant execute on function mos.upsert_proveedor_producto(jsonb) to service_role, authenticated;
