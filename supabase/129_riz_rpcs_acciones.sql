-- 129_riz_rpcs_acciones.sql — [RIZ · CAPA 2 · RPCs DE ACCIÓN: ajustar / pedir / ticket / lista-compras]
-- Módulo de Reposición Inteligente por Zona (RIZ). Diseño: DISENO_modulo_reposicion_zona.md (Parte 1.5-1.6, 3.x).
--
-- ⚠️ INERTE: estas RPCs existen y tienen grant, pero NADIE las llama (no hay wiring en js/api.js ni cron). MOS
--    opera 100% por GAS. Este archivo NO toca flags/sync/frontend/GAS.
--
-- ── ESCRITURAS — NOTA DUAL-WRITE ────────────────────────────────────────────────────────────────────────────
--   El diseño (§2.3, §4.8) manda que el ajuste de stock y "pedir" sean DUAL-WRITE-FRONTEND (GAS verdad + espejo
--   Supabase) y NUNCA directo-puro con el sync apagado (incidente 2026-06-15). Aquí se DEFINE solo la RPC
--   Supabase (el espejo); el cableo del dual-write (que el front escriba TAMBIÉN a la Hoja ME) es trabajo de la
--   Capa de frontend. La RPC es idempotente por local_id para tolerar reintentos del gesto. Como nace inerte y
--   nadie la llama, no hay riesgo de desincronización hoy.
--
-- ── PATRÓN: security definer · search_path='' · gate mos._claim_ok() · shape {ok:true,data:...} camelCase. ─────
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) me.zona_ajustar_stock(p jsonb { zona (req), skuBase (req), nuevo (req), usuario, localId?, codBarras? })
--    Escribe me.stock_zonas (cantidad := nuevo) + log [D] me.zona_ajuste_log. Idempotente por localId.
--    ⚠️ skuBase puede tener VARIAS barras en la zona; el ajuste de "stock del producto" necesita un código
--    concreto sobre el que escribir. Regla: si viene codBarras se usa ese; si no, se usa la barra del PRODUCTO
--    BASE (canónico: factor 1 / sin base) del skuBase. (El frontend del card normalmente ajusta el canónico.)
--    El log guarda stock_antes/después/delta para trazabilidad de inventario.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_ajustar_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_nuevo numeric := nullif(btrim(coalesce(p->>'nuevo','')), '')::numeric;
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_cb    text := nullif(btrim(coalesce(p->>'codBarras','')), '');
  v_antes numeric;
  v_existe bigint;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_sku is null or v_nuevo is null then
    return jsonb_build_object('ok',false,'error','Requiere zona, skuBase y nuevo (numérico)');
  end if;

  -- IDEMPOTENCIA por localId: si el gesto ya se aplicó → devolver lo persistido (dedup).
  if v_local is not null then
    select id into v_existe from me.zona_ajuste_log where local_id = v_local limit 1;
    if found then
      return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idLog', v_existe));
    end if;
  end if;

  -- resolver el código concreto a escribir: explícito → o barra del canónico del skuBase.
  if v_cb is null then
    select upper(btrim(pr.codigo_barra)) into v_cb
    from mos.productos pr
    where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku
      and nullif(btrim(pr.codigo_barra),'') is not null
    order by (case when coalesce(pr.codigo_producto_base,'')='' and coalesce(pr.factor_conversion,1)=1 then 0 else 1 end), pr.id_producto
    limit 1;
  end if;
  if v_cb is null then
    return jsonb_build_object('ok',false,'error','No se encontró código de barra para el skuBase '||v_sku);
  end if;

  -- stock antes (suma de esa barra en la zona; normalmente 1 fila por (cod_barras, zona_id)).
  select coalesce(sum(cantidad),0) into v_antes from me.stock_zonas
   where upper(btrim(cod_barras)) = v_cb and upper(btrim(zona_id)) = v_zona;

  -- escribir el nuevo stock (upsert sobre PK (cod_barras, zona_id)).
  insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
  values (v_cb, v_zona, v_nuevo, v_user, now())
  on conflict (cod_barras, zona_id) do update set
    cantidad = excluded.cantidad, usuario = excluded.usuario, fecha_ultimo_registro = now();

  -- log [D] (idempotente por local_id; on conflict do nothing por si dos gestos colisionan).
  insert into me.zona_ajuste_log (zona_id, sku_base, cod_barras, stock_antes, stock_despues, delta, usuario, local_id)
  values (v_zona, v_sku, v_cb, v_antes, v_nuevo, v_nuevo - v_antes, v_user, v_local)
  on conflict (local_id) where local_id is not null do nothing;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'zona', v_zona, 'skuBase', v_sku, 'codBarras', v_cb,
    'stockAntes', v_antes, 'stockDespues', v_nuevo, 'delta', v_nuevo - v_antes));
end;
$fn$;
revoke all on function me.zona_ajustar_stock(jsonb) from public;
grant execute on function me.zona_ajustar_stock(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) me.zona_pedir_almacen(p jsonb { zona (req), items:[{skuBase, cantidad}] (req), usuario, localId? })
--    Inserta en wh.pickups (estado PENDIENTE, fuente 'RIZ', id_zona, items jsonb) — REUSA el canal pickup ME→WH
--    (mismo shape de items que ME_CIERRE_CAJA: {skuBase, nombre, solicitado, despachado:0, codigosOriginales[]}).
--    Idempotente por una clave determinista: localId (si viene) o hash(zona+fecha+items). El id_pickup se
--    guarda con esa clave en `notas` para dedup (wh.pickups no tiene columna local_id; se evita migrar WH).
--    Devuelve idPickup. Almacén ya sabe procesar PENDIENTE y trackea su "debe" por item.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_pedir_almacen(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_items jsonb := coalesce(p->'items', '[]'::jsonb);
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_hoy   date := (now() at time zone 'America/Lima')::date;
  v_clave text;
  v_id    text;
  v_existe text;
  v_norm  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok',false,'error','Requiere items[] no vacío');
  end if;

  -- clave de idempotencia: localId explícito, o hash determinista de (zona + día + items).
  v_clave := 'RIZ:' || coalesce(v_local, v_zona || ':' || v_hoy::text || ':' || md5(v_items::text));

  -- dedup: ¿ya existe un pickup RIZ con esta clave guardada en notas?
  select id_pickup into v_existe from wh.pickups where notas = v_clave limit 1;
  if found then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPickup', v_existe));
  end if;

  -- normalizar items al shape del canal pickup (skuBase, nombre, solicitado, despachado:0, codigosOriginales).
  -- nombre = descripción canónica del skuBase; codigosOriginales = barra del canónico (si se conoce).
  select coalesce(jsonb_agg(jsonb_build_object(
           'skuBase', it.sku,
           'nombre', coalesce(sd.descripcion, it.sku),
           'solicitado', it.cant,
           'despachado', 0,
           'codigosOriginales', coalesce(sd.barras, '[]'::jsonb)
         )), '[]'::jsonb)
    into v_norm
  from (
    select nullif(btrim(e.value->>'skuBase'),'') as sku,
           coalesce((e.value->>'cantidad')::numeric, 0) as cant
    from jsonb_array_elements(v_items) e
    where nullif(btrim(e.value->>'skuBase'),'') is not null and coalesce((e.value->>'cantidad')::numeric,0) > 0
  ) it
  left join lateral (
    select pr.descripcion,
           (select jsonb_agg(distinct upper(btrim(p2.codigo_barra)))
              from mos.productos p2
             where coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) = it.sku
               and nullif(btrim(p2.codigo_barra),'') is not null) as barras
    from mos.productos pr
    where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = it.sku
    order by (case when coalesce(pr.codigo_producto_base,'')='' and coalesce(pr.factor_conversion,1)=1 then 0 else 1 end), pr.id_producto
    limit 1
  ) sd on true;

  if jsonb_array_length(v_norm) = 0 then
    return jsonb_build_object('ok',false,'error','Ningún item válido (skuBase + cantidad>0)');
  end if;

  v_id := 'PCK-RIZ-' || (extract(epoch from clock_timestamp())*1000)::bigint::text;
  insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
  values (v_id, 'RIZ', 'PENDIENTE', v_norm, v_zona, v_clave, v_user, now(), now());

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idPickup', v_id, 'zona', v_zona, 'items', v_norm));
end;
$fn$;
revoke all on function me.zona_pedir_almacen(jsonb) from public;
grant execute on function me.zona_pedir_almacen(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) me.zona_ticket_dia(p jsonb { zona (req), fecha (req, YYYY-MM-DD) })
--    Devuelve el LOTE del día (~10 productos) con A..E por producto:
--      A nombre · B stockZona · C tendencia (picos[]) · D faltan (brecha) · E stockAlmacen.
--    Si ya hay filas materializadas en me.zona_ticket_dia (zona,fecha) → las LEE (lo que el cron dejó listo).
--    Si NO hay → ARMA el lote on-the-fly del esperado materializado (productos con brecha>0, top por brecha,
--    cortado a ~10 — el lote_dia=1). NO escribe nada (la materialización/corte en lotes lo hace el cron, Capa 3).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_ticket_dia(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_fecha date := nullif(btrim(coalesce(p->>'fecha','')), '')::date;
  v_data  jsonb;
  v_mat    jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_fecha is null then
    return jsonb_build_object('ok',false,'error','Requiere zona y fecha (YYYY-MM-DD)');
  end if;

  -- ¿lote materializado? (cron Capa 3). Si hay, devolver esos lotes tal cual.
  select coalesce(jsonb_agg(jsonb_build_object(
           'loteDia', t.lote_dia, 'estado', t.estado, 'items', t.items) order by t.lote_dia), '[]'::jsonb)
    into v_mat
  from me.zona_ticket_dia t where upper(btrim(t.zona_id)) = v_zona and t.fecha = v_fecha;

  if v_mat is not null and jsonb_array_length(v_mat) > 0 then
    return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'zona', v_zona, 'fecha', to_char(v_fecha,'YYYY-MM-DD'), 'origen', 'materializado', 'lotes', v_mat
    )) || mos._frescura_sombra();
  end if;

  -- on-the-fly: top ~10 por brecha (esperado − stockZona) del esperado materializado de la zona.
  with esp as (
    select e.sku_base, e.esperado, e.tendencia, e.picos from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  cb_sku as (
    select distinct on (cb) cb, sku from (
      select upper(btrim(p2.codigo_barra)) cb, coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, 0 ord
        from mos.productos p2 where nullif(btrim(p2.codigo_barra),'') is not null
      union all
      select upper(btrim(ev.codigo_barra)), ev.sku_base, 1
        from mos.equivalencias ev where coalesce(ev.activo,true) and nullif(btrim(ev.codigo_barra),'') is not null and nullif(btrim(ev.sku_base),'') is not null
    ) t order by cb, ord
  ),
  sku_desc as (
    select distinct on (sku) sku, descripcion from (
      select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, p2.descripcion,
             case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord, p2.id_producto
      from mos.productos p2
    ) t order by sku, ord, id_producto
  ),
  stock_zona as (
    select cs.sku as sku_base, sum(coalesce(z.cantidad,0)) cant
    from me.stock_zonas z join cb_sku cs on cs.cb = upper(btrim(z.cod_barras))
    where upper(btrim(z.zona_id)) = v_zona group by cs.sku
  ),
  stock_alm as (
    select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) cant
    from wh.stock s join cb_sku cs on cs.cb = upper(btrim(s.cod_producto)) group by cs.sku
  ),
  filas as (
    select e.sku_base,
           coalesce(sd.descripcion, e.sku_base) as nombre,
           coalesce(sz.cant,0) as stock_zona,
           e.esperado,
           e.esperado - coalesce(sz.cant,0) as faltan,
           coalesce(sa.cant,0) as stock_almacen,
           e.tendencia, e.picos
    from esp e
    left join sku_desc sd on sd.sku = e.sku_base
    left join stock_zona sz on sz.sku_base = e.sku_base
    left join stock_alm sa on sa.sku_base = e.sku_base
    where (e.esperado - coalesce(sz.cant,0)) > 0
    order by (e.esperado - coalesce(sz.cant,0)) desc
    limit 10
  )
  select jsonb_build_object(
    'zona', v_zona, 'fecha', to_char(v_fecha,'YYYY-MM-DD'), 'origen', 'on_the_fly',
    'lotes', jsonb_build_array(jsonb_build_object('loteDia', 1, 'estado', 'PENDIENTE',
      'items', coalesce(jsonb_agg(jsonb_build_object(
        'skuBase', f.sku_base,
        'nombre', f.nombre,
        'stockZona', f.stock_zona,
        'esperada', f.esperado,
        'faltan', f.faltan,
        'stockAlmacen', f.stock_almacen,
        'tendencia', f.tendencia,
        'picos', f.picos
      ) order by f.faltan desc), '[]'::jsonb)))
  ) into v_data from filas f;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_ticket_dia(jsonb) from public;
grant execute on function me.zona_ticket_dia(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) me.zona_lista_compras(p jsonb { zona (req), semana (req, 'IYYY-Www') })
--    Externos: skuBase con brecha>0 que ALMACÉN NO cubre (brecha − stockAlmacen > 0) y que SÍ rotan
--    (volumen_4sem > 0). Materializa/upsert en me.zona_compra_externa (idempotente por zona+semana+sku) y
--    devuelve la lista. La cantidad externa = ceil(brecha − stockAlmacen) (lo que falta tras pedir a almacén).
--    NOTA: NO construye costo (DECISIÓN CERRADA #5: el costo lo registra la guía de ingreso ME, no RIZ).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_lista_compras(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_semana text := nullif(btrim(coalesce(p->>'semana','')), '');
  v_data   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_semana is null then
    return jsonb_build_object('ok',false,'error','Requiere zona y semana (IYYY-Www)');
  end if;

  with
  esp as (
    select e.sku_base, e.esperado, e.volumen_4sem from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  cb_sku as (
    select distinct on (cb) cb, sku from (
      select upper(btrim(p2.codigo_barra)) cb, coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, 0 ord
        from mos.productos p2 where nullif(btrim(p2.codigo_barra),'') is not null
      union all
      select upper(btrim(ev.codigo_barra)), ev.sku_base, 1
        from mos.equivalencias ev where coalesce(ev.activo,true) and nullif(btrim(ev.codigo_barra),'') is not null and nullif(btrim(ev.sku_base),'') is not null
    ) t order by cb, ord
  ),
  sku_desc as (
    select distinct on (sku) sku, descripcion from (
      select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, p2.descripcion,
             case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord, p2.id_producto
      from mos.productos p2
    ) t order by sku, ord, id_producto
  ),
  stock_zona as (
    select cs.sku as sku_base, sum(coalesce(z.cantidad,0)) cant
    from me.stock_zonas z join cb_sku cs on cs.cb = upper(btrim(z.cod_barras))
    where upper(btrim(z.zona_id)) = v_zona group by cs.sku
  ),
  stock_alm as (
    select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) cant
    from wh.stock s join cb_sku cs on cs.cb = upper(btrim(s.cod_producto)) group by cs.sku
  ),
  externos as (
    select e.sku_base,
           coalesce(sd.descripcion, e.sku_base) as descripcion,
           ceil((e.esperado - coalesce(sz.cant,0)) - coalesce(sa.cant,0))::numeric as cant_externa
    from esp e
    left join sku_desc sd on sd.sku = e.sku_base
    left join stock_zona sz on sz.sku_base = e.sku_base
    left join stock_alm sa on sa.sku_base = e.sku_base
    where coalesce(e.volumen_4sem,0) > 0                                   -- SÍ rota
      and (e.esperado - coalesce(sz.cant,0)) > 0                           -- hay brecha
      and ((e.esperado - coalesce(sz.cant,0)) - coalesce(sa.cant,0)) > 0   -- almacén no cubre
  ),
  up as (
    insert into me.zona_compra_externa as ce (zona_id, semana, sku_base, descripcion, cantidad, estado, creado_ts)
    select v_zona, v_semana, x.sku_base, x.descripcion, x.cant_externa, 'PENDIENTE', now()
    from externos x
    on conflict (zona_id, semana, sku_base) do update set
      descripcion = excluded.descripcion,
      cantidad    = excluded.cantidad
    where ce.estado = 'PENDIENTE'                                          -- no pisar compras ya resueltas
    returning sku_base
  )
  select jsonb_build_object(
    'zona', v_zona, 'semana', v_semana,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'skuBase', x.sku_base, 'descripcion', x.descripcion, 'cantidad', x.cant_externa) order by x.cant_externa desc)
      from externos x), '[]'::jsonb),
    'totalItems', (select count(*) from externos),
    'unidades', coalesce((select sum(cant_externa) from externos), 0),
    'upserted', (select count(*) from up)
  ) into v_data;

  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;
revoke all on function me.zona_lista_compras(jsonb) from public;
grant execute on function me.zona_lista_compras(jsonb) to service_role, authenticated;
