-- 795_auditoria_fixes_sql.sql — [AUDITORÍA 7 DÍAS · paquete de fixes del backend]
-- Hallazgos del auditor de base de datos sobre las migraciones 789-792, todos con evidencia
-- medida en producción. Se corrigen aquí en un solo paso.

-- ─────────────────────────────────────────────────────────────────────────────
-- (1) [ALTO] DOBLE AVISO DE PRECIO — se retira el trigger 791/794 (era mío y sobraba).
-- Ya existía un carril COMPLETO y mejor: trigger `tg_notif_precio` → tabla
-- `mos.notif_precio_pendiente` → cron `mos-avisar-precios` (*/5) → push AGRUPADO
-- ("5 productos: A, B, C… y 2 más"), que es el formato que el dueño ya aprobó.
-- El log de producción confirma que ese carril es el único que ha enviado avisos.
-- Mantener ambos = 2 notificaciones por cada cambio de precio en el POS.
-- `mos.alertas_precio` (la lista de 15 días de ME) NO depende de este trigger: lee
-- la tabla directo. Por eso quitarlo es riesgo cero.
drop trigger if exists tg_precio_push_stmt on mos.historial_precio_costo;
drop trigger if exists tg_precio_push      on mos.historial_precio_costo;
drop function if exists mos.tg_precio_push_stmt();
drop function if exists mos.tg_precio_push();

-- ─────────────────────────────────────────────────────────────────────────────
-- (2) [MEDIO · PLATA] `zona_rezagado_detalle` mostraba DEUDA FANTASMA.
-- Su CTE `desp` resolvía el sku SOLO por `mos.productos`, sin equivalencias (el CTE
-- gemelo del pickup vivo sí las resuelve) y sin filtrar líneas ANULADAS. Medido:
-- 317 líneas / 4.345 u de los últimos 90 días resuelven solo por equivalencia; en el
-- bucket vigente eso son 2 ítems y ~53 u de ZONA-02 que figuran como deuda pese a
-- estar despachados. Con el semáforo nuevo (rojo = deuda + hay stock) eso empuja a
-- RE-DESPACHAR mercadería ya enviada.
CREATE OR REPLACE FUNCTION wh.zona_rezagado_detalle(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_zona   text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket date;
  v_stock  jsonb;
  v_items  jsonb;
  v_sinsku jsonb;
begin
  if v_zona = '' then return jsonb_build_object('ok', false, 'error', 'Requiere zona'); end if;

  select to_date(right(id_pickup,10),'YYYY-MM-DD') into v_bucket
    from wh.pickups
   where coalesce(id_zona,'')=v_zona and fuente='ACUMULADO_SEMANAL'
     and upper(coalesce(estado,''))='REZAGADO'
     and id_pickup like 'PCK-ACU-'||v_zona||'-%'
     and right(id_pickup,10) ~ '^\d{4}-\d{2}-\d{2}$'
   order by to_date(right(id_pickup,10),'YYYY-MM-DD') desc
   limit 1;

  if v_bucket is null then
    return jsonb_build_object('ok',true,'zona',v_zona,'rezagado',true,'sin_rezagado',true,
      'items','[]'::jsonb,'total_items',0,'total_pendiente',0,'total_despachado',0);
  end if;

  select coalesce(jsonb_object_agg(sku, st), '{}'::jsonb) into v_stock
    from (
      select coalesce(pr.sku_base, eq.sku_base) as sku,
             sum(coalesce(s.cantidad_disponible, 0)) as st
        from wh.stock s
        left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
        left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
       where coalesce(pr.sku_base, eq.sku_base) is not null
       group by 1
    ) q;
  v_stock := coalesce(v_stock, '{}'::jsonb);

  with ped as (
    select it->>'skuBase' sku, (pk.fecha_creado at time zone 'America/Lima')::date dia,
           sum(wh._num(coalesce(it->>'solicitado','0'))) cant, max(it->>'nombre') nombre,
           min(pk.fecha_creado) ts
    from wh.pickups pk cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
    where coalesce(pk.id_zona,'')=v_zona and coalesce(pk.fuente,'')<>'ACUMULADO_SEMANAL'
      and wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date)=v_bucket
      and coalesce(it->>'skuBase','')<>''
    group by 1,2
  ),
  desp as (
    -- [795] equivalencias + descartar ANULADO: idéntico al CTE del pickup vivo.
    select coalesce(pr.sku_base, eq.sku_base) sku, (g.fecha at time zone 'America/Lima')::date dia,
           sum(coalesce(gd.cant_recibida, gd.cantidad_aplicada, 0)) cant,
           min(coalesce(gd.created_at, g.fecha)) ts_primero,
           max(coalesce(gd.created_at, g.fecha)) ts_ultimo
    from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
    left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
    left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
    where g.tipo='SALIDA_ZONA' and coalesce(g.id_zona,'')=v_zona
      and wh._bucket_dom((g.fecha at time zone 'America/Lima')::date)=v_bucket
      and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
      and coalesce(pr.sku_base, eq.sku_base) is not null
    group by 1,2
  ),
  skus as (select sku from ped union select sku from desp),
  agg as (
    select s.sku,
      (select max(nombre) from ped where ped.sku=s.sku) nombre,
      coalesce((select sum(cant) from ped where ped.sku=s.sku),0) pedido,
      coalesce((select sum(cant) from desp where desp.sku=s.sku),0) despacho,
      (select min(ts) from ped where ped.sku=s.sku) ts_ped,
      (select max(ts_ultimo) from desp where desp.sku=s.sku) ts_desp
    from skus s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'skuBase', a.sku, 'nombre', coalesce(a.nombre, a.sku),
    'solicitado', a.pedido, 'despachado', a.despacho,
    'pendiente', greatest(0, a.pedido - a.despacho),
    'tsSolicitud', case when a.ts_ped  is not null then to_char(a.ts_ped  at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI') end,
    'tsDespacho',  case when a.ts_desp is not null then to_char(a.ts_desp at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI') end,
    'stockWh', coalesce((v_stock->>(a.sku))::numeric, 0),
    'historial', (
      select coalesce(jsonb_agg(h.obj order by (h.obj->>'fecha'), (h.obj->>'tipo') desc), '[]'::jsonb)
      from (
        select jsonb_build_object('fecha', to_char(ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'), 'tipo','pedido','cant',cant) obj
          from ped where ped.sku=a.sku
        union all
        select jsonb_build_object('fecha', to_char(ts_primero at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'), 'tipo','despacho','cant',cant)
          from desp where desp.sku=a.sku
      ) h)
  ) order by greatest(0, a.pedido - a.despacho) desc), '[]'::jsonb)
  into v_items from agg a where greatest(0, a.pedido - a.despacho) > 0;

  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'solicitado', ped, 'despachado', 0,
           'fecha', to_char(ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')
         ) order by ts desc, nombre), '[]'::jsonb)
    into v_sinsku
    from (
      select upper(btrim(coalesce(it->>'nombre',''))) as nombre,
             min(pk.fecha_creado) as ts,
             sum(wh._num(coalesce(it->>'solicitado','0'))) as ped
        from wh.pickups pk
        cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
       where coalesce(pk.id_zona,'') = v_zona
         and coalesce(pk.fuente,'') = 'LISTA_IA'
         and wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date) = v_bucket
         and coalesce(btrim(it->>'skuBase'),'') = ''
         and wh._num(coalesce(it->>'solicitado','0')) > 0
       group by 1, (pk.fecha_creado at time zone 'America/Lima')::date
      having sum(wh._num(coalesce(it->>'solicitado','0'))) > 0
    ) q;

  return jsonb_build_object('ok',true,'zona',v_zona,'rezagado',true,'bucket',to_char(v_bucket,'YYYY-MM-DD'),
    'items', v_items, 'sinIdentificar', coalesce(v_sinsku,'[]'::jsonb), 'total_items', jsonb_array_length(v_items),
    'total_pendiente', (select coalesce(sum(greatest(0,(x->>'solicitado')::numeric-(x->>'despachado')::numeric)),0) from jsonb_array_elements(v_items) x),
    'total_despachado', (select coalesce(sum((x->>'despachado')::numeric),0) from jsonb_array_elements(v_items) x));
end; $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- (3) [MEDIO] `considerados_listar`: el LIMIT 50 estaba pegado al agregado (limitaba
-- la fila del jsonb_agg, es decir NADA). Se aplica a las filas, como se pretendía.
create or replace function wh.considerados_listar(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_items jsonb;
begin
  update wh.considerados set estado = 'VENCIDO'
   where estado = 'ACTIVO' and creado < now() - interval '7 days';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', z.id, 'skuBase', z.sku_base, 'nombre', z.nombre,
           'cant', z.cant_ingresada, 'zonas', z.zonas, 'guiaTipo', z.guia_tipo,
           'creado', to_char(z.creado at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI')
         ) order by z.creado desc), '[]'::jsonb)
    into v_items
    from (select * from wh.considerados where estado = 'ACTIVO' order by creado desc limit 50) z;

  return jsonb_build_object('ok', true, 'items', v_items,
    'total', (select count(*) from wh.considerados where estado = 'ACTIVO'));
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- (4) [MEDIO] `membrete_cola_listar` ESCRIBÍA en el camino de lectura: un DELETE
-- incondicional (seq scan + WAL) en una función que el front llama CADA 4 SEGUNDOS
-- por caja con el modal abierto. Ahora solo borra si de verdad hay algo que borrar.
create or replace function mos.membrete_cola_listar(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_tipo text := coalesce(nullif(btrim(p->>'tipo'),''), 'MEMBRETE_ME');
  v_zona text := mos._mc_norm(p->>'zona');
  v_usr  text := mos._mc_norm(p->>'usuario');
  v_items jsonb;
begin
  if exists (select 1 from mos.membrete_cola where creado < now() - interval '7 days') then
    delete from mos.membrete_cola where creado < now() - interval '7 days';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'codigoBarra', codigo_barra, 'idProducto', id_producto,
           'descripcion', descripcion, 'payload', payload,
           'creado', to_char(creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')
         ) order by creado), '[]'::jsonb)
    into v_items
    from mos.membrete_cola
   where tipo = v_tipo and zona = v_zona and usuario = v_usr;
  return jsonb_build_object('ok', true, 'tipo', v_tipo, 'zona', v_zona, 'usuario', v_usr,
                            'items', v_items, 'total', jsonb_array_length(v_items));
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- (5) [MEDIO] Push de "considerado" a los admins: `push_tokens_para` combina
-- usuarios/apps/roles con OR, no con AND → `apps:[MOS] + roles:[ADMIN…]` alcanzaba a
-- los 12 dispositivos MOS en vez de a los 8 admins. Con solo `roles` el ruteo a la app
-- admin ya lo aplica MOS_PUSH_APP_ADMIN dentro de la propia función.
create or replace function wh.tg_considerado_ingreso() returns trigger
language plpgsql security definer set search_path to ''
as $$
declare
  v_tipo text; v_sku text; v_nom text; v_bucket date; v_bstr text;
  v_hoy boolean := false; v_zonas jsonb; v_ins int := 0;
  v_txt text; v_tit text; v_cuerpo text;
begin
  begin
    select tipo into v_tipo from wh.guias where id_guia = new.id_guia;
    if v_tipo is null or v_tipo not in ('INGRESO_PROVEEDOR','INGRESO_ENVASADO') then return new; end if;

    select coalesce(pr.sku_base, eq.sku_base) into v_sku
      from (select 1) x
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(new.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(new.cod_producto,''));
    if v_sku is null or btrim(v_sku) = '' then return new; end if;

    v_bucket := wh._bucket_dom((now() at time zone 'America/Lima')::date);
    v_bstr   := to_char(v_bucket, 'YYYY-MM-DD');

    select exists (
      select 1 from wh.pickups pk
      cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
      where pk.fuente = 'ACUMULADO_SEMANAL'
        and pk.id_pickup like 'PCK-ACU-%-' || v_bstr
        and it->>'skuBase' = v_sku
        and wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')) > 0
    ) into v_hoy;
    if v_hoy then return new; end if;

    select jsonb_agg(jsonb_build_object('zona', z.zona, 'bucket', z.bucket, 'pend', z.pend) order by z.bucket desc),
           max(z.nombre)
      into v_zonas, v_nom
      from (
        select coalesce(pk.id_zona,'') as zona, right(pk.id_pickup,10) as bucket,
               wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')) as pend,
               it->>'nombre' as nombre
          from wh.pickups pk
          cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
         where pk.fuente = 'ACUMULADO_SEMANAL'
           and upper(coalesce(pk.estado,'')) = 'REZAGADO'
           and right(pk.id_pickup,10) ~ '^\d{4}-\d{2}-\d{2}$'
           and to_date(right(pk.id_pickup,10),'YYYY-MM-DD') >= v_bucket - 28
           and to_date(right(pk.id_pickup,10),'YYYY-MM-DD') <  v_bucket
           and it->>'skuBase' = v_sku
           and wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')) > 0
      ) z;
    if v_zonas is null or jsonb_array_length(v_zonas) = 0 then return new; end if;

    insert into wh.considerados (sku_base, nombre, id_guia, guia_tipo, cod_ingreso, cant_ingresada, zonas)
    values (v_sku, coalesce(nullif(btrim(v_nom),''), v_sku), new.id_guia, v_tipo, new.cod_producto,
            coalesce(new.cant_recibida, new.cantidad_aplicada, 0), v_zonas)
    on conflict (sku_base) where estado = 'ACTIVO' do nothing;
    get diagnostics v_ins = row_count;

    if v_ins > 0 then
      v_txt := (select string_agg((z->>'zona') || ' quedó debiendo ' || (z->>'pend'), ' · ')
                  from jsonb_array_elements(v_zonas) z);
      v_tit    := '🎯 Ingresó ' || coalesce(nullif(btrim(v_nom),''), v_sku);
      v_cuerpo := 'Considera enviarlo: ' || coalesce(v_txt, 'fue solicitado en semanas pasadas');
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('apps', jsonb_build_array('warehouseMos')),
        'titulo', v_tit, 'cuerpo', v_cuerpo,
        'data', jsonb_build_object('tipo','considerado','sku', v_sku)));
      -- [795] SOLO roles: la audiencia combina con OR, así que agregar apps:[MOS]
      -- alcanzaba a los 12 dispositivos MOS en vez de a los 8 admins.
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('ADMIN','ADMINISTRADOR','MASTER')),
        'titulo', v_tit, 'cuerpo', v_cuerpo,
        'data', jsonb_build_object('tipo','considerado','sku', v_sku)));
    end if;
  exception when others then
    null;
  end;
  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- (6) [BAJO · preventivo] Candado de unicidad en equivalencias activas. Hoy no hay
-- duplicados (verificado), pero sin este índice el día que se registre el mismo código
-- en dos equivalencias el doble LEFT JOIN multiplicaría filas y `stockWh`, los despachos
-- y `ingresos_recientes` empezarían a SUMAR DE MÁS en silencio.
do $$
begin
  create unique index if not exists ux_equiv_codigo_barra_activa
    on mos.equivalencias (btrim(codigo_barra)) where activo is true;
exception when others then
  raise warning '[795] no se pudo crear ux_equiv_codigo_barra_activa (¿duplicados?): %', sqlerrm;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- (7) [MEDIO · limpieza] `replica identity full` en mos.membrete_cola infla el WAL de
-- cada UPDATE guardando la fila vieja completa, y NADIE consume realtime (ninguna app
-- inyecta el hook; además RLS está ON con 0 policies, así que no llegaría ningún evento).
-- Se vuelve al default. La tabla queda en la publicación por si se activa más adelante.
alter table mos.membrete_cola replica identity default;
