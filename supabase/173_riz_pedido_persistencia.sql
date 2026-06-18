-- 173_riz_pedido_persistencia.sql — [RIZ · CARRITO + PERSISTENCIA DEL PEDIDO + FIX DEDUP]
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- CONTEXTO (incidente reportado por el dueño, 2026-06-18, ZONA-02 "CHICHA DE JORA 3LT", 15 u):
--   (A) Pidió 15 → se marcó "pedido" (optimista) + apareció el pickup PCK-RIZ-... en WH → al refrescar el panel,
--       el chip "pedido" DESAPARECIÓ (el estado era SOLO optimista en el DOM; me.zona_panel no lo conoce, así que
--       el auto-refresh reconstruye el card con el botón "Pedir" de vuelta). El dueño creyó que no se pidió y
--       volvió a pedir 15. El 2º pedido NO llegó a WH: la dedup de me.zona_pedir_almacen usaba una clave
--       DETERMINISTA hash(zona+día+items) cuando no venía localId → el 2º request (misma zona, mismo día, mismo
--       item+cantidad) generó el MISMO md5 → matcheó `notas` del pickup existente → devolvió {dedup:true} y NO
--       creó nada. Verificado en prod: hay UN solo pickup de chicha jora (no se duplicó), pero la dedup se
--       "tragó" un re-pedido legítimo y el estado no persistía.
--
-- ESTE ARCHIVO CORRIGE:
--   1) [F] me.zona_pedido_log — persiste CADA línea pedida (zona, sku, cantidad, idPickup, ts). Fuente de verdad
--      del estado "Pedido hoy / ayer / el martes" (ventana 7 días). Idempotente por local_id del PAQUETE+sku.
--   2) me.zona_pedir_almacen — REDISEÑO a LOTE/PAQUETE:
--        · dedup SOLO por localId EXPLÍCITO del paquete (el carrito manda un localId por envío). SIN localId →
--          SIEMPRE crea un pickup nuevo (un re-pedido legítimo nunca se traga). Se elimina el md5(items) que
--          tragaba re-pedidos.
--        · un envío = UN pickup con N líneas (no N pickups). Persiste N filas en me.zona_pedido_log.
--   3) me.zona_panel — emite `pedidoEstado` por item: {veces, ultimoTs, dias:[...], etiqueta:"Pedido hoy y ayer"}
--      leído de me.zona_pedido_log (últimos 7 días). El front lo muestra y PERSISTE entre refrescos. Re-pedir
--      sigue permitido (el botón refleja el historial pero no se bloquea).
--
-- PATRÓN: security definer · search_path='' · gate mos._claim_ok() · shape {ok,data} camelCase · grants
--   revoke public + service_role,authenticated. Money/inventario-safe: NO toca me.stock_zonas/wh.stock/caja/guías;
--   solo crea pickups PENDIENTE (canal ME→WH ya existente) + log de pedidos. El wrapper mos.zona_pedir_almacen
--   (132) es pass-through puro → no se toca. mos.zona_panel (132) idem.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;


-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- [F] me.zona_pedido_log — una fila por LÍNEA pedida (idempotente por (local_id, sku_base) del paquete).
--     Conserva el historial: "Pedido hoy y ayer" = filas en >1 día distinto dentro de la ventana de 7 días.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists me.zona_pedido_log (
  id         bigint generated always as identity primary key,
  zona_id    text not null,
  sku_base   text not null,
  cantidad   numeric not null default 0,
  id_pickup  text,
  usuario    text,
  local_id   text,                              -- localId del PAQUETE (carrito); idempotencia del envío
  ts         timestamptz not null default now()
);
create index if not exists ix_riz_pedido_log_zona_sku_ts on me.zona_pedido_log (zona_id, sku_base, ts desc);
-- idempotencia por (paquete, sku): re-enviar el mismo carrito (mismo localId) no duplica filas del log.
create unique index if not exists ux_riz_pedido_log_pkg_sku on me.zona_pedido_log (local_id, sku_base) where local_id is not null;

alter table me.zona_pedido_log enable row level security;
grant all on me.zona_pedido_log to service_role;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- me.zona_pedir_almacen(p jsonb { zona (req), items:[{skuBase, cantidad}] (req), usuario, localId? })
--   LOTE: inserta UN pickup (estado PENDIENTE, fuente 'RIZ') con N líneas + N filas en me.zona_pedido_log.
--   DEDUP: SOLO por localId explícito del paquete (carrito). Sin localId → SIEMPRE crea (re-pedido legítimo OK).
--   Devuelve idPickup + items normalizados. Almacén ya sabe procesar PENDIENTE.
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

  -- DEDUP del PAQUETE: SOLO si vino un localId explícito (el carrito estampa un localId por envío). Reenviar el
  -- MISMO carrito (mismo localId) devuelve el pickup ya creado sin duplicar. SIN localId NO se dedupea: un
  -- re-pedido legítimo (mismo producto/cantidad otro día o por insistencia) SIEMPRE crea un pickup nuevo.
  if v_local is not null then
    v_clave := 'RIZ:' || v_local;
    select id_pickup into v_existe from wh.pickups where notas = v_clave limit 1;
    if found then
      return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPickup', v_existe));
    end if;
  else
    -- sin localId: clave única no-determinista (no colisiona con otro envío) — el pickup se crea siempre.
    v_clave := 'RIZ:' || v_zona || ':' || (extract(epoch from clock_timestamp())*1000)::bigint::text;
  end if;

  -- normalizar items al shape del canal pickup (skuBase, nombre, solicitado, despachado:0, codigosOriginales).
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

  -- PERSISTIR el pedido: una fila por línea (fuente de verdad del estado "Pedido hoy/ayer" en el panel).
  -- Idempotente por (local_id, sku_base): si el carrito se reenvía con el mismo localId no duplica filas.
  insert into me.zona_pedido_log (zona_id, sku_base, cantidad, id_pickup, usuario, local_id, ts)
  select v_zona,
         (el->>'skuBase'),
         coalesce((el->>'solicitado')::numeric, 0),
         v_id, v_user, v_local, now()
  from jsonb_array_elements(v_norm) el
  on conflict (local_id, sku_base) where local_id is not null do nothing;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idPickup', v_id, 'zona', v_zona, 'items', v_norm));
end;
$fn$;
revoke all on function me.zona_pedir_almacen(jsonb) from public;
grant execute on function me.zona_pedir_almacen(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- me.zona_panel — REDEFINE (= versión 158 + `pedidoEstado` por item, leído de me.zona_pedido_log, ventana 7 días).
--   pedidoEstado = { veces:int, ultimoTs:text, dias:[YYYY-MM-DD…], etiqueta:text } | null (si no se pidió en 7d).
--   etiqueta relativa en español: "Pedido hoy", "Pedido ayer", "Pedido hoy y ayer", "Pedido el martes", o
--   combinaciones cortas ("Pedido hoy y el lunes"). El front la muestra tal cual.
--   El wrapper mos.zona_panel (132) es pass-through → no se toca. Backward-compatible (campo ADITIVO).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_panel(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_filtro text := upper(btrim(coalesce(p->>'filtro','')));
  v_hoy    date := (now() at time zone 'America/Lima')::date;
  v_data   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  with
  zona_aliases as (
    select v_zona as alias
    union select upper(btrim(es.id_zona)) from mos.estaciones es where upper(btrim(es.id_zona)) = v_zona
  ),
  cb_sku as (
    select distinct on (cb) cb, sku, cb_desc, es_equiv from (
      select upper(btrim(p2.codigo_barra)) cb,
             coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku,
             nullif(btrim(p2.descripcion),'') cb_desc,
             false es_equiv, 0 ord
        from mos.productos p2 where nullif(btrim(p2.codigo_barra),'') is not null
      union all
      select upper(btrim(e.codigo_barra)),
             e.sku_base,
             nullif(btrim(e.descripcion),''),
             true, 1
        from mos.equivalencias e
        where coalesce(e.activo,true) and nullif(btrim(e.codigo_barra),'') is not null and nullif(btrim(e.sku_base),'') is not null
    ) t order by cb, ord
  ),
  sku_meta as (
    select distinct on (sku) sku, descripcion, unidad, factor from (
      select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku,
             p2.descripcion,
             coalesce(nullif(btrim(p2.unidad),''),'') as unidad,
             coalesce(p2.factor_conversion,1) as factor,
             case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord,
             p2.id_producto
      from mos.productos p2
    ) t order by sku, ord, id_producto
  ),
  stock_cod as (
    select cs.sku as sku_base, cs.cb as cod_barra, cs.cb_desc, cs.es_equiv,
           sum(coalesce(z.cantidad,0)) as cant
    from cb_sku cs
    join me.stock_zonas z on upper(btrim(z.cod_barras)) = cs.cb
    where upper(btrim(z.zona_id)) in (select alias from zona_aliases)
    group by cs.sku, cs.cb, cs.cb_desc, cs.es_equiv
  ),
  cod_arr as (
    select sk.sku_base,
           jsonb_agg(jsonb_build_object(
             'codBarra', sk.cod_barra,
             'descripcion', coalesce(sk.cb_desc, sk.cod_barra),
             'stock', sk.cant,
             'esEquivalente', sk.es_equiv
           ) order by sk.es_equiv, sk.cod_barra) as codigos,
           sum(sk.cant) as stock_zona
    from stock_cod sk
    group by sk.sku_base
  ),
  stock_alm as (
    select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) as cant
    from wh.stock s
    join cb_sku cs on cs.cb = upper(btrim(s.cod_producto))
    group by cs.sku
  ),
  lotes as (
    select l.sku_base, min(l.fecha_vencimiento) as venc_prox, count(*) as n
    from me.zona_lotes l
    where upper(btrim(l.zona_id)) = v_zona and coalesce(l.cant_restante,0) > 0
    group by l.sku_base
  ),
  esp as (
    select e.sku_base, e.esperado, e.tendencia, e.bcg, e.picos, e.volumen_4sem
    from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  accion as (
    select a.sku_base, a.accion from me.zona_accion_perro a where upper(btrim(a.zona_id)) = v_zona
  ),
  -- ⭐ PEDIDO PERSISTIDO (ventana 7 días): días distintos en que se pidió cada sku + etiqueta relativa.
  ped_raw as (
    select pl.sku_base,
           (pl.ts at time zone 'America/Lima')::date as dia,
           pl.ts
    from me.zona_pedido_log pl
    where upper(btrim(pl.zona_id)) = v_zona
      and (pl.ts at time zone 'America/Lima')::date >= (v_hoy - 6)   -- hoy + 6 atrás = 7 días
  ),
  ped_dias as (
    select pr.sku_base,
           array_agg(distinct pr.dia order by pr.dia desc) as dias,
           count(distinct pr.dia) as veces,
           max(pr.ts) as ultimo_ts
    from ped_raw pr
    group by pr.sku_base
  ),
  -- etiqueta por día (relativa) → luego se concatena ("Pedido hoy y ayer", "Pedido el martes", …).
  ped as (
    select pd.sku_base, pd.veces, pd.ultimo_ts, pd.dias,
           (
             select string_agg(lbl, ' y ' order by ord)
             from (
               select d.dia,
                      row_number() over (order by d.dia desc) as ord,
                      case
                        when d.dia = v_hoy            then 'hoy'
                        when d.dia = v_hoy - 1        then 'ayer'
                        else 'el ' || (array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])
                                       [extract(dow from d.dia)::int + 1]
                      end as lbl
               from unnest(pd.dias) as d(dia)
               order by d.dia desc
               limit 3                                              -- como mucho 3 menciones (cabe en el botón)
             ) x
           ) as etiqueta_dias
    from ped_dias pd
  ),
  universo as (
    select sku_base from esp union select sku_base from cod_arr
  ),
  filas as (
    select
      u.sku_base,
      coalesce(sm.descripcion, u.sku_base) as descripcion,
      coalesce(ca.stock_zona, 0) as stock_zona,
      coalesce(es.esperado, 0) as esperada,
      greatest(0, coalesce(es.esperado, 0) - greatest(coalesce(ca.stock_zona, 0), 0)) as brecha,
      (coalesce(ca.stock_zona, 0) < 0) as stock_negativo,
      coalesce(sa.cant, 0) as stock_almacen,
      coalesce(es.tendencia, 'NULA') as tendencia,
      coalesce(es.bcg, 'PERRO') as bcg,
      coalesce(es.picos, '[]'::jsonb) as picos,
      coalesce(es.volumen_4sem, 0) as volumen,
      lo.venc_prox,
      coalesce(lo.n, 0) as count_lotes,
      coalesce(sm.unidad, '') as unidad,
      me._riz_es_granel(sm.unidad, sm.factor) as es_granel,
      coalesce(ca.codigos, '[]'::jsonb) as codigos,
      ac.accion as accion_perro,
      pe.veces      as ped_veces,
      pe.ultimo_ts  as ped_ultimo_ts,
      pe.dias       as ped_dias,
      pe.etiqueta_dias as ped_etiqueta
    from universo u
    left join sku_meta   sm on sm.sku = u.sku_base
    left join cod_arr    ca on ca.sku_base = u.sku_base
    left join esp        es on es.sku_base = u.sku_base
    left join stock_alm  sa on sa.sku_base = u.sku_base
    left join lotes      lo on lo.sku_base = u.sku_base
    left join accion     ac on ac.sku_base = u.sku_base
    left join ped        pe on pe.sku_base = u.sku_base
  )
  select jsonb_build_object(
    'zona', v_zona,
    'filtro', nullif(v_filtro,''),
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'skuBase', f.sku_base,
      'descripcion', f.descripcion,
      'stockZona', f.stock_zona,
      'esperada', f.esperada,
      'brecha', f.brecha,
      'stockNegativo', f.stock_negativo,
      'stockAlmacen', f.stock_almacen,
      'tendencia', f.tendencia,
      'bcg', f.bcg,
      'picos', f.picos,
      'volumen', f.volumen,
      'unidad', f.unidad,
      'esGranel', f.es_granel,
      'codigos', f.codigos,
      'accionPerro', f.accion_perro,
      'pedidoEstado', case when coalesce(f.ped_veces,0) > 0 then jsonb_build_object(
        'veces', f.ped_veces,
        'ultimoTs', to_char((f.ped_ultimo_ts at time zone 'America/Lima'), 'YYYY-MM-DD"T"HH24:MI:SS'),
        'dias', to_jsonb(f.ped_dias),
        'etiqueta', 'Pedido ' || coalesce(f.ped_etiqueta, 'hoy')
      ) else null end,
      'vencimientoProximo', case when f.venc_prox is null then null else jsonb_build_object(
        'fecha', to_char((f.venc_prox at time zone 'America/Lima')::date, 'YYYY-MM-DD'),
        'dias', ((f.venc_prox at time zone 'America/Lima')::date - v_hoy)) end,
      'countLotes', f.count_lotes
    ) order by f.brecha desc, f.volumen desc, f.stock_zona desc), '[]'::jsonb)
  ) into v_data
  from filas f
  where v_filtro = '' or v_filtro is null
     or (v_filtro = 'BRECHA' and f.brecha > 0)
     or (v_filtro = 'SIN_ROTACION' and f.tendencia = 'NULA')
     or (v_filtro in ('CRECIENTE','DECRECIENTE','ESTABLE') and f.tendencia = v_filtro)
     or (v_filtro in ('ESTRELLA','VACA','INTERROGANTE','PERRO') and f.bcg = v_filtro);

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_panel(jsonb) from public;
grant execute on function me.zona_panel(jsonb) to service_role, authenticated;
