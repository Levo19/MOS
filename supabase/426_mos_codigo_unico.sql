-- ============================================================
-- 426 · Unicidad de código de barras CRUZADA productos ↔ equivalencias (catálogo v4)
-- ============================================================
-- GAP confirmado (dibujo v4 §09): prodValidarCodigoBarra (front) y crear_producto (SQL 78)
-- solo validan contra mos.productos; crear_equivalencia (SQL 79) solo contra equivalencias.
-- Con códigos autogenerados N-/WH-/P- y escáner en todos los casilleros, un código puede
-- chocar CRUZADO (producto nuevo con cb que ya es equivalente de otro, o viceversa).
--
-- Diseño:
--  1) RPC mos.codigo_barra_disponible — consulta única para el front (feedback en vivo).
--  2) Triggers de guardia en AMBAS tablas — la verdad CRUZADA la impone la BD, no la UI.
--     · Alcance: SOLO producto↔equivalencia (el duplicado producto↔producto sigue siendo
--       responsabilidad del RPC crear_producto + validación front, como hoy).
--     · Solo validan filas NUEVAS o con cb/sku_base CAMBIADO (historia con colisiones no bloquea).
--     · Permiten cb repetido DENTRO del mismo grupo (sku_base igual) — redundancia inocua.
--     · Backfills/scripts masivos: bypass por GUC de sesión
--         select set_config('mos.skip_cb_guard','1', false);
--       (documentar en el runbook del backfill; evita abortos por 1 colisión histórica y
--       el agotamiento de la lock table por N advisory locks en una sola tx).
-- Directriz: CERO GAS.
-- ============================================================

-- 1) RPC de consulta (para validación en vivo en los 5 modales)
create or replace function mos.codigo_barra_disponible(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_cb   text := upper(btrim(coalesce(p->>'codigoBarra','')));
  v_ign_prod  text := nullif(btrim(coalesce(p->>'ignorarIdProducto','')),'');
  v_ign_equiv text := nullif(btrim(coalesce(p->>'ignorarIdEquiv','')),'');
  v_row record;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_cb = '' then return jsonb_build_object('ok',true,'disponible',false,'motivo','VACIO'); end if;

  select pr.id_producto as id, pr.descripcion into v_row
  from mos.productos pr
  where upper(btrim(coalesce(pr.codigo_barra,''))) = v_cb
    and (v_ign_prod is null or pr.id_producto <> v_ign_prod)
  limit 1;
  if found then
    return jsonb_build_object('ok',true,'disponible',false,
      'conflicto', jsonb_build_object('tipo','producto','id',v_row.id,'descripcion',v_row.descripcion));
  end if;

  select e.id_equiv as id, coalesce(e.descripcion, e.sku_base) as descripcion into v_row
  from mos.equivalencias e
  where e.activo
    and upper(btrim(coalesce(e.codigo_barra,''))) = v_cb
    and (v_ign_equiv is null or e.id_equiv <> v_ign_equiv)
  limit 1;
  if found then
    return jsonb_build_object('ok',true,'disponible',false,
      'conflicto', jsonb_build_object('tipo','equivalencia','id',v_row.id,'descripcion',v_row.descripcion));
  end if;

  return jsonb_build_object('ok',true,'disponible',true);
end; $fn$;

revoke all on function mos.codigo_barra_disponible(jsonb) from public, anon;
grant execute on function mos.codigo_barra_disponible(jsonb) to authenticated, service_role;

-- 2) Guardia en mos.productos: cb nuevo/cambiado no puede ser equivalente ACTIVO de OTRO grupo
create or replace function mos._tg_producto_cb_unico()
returns trigger language plpgsql security definer set search_path='' as $fn$
declare v_eq record; v_sku text;
begin
  -- [rev M4] bypass para backfills/scripts masivos (runbook)
  if coalesce(current_setting('mos.skip_cb_guard', true),'') = '1' then return new; end if;
  if coalesce(btrim(new.codigo_barra),'') = '' then return new; end if;
  if tg_op = 'UPDATE'
     and coalesce(btrim(old.codigo_barra),'') = coalesce(btrim(new.codigo_barra),'')
     and coalesce(btrim(old.sku_base),'') = coalesce(btrim(new.sku_base),'') then
    return new;  -- ni cb ni grupo cambiaron: no re-validar historia
  end if;
  -- serializar validaciones cruzadas del MISMO código (carrera producto↔equivalencia concurrentes)
  perform pg_advisory_xact_lock(hashtext('cb_unico:' || upper(btrim(new.codigo_barra))));
  v_sku := coalesce(nullif(btrim(new.sku_base),''), new.id_producto);
  select e.id_equiv, e.sku_base into v_eq
  from mos.equivalencias e
  where e.activo
    and upper(btrim(coalesce(e.codigo_barra,''))) = upper(btrim(new.codigo_barra))
    and coalesce(e.sku_base,'') <> coalesce(v_sku,'')
  limit 1;
  if found then
    raise exception 'CODIGO_EN_EQUIVALENCIAS: % ya es equivalente del grupo % (id_equiv %)',
      new.codigo_barra, v_eq.sku_base, v_eq.id_equiv;
  end if;
  return new;
end; $fn$;

drop trigger if exists tg_producto_cb_unico on mos.productos;
create trigger tg_producto_cb_unico
  before insert or update of codigo_barra, sku_base on mos.productos
  for each row execute function mos._tg_producto_cb_unico();

-- 3) Guardia en mos.equivalencias: cb activo nuevo/cambiado no puede ser codigo_barra de un
--    PRODUCTO de OTRO grupo (apuntar a un código que ya es producto real = error de registro)
create or replace function mos._tg_equiv_cb_unico()
returns trigger language plpgsql security definer set search_path='' as $fn$
declare v_pr record;
begin
  -- [rev M4] bypass para backfills/scripts masivos (runbook)
  if coalesce(current_setting('mos.skip_cb_guard', true),'') = '1' then return new; end if;
  if not coalesce(new.activo, true) then return new; end if;         -- desactivar siempre permitido
  if coalesce(btrim(new.codigo_barra),'') = '' then return new; end if;
  if tg_op = 'UPDATE'
     and coalesce(btrim(old.codigo_barra),'') = coalesce(btrim(new.codigo_barra),'')
     and coalesce(btrim(old.sku_base),'') = coalesce(btrim(new.sku_base),'')
     and coalesce(old.activo,true) = coalesce(new.activo,true) then
    return new;
  end if;
  -- mismo lock que _tg_producto_cb_unico: cierra la carrera cruzada
  perform pg_advisory_xact_lock(hashtext('cb_unico:' || upper(btrim(new.codigo_barra))));
  select pr.id_producto, pr.descripcion, coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) as sku
    into v_pr
  from mos.productos pr
  where upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(new.codigo_barra))
    and coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) <> coalesce(new.sku_base,'')
  limit 1;
  if found then
    raise exception 'CODIGO_EN_PRODUCTOS: % ya es el código del producto % (%)',
      new.codigo_barra, v_pr.descripcion, v_pr.id_producto;
  end if;
  return new;
end; $fn$;

drop trigger if exists tg_equiv_cb_unico on mos.equivalencias;
create trigger tg_equiv_cb_unico
  before insert or update of codigo_barra, activo, sku_base on mos.equivalencias
  for each row execute function mos._tg_equiv_cb_unico();
