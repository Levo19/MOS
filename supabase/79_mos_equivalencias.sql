-- 79_mos_equivalencias.sql — [MIGRACIÓN MOS · FASE 2 · LOTE CATÁLOGO] Escritura directa de EQUIVALENCIAS.
-- Espeja crearEquivalencia / actualizarEquivalencia (gas/Productos.gs) sobre mos.equivalencias.
--
-- ⚠️ INERTE: gateada por el MISMO flag mos.config.MOS_CATALOGO_DIRECTO (sembrado en 78) y por mos._claim_ok().
--    Sin cablear js/api.js, nadie las llama → MOS sigue 100% por GAS.
--
-- ── MODELO (memoria architecture_wh_codigos_canonico_equivalente · regla en piedra) ─────────────────────
--   Una equivalencia liga un codigo_barra a un sku_base (canónico). El catálogo de WH solo matchea EQUIVALENTES
--   ACTIVOS (activo=true). crearEquivalencia nace activa ('1' en GAS → boolean true acá). NO hay factor en
--   mos.equivalencias (el factor vive en mos.productos para presentaciones; las equivalencias son alias de código).
--
-- ── IDEMPOTENCIA ─────────────────────────────────────────────────────────────────────────────────────────
--   crear: la PWA puede mandar id_equiv (lo obtiene de la 1ra respuesta) → insert on conflict (id_equiv) do nothing.
--     Si no viene, se genera 'EQ'+epoch_ms (espeja _generateId('EQ') de GAS). Dedup defensivo adicional:
--     (sku_base, codigo_barra) activos ya existentes → no recrea (evita duplicar la misma equivalencia activa).
--   actualizar: UPDATE atómico por PK id_equiv (idempotente: re-aplicar el mismo valor = no-op).

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.crear_equivalencia(p jsonb) — espeja crearEquivalencia
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.crear_equivalencia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'idEquiv','')), '');
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_cod  text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');   -- texto SIEMPRE
  v_desc text := nullif(btrim(coalesce(p->>'descripcion','')), '');
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_sku is null or v_cod is null then
    return jsonb_build_object('ok',false,'error','Requiere skuBase y codigoBarra');
  end if;

  -- idempotencia por id si vino y ya existe
  if v_id is not null and exists (select 1 from mos.equivalencias where id_equiv = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEquiv', v_id));
  end if;

  -- dedup defensivo: misma (sku_base, codigo_barra) ya ACTIVA → no recrear
  select id_equiv into v_existe from mos.equivalencias
    where upper(coalesce(sku_base,'')) = upper(v_sku) and btrim(coalesce(codigo_barra,'')) = v_cod
      and activo = true limit 1;
  if found then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEquiv', v_existe));
  end if;

  v_id := coalesce(v_id, 'EQ'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.equivalencias (id_equiv, sku_base, codigo_barra, descripcion, activo, created_at)
  values (v_id, v_sku, v_cod, v_desc, true, now())
  on conflict (id_equiv) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEquiv', v_id));
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idEquiv', v_id));
end;
$fn$;

revoke all on function mos.crear_equivalencia(jsonb) from public;
grant execute on function mos.crear_equivalencia(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.actualizar_equivalencia(p jsonb) — espeja actualizarEquivalencia (patch codigoBarra/descripcion/activo)
--   UPDATE atómico por PK id_equiv. codigoBarra SIEMPRE texto. activo acepta '0'/'1' o bool.
--   Paridad GAS: solo se tocan los campos presentes en el patch (codigoBarra/descripcion/activo).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.actualizar_equivalencia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idEquiv','')), '');
  v_n  int;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idEquiv'); end if;

  update mos.equivalencias t set
    codigo_barra = case when p ? 'codigoBarra' then nullif(btrim(coalesce(p->>'codigoBarra','')),'') else t.codigo_barra end,
    descripcion  = case when p ? 'descripcion' then nullif(btrim(coalesce(p->>'descripcion','')),'') else t.descripcion end,
    activo       = case when p ? 'activo' then ((p->>'activo') in ('1','true','t')) else t.activo end
  where id_equiv = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Equivalencia no encontrada: '||v_id); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

revoke all on function mos.actualizar_equivalencia(jsonb) from public;
grant execute on function mos.actualizar_equivalencia(jsonb) to service_role, authenticated;
