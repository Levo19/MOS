-- ════════════════════════════════════════════════════════════════════════════
-- 369 · NIVEL 1 corte-GAS (MOS) — promociones. Tabla mos.promociones (sombra de
-- PROMOCIONES) + mos.crear_promocion / mos.actualizar_promocion (espejo de
-- Promociones.gs). Gate mos._claim_ok(). Conversión TOTAL→UNITARIO idéntica al GAS.
-- NOTA: el WRITE queda cero-GAS. Servir las promos al POS (catalogo_pos_rls hoy
-- devuelve PROMOCIONES:[]) + migrar las promos existentes del sheet = follow-up.
-- ════════════════════════════════════════════════════════════════════════════

create table if not exists mos.promociones (
  id_promo       text primary key,
  sku_base       text,
  tipo_promo     text,
  cant_min       numeric,
  valor_promo    numeric,
  valor_modo     text,
  descripcion    text,
  vigencia_desde text,
  vigencia_hasta text,
  activa         boolean default true,
  notas          text,
  items_json     jsonb,
  updated_at     timestamptz default now()
);
create index if not exists ix_mos_promo_sku on mos.promociones (sku_base);

create or replace function mos.crear_promocion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_tipo text := upper(coalesce(p->>'tipo',''));
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_modo text := upper(coalesce(p->>'valorModo','UNITARIO'));
  v_valor numeric := coalesce(nullif(btrim(coalesce(p->>'valorPromo','')),'')::numeric, 0);
  v_cmin  numeric := coalesce(nullif(btrim(coalesce(p->>'cantMin','')),'')::numeric, 0);
  v_id text := nullif(btrim(coalesce(p->>'idPromo','')),'');
  v_items jsonb := p->'items';
  v_exist text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_tipo not in ('GRUPO','PORCENTAJE','COMBO') then return jsonb_build_object('ok',false,'error','tipo debe ser GRUPO, PORCENTAJE o COMBO'); end if;
  if v_tipo = 'COMBO' then
    if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
      return jsonb_build_object('ok',false,'error','COMBO requiere lista de items');
    end if;
  else
    if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;
  end if;
  -- Conversión TOTAL→UNITARIO (solo GRUPO).
  if v_tipo = 'GRUPO' and v_modo = 'TOTAL' and v_cmin > 0 and v_valor > 0 then v_valor := v_valor / v_cmin; end if;

  -- GRUPO/PORCENTAJE: si ya existe una promo con ese SKU → reemplazar (upsert por sku).
  if v_tipo <> 'COMBO' then
    select id_promo into v_exist from mos.promociones where sku_base = v_sku limit 1;
    if v_exist is not null then v_id := v_exist; end if;
  end if;
  if v_id is null then v_id := 'PROMO' || (extract(epoch from clock_timestamp())*1000)::bigint; end if;

  insert into mos.promociones (id_promo, sku_base, tipo_promo, cant_min, valor_promo, valor_modo,
    descripcion, vigencia_desde, vigencia_hasta, activa, notas, items_json, updated_at)
  values (v_id, case when v_tipo='COMBO' then null else v_sku end, v_tipo, v_cmin, v_valor, v_modo,
    coalesce(p->>'descripcion',''), coalesce(p->>'vigenciaDesde',''), coalesce(p->>'vigenciaHasta',''),
    not (coalesce(p->>'activa','true') = 'false'), coalesce(p->>'notas',''),
    case when v_tipo='COMBO' then coalesce(v_items,'[]'::jsonb) else null end, now())
  on conflict (id_promo) do update set sku_base=excluded.sku_base, tipo_promo=excluded.tipo_promo,
    cant_min=excluded.cant_min, valor_promo=excluded.valor_promo, valor_modo=excluded.valor_modo,
    descripcion=excluded.descripcion, vigencia_desde=excluded.vigencia_desde, vigencia_hasta=excluded.vigencia_hasta,
    activa=excluded.activa, notas=excluded.notas, items_json=excluded.items_json, updated_at=now();
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPromo',v_id,'skuBase',v_sku,'tipo',v_tipo));
end; $fn$;

create or replace function mos.actualizar_promocion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'idPromo','')),'');
  v_sku text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_row mos.promociones%rowtype;
  v_tipo text; v_modo text; v_cmin numeric; v_valor numeric;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null and v_sku is null then return jsonb_build_object('ok',false,'error','idPromo o skuBase requerido'); end if;
  select * into v_row from mos.promociones where (v_id is not null and id_promo = v_id) or (v_id is null and sku_base = v_sku) limit 1;
  if not found then return jsonb_build_object('ok',false,'error','Promoción no encontrada'); end if;

  v_tipo := upper(coalesce(nullif(p->>'tipo',''), v_row.tipo_promo));
  v_modo := upper(coalesce(p->>'valorModo','UNITARIO'));
  v_cmin := coalesce(nullif(btrim(coalesce(p->>'cantMin','')),'')::numeric, v_row.cant_min);
  if (p ? 'valorPromo') then
    v_valor := coalesce(nullif(btrim(coalesce(p->>'valorPromo','')),'')::numeric, 0);
    if v_tipo = 'GRUPO' and v_modo = 'TOTAL' and coalesce(v_cmin,0) > 0 and v_valor > 0 then v_valor := v_valor / v_cmin; end if;
  else v_valor := v_row.valor_promo; end if;

  update mos.promociones set
    tipo_promo     = case when (p ? 'tipo') then v_tipo else tipo_promo end,
    sku_base       = case when (p ? 'skuBase') then v_sku else sku_base end,
    cant_min       = v_cmin,
    valor_promo    = v_valor,
    valor_modo     = case when (p ? 'valorModo') then v_modo else valor_modo end,
    descripcion    = coalesce(p->>'descripcion', descripcion),
    vigencia_desde = coalesce(p->>'vigenciaDesde', vigencia_desde),
    vigencia_hasta = coalesce(p->>'vigenciaHasta', vigencia_hasta),
    activa         = case when (p ? 'activa') then not (coalesce(p->>'activa','true')='false') else activa end,
    notas          = coalesce(p->>'notas', notas),
    items_json     = case when (p ? 'items') then coalesce(p->'items','[]'::jsonb) else items_json end,
    updated_at     = now()
   where id_promo = v_row.id_promo;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPromo',v_row.id_promo,'skuBase',coalesce(v_sku,v_row.sku_base)));
end; $fn$;

revoke all on function mos.crear_promocion(jsonb), mos.actualizar_promocion(jsonb) from public, anon;
grant execute on function mos.crear_promocion(jsonb), mos.actualizar_promocion(jsonb) to authenticated, service_role;
