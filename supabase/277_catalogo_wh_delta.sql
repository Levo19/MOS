-- 277_catalogo_wh_delta.sql — Descarga INCREMENTAL del catálogo WH (cero re-descargas de 1.9MB).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- CAUSA RAÍZ de la lentitud de WH: cada bump de catalogo_version re-descargaba ~1.9MB completos. El
-- coalescing (front 2.13.354) ya agrupa la ráfaga a 1 descarga; este delta hace que ESA descarga traiga
-- SOLO las filas de productos cambiadas desde la última sync (KB en vez de MB). Las tablas chicas
-- (equivalencias/proveedores/personal/impresoras/zonas) viajan completas (son ~50KB juntas y cambian poco).
--
-- (1) Trigger BEFORE UPDATE en mos.productos → updated_at=now() en CADA cambio (hoy no era confiable: no
--     había trigger). Así el delta por updated_at es exacto. (2) RPC mos.catalogo_wh_delta(desde_ts).
-- (3) server_ts en catalogo_wh_rls (el full) para que el front guarde el punto de corte.
-- Money/fiscal-neutro (catálogo, no dinero). Additivo: el full sigue igual (fallback). Mismas exclusiones
-- de seguridad (sin pin/pin_hash/numero_cuenta/cci) y proyección (sin created_at/updated_at en productos).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

-- (1) updated_at confiable en mos.productos (INSERT y UPDATE → un alta también entra al delta).
create or replace function mos._touch_updated_at() returns trigger language plpgsql as $fn$
begin
  new.updated_at := now();
  return new;
end;
$fn$;
drop trigger if exists tg_touch_updated_at on mos.productos;
create trigger tg_touch_updated_at before insert or update on mos.productos
  for each row execute function mos._touch_updated_at();

-- (1b) [500x HIGH] TOMBSTONES de borrados: un DELETE de producto NO viaja por updated_at (la fila ya no
-- existe) → el delta nunca lo quitaría del cache local (quedaría vendible/despachable con datos viejos).
-- Registramos el id borrado; el delta devuelve los borrados-desde-corte y el front los saca del cache.
create table if not exists mos.catalogo_tombstones (
  id_producto text primary key,
  deleted_at  timestamptz not null default now()
);
create or replace function mos._tombstone_producto() returns trigger language plpgsql as $fn$
begin
  insert into mos.catalogo_tombstones(id_producto, deleted_at) values (old.id_producto, now())
    on conflict (id_producto) do update set deleted_at = now();
  return old;
end;
$fn$;
drop trigger if exists tg_tombstone_producto on mos.productos;
create trigger tg_tombstone_producto after delete on mos.productos
  for each row execute function mos._tombstone_producto();

-- (3) server_ts en el FULL (para que el front fije el punto de corte del delta)
create or replace function mos.catalogo_wh_rls()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
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
$function$;

-- (2) DELTA: solo productos cambiados desde desde_ts; tablas chicas completas. server_ts = nuevo corte.
create or replace function mos.catalogo_wh_delta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
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
$function$;

revoke all on function mos.catalogo_wh_delta(jsonb) from public;
grant execute on function mos.catalogo_wh_delta(jsonb) to authenticated;
notify pgrst, 'reload schema';
