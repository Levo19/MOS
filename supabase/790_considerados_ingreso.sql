-- 790_considerados_ingreso.sql — [CONSIDERADOS + PRIORIZADO por ingreso de mercadería]
-- Modelo del dueño (2026-08-15): cuando ENTRA mercadería al almacén (guía INGRESO_PROVEEDOR
-- o INGRESO_ENVASADO), cruzar cada línea (sku canónico, equivalentes incluidos) contra la
-- deuda de las zonas:
--   · ¿Alguna zona lo debe ESTA semana (acumulado vivo)? → PRIORIZADO: no se notifica ni
--     entra a considerados; el semáforo de MOS/WH lo pinta con el matiz "🆕 ingresó" usando
--     wh.ingresos_recientes (computado al leer, cero estado).
--   · ¿NO se debe hoy pero SÍ quedó debiendo en los REZAGADOS de las últimas 4 semanas?
--     → CONSIDERADO: fila en wh.considerados + push a TODOS los operadores WH y a los
--     admins de MOS ("Ingresó X · considera enviarlo, alguna vez lo pidieron").
-- El trigger va sobre wh.guia_detalle (cubre TODOS los caminos de ingreso, línea a línea)
-- y está blindado: cualquier error se traga — un ingreso JAMÁS se bloquea por esto.

-- ── tabla ──
create table if not exists wh.considerados (
  id              bigserial primary key,
  sku_base        text not null,
  nombre          text,
  id_guia         text,
  guia_tipo       text,
  cod_ingreso     text,
  cant_ingresada  numeric default 0,
  zonas           jsonb default '[]'::jsonb,   -- [{zona, bucket, pend}] semanas que quedaron debiendo
  estado          text not null default 'ACTIVO',   -- ACTIVO | ATENDIDO | DESCARTADO | VENCIDO
  creado          timestamptz not null default now(),
  resuelto_por    text,
  resuelto_ts     timestamptz
);
create unique index if not exists ux_wh_considerados_activo on wh.considerados (sku_base) where estado = 'ACTIVO';
create index if not exists ix_wh_considerados_estado on wh.considerados (estado, creado desc);

-- ── trigger: cruce al ingresar una línea de guía ──
create or replace function wh.tg_considerado_ingreso() returns trigger
language plpgsql security definer set search_path to ''
as $$
declare
  v_tipo   text;
  v_sku    text;
  v_nom    text;
  v_bucket date;
  v_bstr   text;
  v_hoy    boolean := false;
  v_zonas  jsonb;
  v_ins    int := 0;
  v_txt    text;
  v_tit    text;
  v_cuerpo text;
begin
  begin
    select tipo into v_tipo from wh.guias where id_guia = new.id_guia;
    if v_tipo is null or v_tipo not in ('INGRESO_PROVEEDOR','INGRESO_ENVASADO') then return new; end if;

    -- sku canónico: productos + EQUIVALENTES (mismo join que todo el ecosistema)
    select coalesce(pr.sku_base, eq.sku_base) into v_sku
      from (select 1) x
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(new.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(new.cod_producto,''));
    if v_sku is null or btrim(v_sku) = '' then return new; end if;

    v_bucket := wh._bucket_dom((now() at time zone 'America/Lima')::date);
    v_bstr   := to_char(v_bucket, 'YYYY-MM-DD');

    -- ¿Se debe ESTA semana en algún acumulado vivo? → PRIORIZADO (lo pinta el front). Fin.
    select exists (
      select 1 from wh.pickups pk
      cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
      where pk.fuente = 'ACUMULADO_SEMANAL'
        and pk.id_pickup like 'PCK-ACU-%-' || v_bstr
        and it->>'skuBase' = v_sku
        and wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')) > 0
    ) into v_hoy;
    if v_hoy then return new; end if;

    -- ¿Quedó debiendo en los REZAGADOS de las últimas 4 semanas?
    select jsonb_agg(jsonb_build_object('zona', z.zona, 'bucket', z.bucket, 'pend', z.pend) order by z.bucket desc),
           max(z.nombre)
      into v_zonas, v_nom
      from (
        select coalesce(pk.id_zona,'') as zona,
               right(pk.id_pickup,10)  as bucket,
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

    -- Un solo considerado ACTIVO por sku (ingresos repetidos no duplican ni re-notifican).
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
      -- Todos los operadores de WH
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('apps', jsonb_build_array('warehouseMos')),
        'titulo', v_tit, 'cuerpo', v_cuerpo,
        'data', jsonb_build_object('tipo','considerado','sku', v_sku)));
      -- Admins de MOS
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('apps', jsonb_build_array('MOS'),
                                        'roles', jsonb_build_array('ADMIN','ADMINISTRADOR','MASTER')),
        'titulo', v_tit, 'cuerpo', v_cuerpo,
        'data', jsonb_build_object('tipo','considerado','sku', v_sku)));
    end if;
  exception when others then
    null;   -- blindaje: el ingreso NUNCA se bloquea por el cruce
  end;
  return new;
end;
$$;

drop trigger if exists tg_considerado_ingreso on wh.guia_detalle;
create trigger tg_considerado_ingreso
  after insert on wh.guia_detalle
  for each row execute function wh.tg_considerado_ingreso();

-- ── RPC: lista para la card de WH (expira lazy los ACTIVOS >7 días) ──
create or replace function wh.considerados_listar(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_items jsonb;
begin
  update wh.considerados set estado = 'VENCIDO'
   where estado = 'ACTIVO' and creado < now() - interval '7 days';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'skuBase', sku_base, 'nombre', nombre,
           'cant', cant_ingresada, 'zonas', zonas, 'guiaTipo', guia_tipo,
           'creado', to_char(creado at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI')
         ) order by creado desc), '[]'::jsonb)
    into v_items
    from wh.considerados
   where estado = 'ACTIVO'
   limit 50;

  return jsonb_build_object('ok', true, 'items', v_items,
    'total', (select count(*) from wh.considerados where estado = 'ACTIVO'));
end;
$$;

-- ── RPC: resolver (botones ✔ Atendido / ✕ Descartar de la card) ──
create or replace function wh.considerado_resolver(p jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_id  bigint := (p->>'id')::bigint;
  v_est text   := upper(coalesce(p->>'estado',''));
  v_n   int;
begin
  if v_est not in ('ATENDIDO','DESCARTADO') then
    return jsonb_build_object('ok', false, 'error', 'estado inválido');
  end if;
  update wh.considerados
     set estado = v_est, resuelto_por = coalesce(p->>'usuario',''), resuelto_ts = now()
   where id = v_id and estado = 'ACTIVO';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0, 'resueltos', v_n);
end;
$$;

-- ── RPC: ingresos recientes por sku (chips PRIORIZADO en MOS y WH) ──
create or replace function wh.ingresos_recientes(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_dias int := least(greatest(coalesce((p->>'dias')::int, 3), 1), 14);
  v_items jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', q.sku,
           'ts', to_char(q.ts at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI'),
           'cant', q.cant)), '[]'::jsonb)
    into v_items
    from (
      select coalesce(pr.sku_base, eq.sku_base) as sku,
             max(coalesce(gd.created_at, g.fecha)) as ts,
             sum(coalesce(gd.cant_recibida, gd.cantidad_aplicada, 0)) as cant
        from wh.guias g
        join wh.guia_detalle gd on gd.id_guia = g.id_guia
        left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
        left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
       where g.tipo in ('INGRESO_PROVEEDOR','INGRESO_ENVASADO')
         and g.fecha > now() - make_interval(days => v_dias)
         and coalesce(pr.sku_base, eq.sku_base) is not null
       group by 1
    ) q;
  return jsonb_build_object('ok', true, 'dias', v_dias, 'items', v_items);
end;
$$;

grant execute on function wh.considerados_listar(jsonb)  to anon, authenticated, service_role;
grant execute on function wh.considerado_resolver(jsonb) to anon, authenticated, service_role;
grant execute on function wh.ingresos_recientes(jsonb)   to anon, authenticated, service_role;
