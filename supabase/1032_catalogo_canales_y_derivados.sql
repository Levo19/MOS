-- 1032 · Catálogo (21-sep-2026, decisiones del dueño)
-- (1) TIENE_DERIVADOS solo bloquea al borrar el CANÓNICO: los derivados salen del granel, no de sus presentaciones
--     (las presentaciones comparten sku_base con el granel → antes 39 presentaciones no se podían borrar).
-- (2) Canales por producto: canal_me (se vende en el POS ME) y canal_wh (se ve/mueve en almacén WH), además de
--     canal_mayoreo (GO) que ya existía. "estado" sigue siendo el interruptor maestro (existe o no existe).
--     Caso cebada: granel con ME apagado / WH encendido; sus derivados 250/500 g en ME y WH.

alter table mos.productos add column if not exists canal_me boolean not null default true;
alter table mos.productos add column if not exists canal_wh boolean not null default true;


-- mos._tg_no_huerfanos_derivados (pg_get_functiondef vivo + [1032])
CREATE OR REPLACE FUNCTION mos._tg_no_huerfanos_derivados()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_huerfano record;
begin
  if coalesce(current_setting('mos.skip_cb_guard', true),'') = '1' then return null; end if;
  select d.id_producto, d.descripcion, b.descripcion as padre
    into v_huerfano
  from mos.productos d
  join borrados b
    on upper(btrim(coalesce(d.codigo_producto_base,'')))
       in (upper(coalesce(nullif(btrim(b.sku_base),''), b.id_producto)), upper(b.id_producto))
  where coalesce(nullif(btrim(d.codigo_producto_base),''),'') <> ''
    -- [1032] una PRESENTACIÓN no es madre de nadie (comparte sku_base con su granel)
    and coalesce(b.tipo_producto::text,'') <> 'PRESENTACION'
    -- [1032] y si el canónico de ese código sigue vivo, el derivado NO queda huérfano
    and not exists (select 1 from mos.productos v
                     where coalesce(v.tipo_producto::text,'') <> 'PRESENTACION'
                       and upper(coalesce(nullif(btrim(v.sku_base),''), v.id_producto)) = upper(btrim(d.codigo_producto_base))
                       and not exists (select 1 from borrados b3 where b3.id_producto = v.id_producto))
    -- el hijo debe seguir VIVO (no venir en el mismo delete)
    and not exists (select 1 from borrados b2 where b2.id_producto = d.id_producto)
  limit 1;
  if found then
    raise exception 'TIENE_DERIVADOS: no puedes eliminar "%" — su derivado "%" (%) sigue vivo. Elimina primero los hijos.',
      v_huerfano.padre, v_huerfano.descripcion, v_huerfano.id_producto;
  end if;
  return null;
end; $function$
;


-- mos.catalogo_pos_rls (pg_get_functiondef vivo + [1032])
CREATE OR REPLACE FUNCTION mos.catalogo_pos_rls()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
 SET work_mem TO '16MB'
AS $function$
declare
  v_pb jsonb := '[]'::jsonb; v_pr jsonb := '[]'::jsonb; v_eq jsonb; v_zc jsonb; v_cf jsonb; v_sz jsonb; g record;
  v_tramos_map jsonb;
  v_fp text; v_hit jsonb; v_t0 timestamptz;
begin
  -- [650] CACHÉ VERSIONADA POR CONTENIDO (ver 650_catalogo_cache.mjs).
  -- Solo cubre PRODUCTO_BASE + PRESENTACIONES; lo demás se calcula VIVO más abajo.
  v_fp := mos._catalogo_pos_fp();
  select payload into v_hit from mos.catalogo_cache where fn = 'catalogo_pos_rls' and version_fp = v_fp;
  if v_hit is null then
    -- anti-estampida: un solo constructor; los demás esperan y salen por el double-check
    perform pg_advisory_xact_lock(hashtext('catalogo_cache_catalogo_pos_rls'));
    select payload into v_hit from mos.catalogo_cache where fn = 'catalogo_pos_rls' and version_fp = v_fp;
  end if;
  if v_hit is not null then
    v_pb := v_hit->'PRODUCTO_BASE';
    v_pr := v_hit->'PRESENTACIONES';
  else
  v_t0 := clock_timestamp();
  -- [PERF] pre-cargar TODOS los tramos en un mapa sku_base->tramos UNA vez (evita N subqueries en el loop)
  select coalesce(jsonb_object_agg(sku_base, tramos), '{}'::jsonb) into v_tramos_map from mos.precio_tramos;

  -- [651] CONSTRUCCIÓN SET-BASED (antes: loop plpgsql que concatenaba con el operador de
  -- append de jsonb sobre los acumuladores ⇒ copia el array entero por elemento, O(n²), ~9 s).
  -- Misma lógica exacta. El orden del loop se congela en `rn`: grp es MATERIALIZED con la
  -- MISMA query agregada que alimentaba el `for g in`, y row_number() over () captura su
  -- orden de salida (HashAggregate). Todos los agg llevan order by rn (+ k = orden del for m).
  with act as (
      select coalesce(nullif(btrim(sku_base),''), id_producto) as sku,
             id_producto, codigo_barra, descripcion, precio_venta,
             coalesce(precio_fijo, false) as precio_fijo,
         sustitutos_internos, foto_url, categoria_ia,   -- [628] presentación de granel con precio de etiqueta
             coalesce(nullif(factor_conversion,0),1) as factor,
             (coalesce(btrim(es_envasable::text),'') <> '1') as vendible,
             coalesce(es_envasable::text,'') as es_env,
             tipo_igv, unidad, unidad_medida, cod_sunat
        from mos.productos
       where coalesce(estado, true) = true          -- [b FIX] estado es BOOLEAN: excluir apagados (false), no '0'
         and coalesce(canal_me, true) = true        -- [1032] canal ME apagado → no se vende en el POS
  ),
  grp as materialized (
    select sku, jsonb_agg(to_jsonb(act) order by factor asc) as members from act group by sku
  ),
  ordn as (select sku, members, row_number() over () as rn from grp),
  gv as (
    select o.rn, o.sku, o.members,
           -- == `select … into v_vend from jsonb_array_elements(v_members) where vendible`
           (select coalesce(jsonb_agg(value order by (value->>'factor')::numeric asc),'[]'::jsonb)
              from jsonb_array_elements(o.members) where (value->>'vendible')::boolean) as vend
      from ordn o
  ),
  gb as (
    select gv.rn, gv.sku, gv.vend,
           -- [fix dinero] DESEMPATE KGM idéntico al del loop: en grupos unidad-mixta (KGM+NIU,
           -- ambos factor=1) preferir KGM, si no ME ignora los tramos del granel en silencio.
           (select value from jsonb_array_elements(gv.members) where (value->>'factor')::numeric = 1
             order by (upper(coalesce(value->>'unidad_medida', value->>'unidad','')) = 'KGM') desc limit 1) as f1,
           coalesce(
             (select value from jsonb_array_elements(gv.vend) where (value->>'factor')::numeric = 1
               order by (upper(coalesce(value->>'unidad_medida', value->>'unidad','')) = 'KGM') desc limit 1),
             gv.vend->0) as base,                      -- == `if v_base is null then v_base := v_vend->0`
           v_tramos_map -> gv.sku as tramos
      from gv
     where jsonb_array_length(gv.vend) > 0             -- == `continue` cuando no hay vendibles
  )
  select
    coalesce((select jsonb_agg(jsonb_build_object(
        'SKU_Base', gb.sku,
        'Nombre', case when gb.f1 is not null and not (gb.f1->>'vendible')::boolean
                        and coalesce(gb.f1->>'id_producto','') <> coalesce(gb.base->>'id_producto','')
                       then btrim(coalesce(nullif(btrim(gb.f1->>'descripcion'),''),'') || ' ' || coalesce(gb.base->>'descripcion',''))
                       else btrim(coalesce(gb.base->>'descripcion','')) end,
        'Tipo_IGV', mos._conv_tipo_igv(gb.base->>'tipo_igv'),
        'Unidad_Medida', mos._norm_unidad_medida(gb.base->>'unidad', gb.base->>'unidad_medida'),
        'Cod_SUNAT', coalesce(gb.base->>'cod_sunat',''),
        'Foto', coalesce(gb.base->>'foto_url',''),
        'Categoria', coalesce(gb.base->'categoria_ia','{}'::jsonb),
        'segmentos_precio', coalesce(gb.tramos,'[]'::jsonb))
      order by gb.rn) from gb), '[]'::jsonb),
    coalesce((select jsonb_agg(
        jsonb_build_object(
            'SKU_Base', gb.sku, 'SKU', coalesce(e.value->>'id_producto',''),
            'Cod_Barras', coalesce(nullif(btrim(e.value->>'codigo_barra'),''), e.value->>'id_producto'),
            'Empaque', coalesce(e.value->>'descripcion',''),
            'Precio_Venta', coalesce((e.value->>'precio_venta')::numeric, 0),
            'Factor', coalesce((e.value->>'factor')::numeric, 1),
            'Sustitutos', coalesce(e.value->'sustitutos_internos','[]'::jsonb),
            'Precio_Fijo', coalesce((e.value->>'precio_fijo')::boolean, false))
          -- [c] segmentos_precio SOLO en la canónica (Factor=1, lo único que ME lee) y solo si hay tramos
          || case when (e.value->>'factor')::numeric = 1 and gb.tramos is not null
                  then jsonb_build_object('segmentos_precio', gb.tramos) else '{}'::jsonb end
      order by gb.rn, e.k) from gb, lateral jsonb_array_elements(gb.vend) with ordinality as e(value, k)), '[]'::jsonb)
  into v_pb, v_pr;
  -- [650] guardar con el fingerprint LEÍDO AL INICIO: si algo cambió durante los ~9 s de build,
  -- el fp vivo ya no coincide → la próxima llamada reconstruye (sobre-invalida, nunca sub-invalida).
  begin
    insert into mos.catalogo_cache as cc (fn, version, version_fp, payload, built_at, build_ms)
    values ('catalogo_pos_rls',
            (select version from mos.catalogo_meta where id = 1),
            v_fp,
            jsonb_build_object('PRODUCTO_BASE', v_pb, 'PRESENTACIONES', v_pr),
            clock_timestamp(),   -- reloj real de fin de build (now() sería el de la tx)
            (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int)
    on conflict (fn) do update set version = excluded.version, version_fp = excluded.version_fp,
           payload = excluded.payload, built_at = excluded.built_at, build_ms = excluded.build_ms;
  exception when others then null;   -- si el caché falla, la RPC igual responde (degrada, no rompe)
  end;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('Cod_Alias', codigo_barra, 'Cod_Barras_Real', sku_base)), '[]'::jsonb)
    into v_eq from mos.equivalencias where activo;
  with imp as (
    select id_estacion, max(printnode_id) as pn from mos.impresoras
     where activo and (coalesce(lower(app_origen),'') in ('','mosexpress')) and (coalesce(upper(tipo),'') in ('','TICKET')) group by id_estacion),
  ser as (
    select id_zona,
      max(serie) filter (where upper(replace(replace(tipo_documento,' ',''),'_','')) in ('NOTAVENTA','NV','NOTADEVENTA')) as nota,
      max(serie) filter (where upper(tipo_documento)='BOLETA') as boleta,
      max(serie) filter (where upper(tipo_documento)='FACTURA') as factura
    from mos.series_documentales where activo group by id_zona)
  select coalesce(jsonb_agg(jsonb_build_object(
           'Zona_ID', e.id_zona, 'Estacion_Nombre', e.nombre, 'idEstacion', e.id_estacion,
           'PrintNode_ID', coalesce(imp.pn,''), 'Serie_Nota', coalesce(ser.nota,''),
           'Serie_Boleta', coalesce(ser.boleta,''), 'Serie_Factura', coalesce(ser.factura,''),
           'Admin_PIN', coalesce(e.admin_pin,''))), '[]'::jsonb)
    into v_zc from mos.estaciones e
    left join imp on imp.id_estacion = e.id_estacion left join ser on ser.id_zona = e.id_zona
   where e.activo and coalesce(lower(e.app_origen),'') in ('','mosexpress') and coalesce(btrim(e.nombre),'') <> '';
  select coalesce(jsonb_agg(jsonb_build_object('Documento', documento, 'Nombre_RazonSocial', nombre, 'Direccion', coalesce(direccion,''))), '[]'::jsonb)
    into v_cf from me.clientes_frecuentes;
  select coalesce(jsonb_agg(jsonb_build_object('Cod_Barras', cod_barras, 'Zona_ID', zona_id, 'Cantidad', cantidad)), '[]'::jsonb)
    into v_sz from me.stock_zonas;

  return jsonb_build_object('status','success','data', jsonb_build_object(
    'PRODUCTO_BASE', v_pb, 'PRESENTACIONES', v_pr, 'EQUIVALENCIAS', v_eq,
    'ZONAS_CONFIG', v_zc, 'CLIENTES_FRECUENTES', v_cf, 'STOCK_ZONAS', v_sz, 'PROMOCIONES', /* [663] promos reales al POS (decisión dueño) */ coalesce((
        select jsonb_agg(jsonb_build_object(
          'ID_Promo', pm.id_promo,
          'SKU_Base', pm.sku_base,
          'Tipo_Promo', pm.tipo_promo,
          'Cant_Min', pm.cant_min,
          'Valor_Promo', pm.valor_promo,
          'Valor_Modo', pm.valor_modo,
          'Descripcion', pm.descripcion,
          'Items_JSON', pm.items_json,
          'Vigencia_Desde', pm.vigencia_desde,
          'Vigencia_Hasta', pm.vigencia_hasta,
          'Activa', coalesce(pm.activa, true),
          /* [664] ventana horaria (null = todo el día) + jugada del playbook */
          'Hora_Desde', case when pm.hora_desde is null then null else to_char(pm.hora_desde,'HH24:MI') end,
          'Hora_Hasta', case when pm.hora_hasta is null then null else to_char(pm.hora_hasta,'HH24:MI') end,
          'Estrategia', pm.estrategia
        ) order by pm.id_promo)
        from mos.promociones pm
        where coalesce(pm.activa, true)
      ), '[]'::jsonb),
    '_meta', jsonb_build_object('fuente','SUPABASE','timestamp', (extract(epoch from now())*1000)::bigint)));
end;
$function$
;


-- mos._catalogo_pos_fp (pg_get_functiondef vivo + [1032])
CREATE OR REPLACE FUNCTION mos._catalogo_pos_fp()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with act as (
    select coalesce(nullif(btrim(sku_base),''), id_producto) as sku,
           id_producto, codigo_barra, descripcion, precio_venta,
           coalesce(precio_fijo, false) as precio_fijo,
           sustitutos_internos, foto_url, categoria_ia,
           coalesce(nullif(factor_conversion,0),1) as factor,
           (coalesce(btrim(es_envasable::text),'') <> '1') as vendible,
           coalesce(es_envasable::text,'') as es_env,
           tipo_igv, unidad, unidad_medida, cod_sunat
      from mos.productos
     where coalesce(estado, true) = true
       and coalesce(canal_me, true) = true)   -- [1032] la huella cambia al tocar el canal ME
  select md5(
      coalesce((select string_agg(h,'' order by h) from (select md5(to_jsonb(act)::text) h from act) z),'')
   || '#'
   || coalesce((select string_agg(sku_base||':'||tramos::text, ',' order by sku_base) from mos.precio_tramos),'')
  );
$function$
;


-- mos.catalogo_wh_rls (pg_get_functiondef vivo + [1032] canal_wh)
CREATE OR REPLACE FUNCTION mos.catalogo_wh_rls()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_prod jsonb; v_equiv jsonb; v_prov jsonb; v_pers jsonb; v_impr jsonb; v_zonas jsonb;
        v_ts timestamptz := now();   -- [race-safe] corte ANTES de leer: lo que cambie durante el query lo re-trae el próximo delta
begin
  if not (wh._claim_ok() or mos._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(((to_jsonb(t) - 'created_at' - 'updated_at') || case when coalesce(t.canal_wh, true) then '{}'::jsonb else jsonb_build_object('estado', false) end) order by t.id_producto), '[]'::jsonb) into v_prod from mos.productos t;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.id_equiv), '[]'::jsonb) into v_equiv from mos.equivalencias e where e.activo = true;
  select coalesce(jsonb_agg((to_jsonb(p) - 'numero_cuenta' - 'cci') order by p.id_proveedor), '[]'::jsonb) into v_prov from mos.proveedores p;
  select coalesce(jsonb_agg((to_jsonb(p) - 'pin' - 'pin_hash') order by p.id_personal), '[]'::jsonb) into v_pers from mos.personal p where p.estado = true;
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id_impresora), '[]'::jsonb) into v_impr from mos.impresoras i where lower(coalesce(i.app_origen,'')) = 'warehousemos' and i.activo = true;
  select coalesce(jsonb_agg(to_jsonb(z) order by z.id_zona), '[]'::jsonb) into v_zonas from mos.zonas z where z.estado = true;
  return jsonb_build_object('ok', true, 'server_ts', to_char((v_ts - interval '2 seconds') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'productos', v_prod, 'equivalencias', v_equiv, 'proveedores', v_prov,
    'personal', v_pers, 'impresoras', v_impr, 'zonas', v_zonas);
end;
$function$
;


-- mos.catalogo_wh_delta (pg_get_functiondef vivo + [1032] canal_wh)
CREATE OR REPLACE FUNCTION mos.catalogo_wh_delta(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  select coalesce(jsonb_agg(((to_jsonb(t) - 'created_at' - 'updated_at') || case when coalesce(t.canal_wh, true) then '{}'::jsonb else jsonb_build_object('estado', false) end) order by t.id_producto), '[]'::jsonb), count(*)
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
$function$
;


create or replace function mos.catalogo_toggle_canal(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_id    text := btrim(coalesce(p->>'idProducto',''));
  v_canal text := upper(btrim(coalesce(p->>'canal','')));
  v_on    boolean := coalesce((p->>'on')::boolean, false);
  v_usr   text := btrim(coalesce(p->>'usuario',''));
  v_row   record;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if not exists (select 1 from mos.personal
                  where upper(btrim(nombre)) = upper(v_usr) and upper(coalesce(rol,'')) = 'MASTER') then
    return jsonb_build_object('ok', false, 'error', 'SOLO_MASTER');
  end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idProducto'); end if;
  if v_canal not in ('ME','WH') then return jsonb_build_object('ok',false,'error','Canal inválido (ME|WH)'); end if;
  if v_canal = 'ME' then update mos.productos set canal_me = v_on where id_producto = v_id;
  else                   update mos.productos set canal_wh = v_on where id_producto = v_id; end if;
  if not found then return jsonb_build_object('ok',false,'error','NO_EXISTE'); end if;
  select canal_me, canal_wh, canal_mayoreo, estado into v_row from mos.productos where id_producto = v_id;
  return jsonb_build_object('ok', true, 'idProducto', v_id,
    'canalMe', v_row.canal_me, 'canalWh', v_row.canal_wh, 'canalMayoreo', v_row.canal_mayoreo, 'estado', v_row.estado);
end $$;
revoke all on function mos.catalogo_toggle_canal(jsonb) from public, anon;
grant execute on function mos.catalogo_toggle_canal(jsonb) to authenticated, service_role;
