-- ════════════════════════════════════════════════════════════════════════════
-- 248 · REPARACIÓN #7 — mos.eliminar_items_catalogo: purga de catálogo 100% Supabase
-- ════════════════════════════════════════════════════════════════════════════
-- SÍNTOMA: el master borra un producto del catálogo → "procesando" eterno → "⚠ Lock timeout"
-- y el producto NUNCA se borra. CAUSA: el borrado era 100% GAS (PurgaCatalogo.gs) bajo
-- LockService.waitLock(15000); el doc-lock de GAS (sync horario + concurrencia) excedía 15s → timeout.
--
-- FIX: port fiel de PurgaCatalogo.gs::eliminarItemsCatalogo a una RPC atómica de Postgres
-- (transacción = sin LockService, row-locks nativos, instantáneo). Mantiene: validación de items,
-- verificación de clave admin + rol MASTER, chequeo de INTEGRIDAD (no dejar canónico sin sus
-- presentaciones/equivalentes), snapshot de auditoría, y bump de catalogo_version.
--
-- TOMBSTONE (clave para que sea 100% Supabase-autoritativo): el sync Hoja→Supabase
-- (migrarCatalogoCompartido) es SOLO-UPSERT (no borra) → si borro en Supabase pero la Hoja
-- conserva la fila, el próximo sync RESUCITA el producto. Por eso registramos cada id borrado en
-- mos.purgas_historicas (= lápida); el sync se parchea (GAS) para NO re-upsertear ids con lápida.
-- Así Supabase MANDA sobre la Hoja y el borrado nunca revive, sin depender de borrar la Hoja.
-- ════════════════════════════════════════════════════════════════════════════

-- ── Tabla de auditoría + TOMBSTONE ──────────────────────────────────────────
create table if not exists mos.purgas_historicas (
  id                  bigint generated always as identity primary key,
  fecha               timestamptz not null default now(),
  id_lote             text not null,
  id_personal_master  text,
  nombre_master       text,
  tabla               text not null,     -- 'mos.productos' | 'mos.equivalencias'
  id_fila             text not null,     -- id_producto | id_equiv  (= clave de lápida)
  sku_base            text,
  codigo_barra        text,
  descripcion         text,
  snapshot_json       jsonb,
  detalle             text
);
-- Índice de lápida: el sync consulta (tabla,id_fila) para saltar ids purgados.
create index if not exists ix_purgas_tombstone on mos.purgas_historicas (tabla, id_fila);

revoke all on table mos.purgas_historicas from anon;
grant select, insert on table mos.purgas_historicas to authenticated, service_role;
grant usage, select on all sequences in schema mos to authenticated, service_role;

-- ── RPC de purga ────────────────────────────────────────────────────────────
create or replace function mos.eliminar_items_catalogo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_items   jsonb := coalesce(p->'items','[]'::jsonb);
  v_clave   text  := coalesce(p->>'claveAdmin','');
  v_app     text  := coalesce(p->>'appOrigen','MOS');
  v_device  text  := coalesce(p->>'deviceId','');
  v_detalle text  := coalesce(p->>'detalle','');
  v_auth    jsonb;
  v_rol     text;
  v_idp     text;
  v_nom     text;
  v_it      jsonb;
  v_id      text;
  v_tipo    text;
  v_pm_ids  text[] := '{}';   -- ids de PRODUCTOS_MASTER a borrar (canónico + presentación)
  v_eq_ids  text[] := '{}';   -- ids de EQUIVALENCIAS a borrar
  v_pres_h  text[] := '{}';
  v_eq_h    text[] := '{}';
  v_huerf   text[] := '{}';
  v_noenc   text[] := '{}';
  v_idlote  text;
  v_elim_pm int := 0;
  v_elim_eq int := 0;
begin
  -- 1) Validar payload
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Requiere items[]');
  end if;
  if v_clave = '' then
    return jsonb_build_object('ok', false, 'error', 'Requiere claveAdmin (8 dígitos)');
  end if;

  -- Validar + clasificar cada item (mismo contrato que PurgaCatalogo.gs)
  for v_it in select * from jsonb_array_elements(v_items) loop
    v_id   := coalesce(v_it->>'id', '');
    v_tipo := upper(coalesce(v_it->>'tipo', ''));
    if v_id = '' then
      return jsonb_build_object('ok', false, 'error', 'Item sin id');
    end if;
    if v_tipo not in ('CANONICO','PRESENTACION','EQUIVALENTE') then
      return jsonb_build_object('ok', false, 'error', 'Item tipo inválido: ' || coalesce(v_it->>'tipo',''));
    end if;
    if v_tipo in ('CANONICO','PRESENTACION') then
      v_pm_ids := v_pm_ids || v_id;
    else
      v_eq_ids := v_eq_ids || v_id;
    end if;
  end loop;

  -- 2) Verificar clave (tier seguridad) + enforce rol MASTER explícito
  v_auth := mos.verificar_clave_admin(
    v_clave, 'PURGAR_CATALOGO', jsonb_array_length(v_items) || ' items',
    v_app, v_device, v_detalle, null, null);
  if not coalesce((v_auth->>'ok')::boolean, false) then
    return v_auth;  -- propaga el error de la verificación
  end if;
  if not coalesce((v_auth->>'autorizado')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', coalesce(v_auth->>'error', 'No autorizado'));
  end if;
  v_rol := upper(coalesce(v_auth->>'rol', ''));
  if v_rol <> 'MASTER' then
    return jsonb_build_object('ok', false,
      'error', 'Solo MASTER puede ejecutar esta acción. Tu rol: ' || coalesce(v_auth->>'rol',''));
  end if;
  v_idp := coalesce(v_auth->>'id_personal', '');
  v_nom := coalesce(v_auth->>'nombre', '');

  -- 3) INTEGRIDAD: por cada canónico (factor_conversion=1) del batch, sus presentaciones
  --    (mismo sku_base, factor<>1) y equivalentes (mismo sku_base) DEBEN estar incluidos.
  select coalesce(array_agg(p2.id_producto || ' (presentación de ' || can.id_producto || ')'), '{}')
    into v_pres_h
  from mos.productos can
  join mos.productos p2
    on p2.sku_base = can.sku_base
   and p2.id_producto <> can.id_producto
   and coalesce(p2.factor_conversion, 1) <> 1
  where can.id_producto = any(v_pm_ids)
    and coalesce(can.factor_conversion, 1) = 1
    and not (p2.id_producto = any(v_pm_ids));

  select coalesce(array_agg(e2.id_equiv || ' (equivalente de ' || can.sku_base || ')'), '{}')
    into v_eq_h
  from mos.productos can
  join mos.equivalencias e2
    on e2.sku_base = can.sku_base
  where can.id_producto = any(v_pm_ids)
    and coalesce(can.factor_conversion, 1) = 1
    and not (e2.id_equiv = any(v_eq_ids));

  v_huerf := v_pres_h || v_eq_h;
  if array_length(v_huerf, 1) > 0 then
    return jsonb_build_object('ok', false, 'codigo', 'INTEGRIDAD',
      'error', 'Si eliminas el canónico debes incluir también sus presentaciones/equivalentes ('
               || array_length(v_huerf, 1) || ' huérfanos)',
      'huerfanos', to_jsonb(v_huerf));
  end if;

  -- 4) ids no encontrados (no existen en la sombra) — informativo, no bloquea
  select coalesce(array_agg(x), '{}') into v_noenc from (
    (select unnest(v_pm_ids) x
       except select id_producto from mos.productos where id_producto = any(v_pm_ids))
    union all
    (select unnest(v_eq_ids) x
       except select id_equiv from mos.equivalencias where id_equiv = any(v_eq_ids))
  ) s;

  -- 5) Snapshot de auditoría + LÁPIDA (antes de borrar) — sobrevive resurrecciones del sync.
  v_idlote := 'PRG-' || (extract(epoch from clock_timestamp()) * 1000)::bigint;
  insert into mos.purgas_historicas
    (id_lote, id_personal_master, nombre_master, tabla, id_fila, sku_base, codigo_barra, descripcion, snapshot_json, detalle)
  select v_idlote, v_idp, v_nom, 'mos.productos', pr.id_producto, pr.sku_base, pr.codigo_barra, pr.descripcion,
         to_jsonb(pr.*), v_detalle
  from mos.productos pr where pr.id_producto = any(v_pm_ids);

  insert into mos.purgas_historicas
    (id_lote, id_personal_master, nombre_master, tabla, id_fila, sku_base, codigo_barra, descripcion, snapshot_json, detalle)
  select v_idlote, v_idp, v_nom, 'mos.equivalencias', eq.id_equiv, eq.sku_base, eq.codigo_barra, eq.descripcion,
         to_jsonb(eq.*), v_detalle
  from mos.equivalencias eq where eq.id_equiv = any(v_eq_ids);

  -- 6) Borrado atómico (la función ES la transacción; si algo falla, rollback total)
  with d as (delete from mos.productos where id_producto = any(v_pm_ids) returning 1)
  select count(*)::int into v_elim_pm from d;
  with d as (delete from mos.equivalencias where id_equiv = any(v_eq_ids) returning 1)
  select count(*)::int into v_elim_eq from d;

  -- 7) Bump de versión del catálogo → ME/MOS/WH re-jalan y dejan de ver el producto.
  update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idLote', v_idlote,
    'eliminadosProductos', v_elim_pm,
    'eliminadosEquivs', v_elim_eq,
    'idsNoEncontrados', to_jsonb(v_noenc),
    'timestamp', now()
  ));
end;
$fn$;

revoke all on function mos.eliminar_items_catalogo(jsonb) from public, anon;
grant execute on function mos.eliminar_items_catalogo(jsonb) to authenticated, service_role;

-- ── Helper de LÁPIDAS para el sync (GAS lo consume para NO resucitar) ────────
-- Devuelve el set de ids purgados de una tabla. El sync Hoja→Supabase salta estos ids.
create or replace function mos.purga_tombstones(p_tabla text)
returns setof text language sql stable security definer set search_path = '' as $fn$
  select distinct id_fila from mos.purgas_historicas where tabla = p_tabla;
$fn$;
revoke all on function mos.purga_tombstones(text) from public;
grant execute on function mos.purga_tombstones(text) to anon, authenticated, service_role;

-- Flag de cutover (server-side, vía me/mos get_flags). 0 = GAS (actual), 1 = Supabase directo.
insert into mos.config (clave, valor, descripcion) values
  ('MOS_PURGA_DIRECTO','0','MOS: purga de catálogo directa a Supabase (mos.eliminar_items_catalogo) en vez de GAS. 0=GAS, 1=Supabase.')
on conflict (clave) do nothing;

notify pgrst, 'reload schema';
