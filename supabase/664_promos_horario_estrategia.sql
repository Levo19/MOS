-- 664 · PROMOCIONES: horario (⏰ horas valle), estrategia (jugada del playbook) y descartes del radar.
--   · mos.promociones += hora_desde time, hora_hasta time (null = todo el día), estrategia text
--   · crear/actualizar/listar promociones manejan los 3 campos nuevos
--   · mos.promo_descartes: lo que el dueño rechazó del radar (no se le vuelve a insistir por 30 días)
--   (el parche de mos.catalogo_pos_rls para mandar Hora_Desde/Hora_Hasta al POS va en el .mjs,
--    porque se aplica sobre la definición VIVA con pg_get_functiondef)

alter table mos.promociones add column if not exists hora_desde time;
alter table mos.promociones add column if not exists hora_hasta time;
alter table mos.promociones add column if not exists estrategia text;

create table if not exists mos.promo_descartes (
  sku_base   text not null,
  regla      text not null default '',
  descartado_en timestamptz not null default now(),
  por        text not null default '',
  primary key (sku_base, regla)
);

-- ═══ ESCRITURA ═══
create or replace function mos.crear_promocion(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_tipo text := upper(coalesce(p->>'tipo',''));
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_modo text := upper(coalesce(p->>'valorModo','UNITARIO'));
  v_valor numeric := coalesce(nullif(btrim(coalesce(p->>'valorPromo','')),'')::numeric, 0);
  v_cmin  numeric := coalesce(nullif(btrim(coalesce(p->>'cantMin','')),'')::numeric, 0);
  v_id text := nullif(btrim(coalesce(p->>'idPromo','')),'');
  v_items jsonb := p->'items';
  v_hd time := nullif(btrim(coalesce(p->>'horaDesde','')),'')::time;
  v_hh time := nullif(btrim(coalesce(p->>'horaHasta','')),'')::time;
  v_estr text := nullif(btrim(coalesce(p->>'estrategia','')),'');
  v_exist text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_tipo not in ('GRUPO','PORCENTAJE','COMBO') then return jsonb_build_object('ok',false,'error','tipo debe ser GRUPO, PORCENTAJE o COMBO'); end if;
  if v_tipo = 'COMBO' then
    if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
      return jsonb_build_object('ok',false,'error','COMBO requiere lista de items'); end if;
  else
    if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;
  end if;
  -- [fix D5] GRUPO en modo TOTAL sin cantMin>0 no se puede unitarizar → rechazar (evita precio ×cantMin errado).
  if v_tipo = 'GRUPO' and v_modo = 'TOTAL' and coalesce(v_cmin,0) <= 0 then
    return jsonb_build_object('ok',false,'error','GRUPO en modo TOTAL requiere cantMin > 0');
  end if;
  -- [664] ventana horaria: o las dos o ninguna, y desde <> hasta
  if (v_hd is null) <> (v_hh is null) then
    return jsonb_build_object('ok',false,'error','Horario incompleto: define hora de inicio y de fin');
  end if;
  if v_hd is not null and v_hd = v_hh then
    return jsonb_build_object('ok',false,'error','El horario de inicio y fin no pueden ser iguales');
  end if;
  if v_tipo = 'GRUPO' and v_modo = 'TOTAL' and v_valor > 0 then v_valor := v_valor / v_cmin; end if;

  if v_tipo <> 'COMBO' then
    select id_promo into v_exist from mos.promociones where sku_base = v_sku limit 1;
    if v_exist is not null then v_id := v_exist; end if;
  end if;
  if v_id is null then v_id := 'PROMO' || (extract(epoch from clock_timestamp())*1000)::bigint; end if;

  insert into mos.promociones (id_promo, sku_base, tipo_promo, cant_min, valor_promo, valor_modo,
    descripcion, vigencia_desde, vigencia_hasta, activa, notas, items_json,
    hora_desde, hora_hasta, estrategia, updated_at)
  values (v_id, case when v_tipo='COMBO' then null else v_sku end, v_tipo, v_cmin, v_valor, v_modo,
    coalesce(p->>'descripcion',''), coalesce(p->>'vigenciaDesde',''), coalesce(p->>'vigenciaHasta',''),
    not (coalesce(p->>'activa','true') = 'false'), coalesce(p->>'notas',''),
    case when v_tipo='COMBO' then coalesce(v_items,'[]'::jsonb) else null end,
    v_hd, v_hh, v_estr, now())
  on conflict (id_promo) do update set sku_base=excluded.sku_base, tipo_promo=excluded.tipo_promo,
    cant_min=excluded.cant_min, valor_promo=excluded.valor_promo, valor_modo=excluded.valor_modo,
    descripcion=excluded.descripcion, vigencia_desde=excluded.vigencia_desde, vigencia_hasta=excluded.vigencia_hasta,
    activa=excluded.activa, notas=excluded.notas, items_json=excluded.items_json,
    hora_desde=excluded.hora_desde, hora_hasta=excluded.hora_hasta,
    estrategia=coalesce(excluded.estrategia, mos.promociones.estrategia), updated_at=now();

  -- aceptar una sugerencia = el radar ya no la propone (quedó resuelta)
  if v_sku is not null then delete from mos.promo_descartes where sku_base = v_sku; end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPromo',v_id,'skuBase',v_sku,'tipo',v_tipo));
end; $fn$;

create or replace function mos.actualizar_promocion(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'idPromo','')),'');
  v_sku text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_row mos.promociones%rowtype;
  v_tipo text; v_modo text; v_cmin numeric; v_valor numeric;
  v_hd time; v_hh time;
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

  if (p ? 'horaDesde') or (p ? 'horaHasta') then
    v_hd := nullif(btrim(coalesce(p->>'horaDesde','')),'')::time;
    v_hh := nullif(btrim(coalesce(p->>'horaHasta','')),'')::time;
    if (v_hd is null) <> (v_hh is null) then
      return jsonb_build_object('ok',false,'error','Horario incompleto: define hora de inicio y de fin');
    end if;
    if v_hd is not null and v_hd = v_hh then
      return jsonb_build_object('ok',false,'error','El horario de inicio y fin no pueden ser iguales');
    end if;
  else v_hd := v_row.hora_desde; v_hh := v_row.hora_hasta; end if;

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
    hora_desde     = v_hd,
    hora_hasta     = v_hh,
    estrategia     = coalesce(nullif(btrim(coalesce(p->>'estrategia','')),''), estrategia),
    updated_at     = now()
   where id_promo = v_row.id_promo;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPromo',v_row.id_promo,'skuBase',coalesce(v_sku,v_row.sku_base)));
end; $fn$;

-- ═══ LECTURA ═══
create or replace function mos.promociones_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_solo_act boolean := coalesce(nullif(btrim(coalesce(p->>'activa','')),'')::boolean, false); v_data jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'idPromo', id_promo, 'skuBase', sku_base, 'tipo', tipo_promo, 'cantMin', cant_min,
      'valorPromo', valor_promo, 'valorModo', valor_modo,
      'items', coalesce(items_json, '[]'::jsonb),
      'descripcion', descripcion, 'vigenciaDesde', vigencia_desde, 'vigenciaHasta', vigencia_hasta,
      'horaDesde', case when hora_desde is null then null else to_char(hora_desde,'HH24:MI') end,
      'horaHasta', case when hora_hasta is null then null else to_char(hora_hasta,'HH24:MI') end,
      'estrategia', estrategia,
      'actualizado', to_char(updated_at,'YYYY-MM-DD HH24:MI'),
      'activa', coalesce(activa, true), 'notas', notas) order by updated_at desc nulls last, id_promo), '[]'::jsonb)
    into v_data from mos.promociones
   where (not v_solo_act) or coalesce(activa, true) = true;
  return jsonb_build_object('ok',true,'data', v_data);
end; $fn$;

-- ═══ DESCARTES DEL RADAR ═══
create or replace function mos.promo_descartar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_sku text := nullif(btrim(coalesce(p->>'skuBase','')),'');
        v_regla text := upper(coalesce(nullif(btrim(coalesce(p->>'regla','')),''),''));
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;
  insert into mos.promo_descartes (sku_base, regla, descartado_en, por)
  values (v_sku, v_regla, now(), coalesce(p->>'por',''))
  on conflict (sku_base, regla) do update set descartado_en = now(), por = excluded.por;
  return jsonb_build_object('ok',true);
end; $fn$;

revoke all on function mos.promo_descartar(jsonb) from public, anon;
grant execute on function mos.promo_descartar(jsonb) to authenticated;
