-- ============================================================================
-- 1016_prov_alertas_pedidos.sql — Alertas de pedido por proveedor (04-sep)
-- ----------------------------------------------------------------------------
-- Punto de pedido = ALMACÉN. Si a un producto le falta stock para la semana (criterio de
-- Zona: meta demand-flow 1sem+20% que YA contempla el envasado de derivados, comparada
-- contra el stock del almacén), el proveedor que lo vende entra en ALERTA.
--   · mos._meta_smart       — port EXACTO de _zonaMetaSmart (front) al servidor.
--   · mos.prov_alertas      — por proveedor: cuántos productos por pedir + top + si TOCA HOY
--                             (dia_pedido = hoy). Lo consumen los badges del front.
--   · mos.cron_prov_pedidos_hoy — 1 push/día (8am Lima) a MASTER+ADMIN: los proveedores que
--                             tocan pedir HOY con lo que falta. Cooldown por día (config).
-- Reusa mos.almacen_demanda_bulk (misma serie sem[4]+stock por sku que usa Zona/Proveedores).
-- ============================================================================

-- ── port de _zonaMetaSmart (front) ──────────────────────────────────────────
create or replace function mos._meta_smart(picos numeric[], colchon numeric default 0.20)
returns numeric language plpgsql immutable as $fn$
declare
  n int := coalesce(array_length(picos,1),0);
  col numeric := coalesce(colchon,0.20);
  last numeric; cnt int; wsum numeric := 0; w numeric := 0; avgp numeric; mx numeric; slope numeric; base numeric; i int;
begin
  if n = 0 then return 0; end if;
  last := picos[n];
  select count(*) into cnt from unnest(picos) x where x > 0;
  if cnt < 2 then return ceil(greatest(0,last)*(1+col)); end if;             -- sin historial real → última × colchón
  for i in 1..n loop wsum := wsum + picos[i]*i; w := w + i; end loop;         -- promedio ponderado (recientes pesan más)
  avgp := case when w > 0 then wsum/w else last end;
  select max(x) into mx from unnest(picos) x;
  slope := (last - picos[1])/(n-1);
  base := least(mx, greatest(last, avgp));                                    -- nunca por debajo de lo que vendes
  if slope > 0.05*greatest(1,last) then base := least(mx*1.25, greatest(base, last + greatest(0,slope)));   -- sube: proyecta, capeado
  elsif slope < -0.05*greatest(1,last) then base := greatest(last, avgp*0.9); -- baja: no sobre-stockear
  end if;
  return ceil(greatest(0,base)*(1+col));
end $fn$;

-- ── faltantes por sku (meta − stock almacén) reusando el bulk ───────────────
create or replace function mos.almacen_faltantes()
returns table(sku text, meta numeric, stock numeric, falta numeric)
language plpgsql security definer set search_path to '' as $fn$
declare v_items jsonb;
begin
  v_items := coalesce((mos.almacen_demanda_bulk('{}'::jsonb))->'data'->'items', '[]'::jsonb);
  return query
    select f.sku, f.meta, f.stock, greatest(0, f.meta - f.stock) falta
    from (
      select upper(it->>'sku') sku,
             mos._meta_smart(array(select (e.value)::numeric from jsonb_array_elements_text(it->'sem') e), 0.20) meta,
             coalesce((it->>'stock')::numeric,0) stock
      from jsonb_array_elements(v_items) it
    ) f
    where f.meta > f.stock;
end $fn$;
revoke all on function mos.almacen_faltantes() from public, anon;
grant execute on function mos.almacen_faltantes() to authenticated, service_role;

-- ── día de hoy en el formato de mos.proveedores.dia_pedido (sin tildes, mayúsc) ──
create or replace function mos._dia_hoy_es()
returns text language sql stable as $fn$
  select (array['DOMINGO','LUNES','MARTES','MIERCOLES','JUEVES','VIERNES','SABADO'])
           [extract(dow from (now() at time zone 'America/Lima'))::int + 1];
$fn$;

-- ── alertas por proveedor (para los badges del front) ───────────────────────
create or replace function mos.prov_alertas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_hoy text := mos._dia_hoy_es(); v jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  create temporary table if not exists _falt on commit drop as select * from mos.almacen_faltantes();

  with pp as (
    select pv.id_proveedor, pv.nombre, pv.dia_pedido,
           upper(btrim(pr.sku_base)) sku,
           coalesce(nullif(pr.descripcion,''), pp.descripcion, pr.codigo_barra) nombre_prod,
           upper(coalesce(pr.unidad_medida,'')) uni
      from mos.proveedores pv
      join mos.proveedores_productos pp on pp.id_proveedor = pv.id_proveedor and coalesce(pp.activa,true)
      join mos.productos pr on upper(btrim(pr.codigo_barra)) = upper(btrim(pp.codigo_barra))
     where pv.nombre not ilike 'CARGADOR%'
  ),
  hit as (
    select pp.id_proveedor, pp.nombre, pp.dia_pedido,
           pp.nombre_prod, f.falta,
           case when pp.uni = 'KGM' then 'kg' else 'und' end uni
      from pp join _falt f on f.sku = pp.sku and f.falta > 0
  ),
  agg as (
    select id_proveedor, max(nombre) nombre, max(dia_pedido) dia_pedido,
           count(*) por_pedir,
           (upper(coalesce(max(dia_pedido),'')) = v_hoy) toca_hoy,
           coalesce(jsonb_agg(jsonb_build_object('nombre', nombre_prod, 'falta', round(falta,3), 'uni', uni)
                    order by falta desc) filter (where rn <= 6), '[]'::jsonb) items
      from (select *, row_number() over (partition by id_proveedor order by falta desc) rn from hit) h
     group by id_proveedor
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'idProveedor', id_proveedor, 'nombre', nombre, 'diaPedido', dia_pedido,
           'tocaHoy', toca_hoy, 'porPedir', por_pedir, 'items', items
         ) order by toca_hoy desc, por_pedir desc), '[]'::jsonb) into v
    from agg;

  return jsonb_build_object('ok', true, 'hoy', v_hoy,
    'proveedores', coalesce(v, '[]'::jsonb),
    'totalPorPedir', (select coalesce(jsonb_array_length(v),0)),
    'tocanHoy', (select count(*) from jsonb_array_elements(coalesce(v,'[]'::jsonb)) x where (x->>'tocaHoy')::boolean));
end $fn$;
revoke all on function mos.prov_alertas(jsonb) from public, anon;
grant execute on function mos.prov_alertas(jsonb) to authenticated, service_role;

-- ── CRON: aviso diario de "qué pedir hoy" a MASTER + ADMIN (8am Lima) ────────
create or replace function mos.cron_prov_pedidos_hoy()
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_hoy text := mos._dia_hoy_es();
  v_fecha text := to_char(now() at time zone 'America/Lima','YYYY-MM-DD');
  v_ya text; v_cuerpo text; v_n int := 0; v_prov text[] := '{}';
  r record;
begin
  -- 1 solo aviso por día (idempotente aunque el cron corra varias veces)
  select valor into v_ya from mos.config where clave = 'PROV_PEDIDOS_AVISO_DIA' limit 1;
  if coalesce(v_ya,'') = v_fecha then
    insert into mos.cron_log(job, ok, resultado) values ('prov_pedidos_hoy', true, jsonb_build_object('skip','ya avisado', 'dia', v_fecha));
    return jsonb_build_object('ok', true, 'skip', true);
  end if;

  create temporary table if not exists _falt on commit drop as select * from mos.almacen_faltantes();

  for r in
    with pp as (
      select pv.id_proveedor, pv.nombre, upper(btrim(pr.sku_base)) sku,
             coalesce(nullif(pr.descripcion,''), pr.codigo_barra) nombre_prod,
             case when upper(coalesce(pr.unidad_medida,''))='KGM' then 'kg' else 'und' end uni
        from mos.proveedores pv
        join mos.proveedores_productos pp on pp.id_proveedor = pv.id_proveedor and coalesce(pp.activa,true)
        join mos.productos pr on upper(btrim(pr.codigo_barra)) = upper(btrim(pp.codigo_barra))
       where pv.nombre not ilike 'CARGADOR%'
         and upper(coalesce(pv.dia_pedido,'')) = v_hoy
    )
    select pp.nombre,
           count(*) n,
           string_agg(pp.nombre_prod || ' ' || round(f.falta,2) || pp.uni, ', ' order by f.falta desc) det
      from pp join _falt f on f.sku = pp.sku and f.falta > 0
     group by pp.nombre
     order by count(*) desc
  loop
    v_n := v_n + 1;
    v_prov := v_prov || (r.nombre || ' (' || r.n || ')');
    if v_cuerpo is null then v_cuerpo := ''; end if;
    if length(v_cuerpo) < 320 then
      v_cuerpo := v_cuerpo || '• ' || upper(r.nombre) || ': ' || left(r.det, 90) || E'\n';
    end if;
  end loop;

  if v_n = 0 then
    insert into mos.cron_log(job, ok, resultado) values ('prov_pedidos_hoy', true, jsonb_build_object('proveedores',0,'dia',v_hoy));
    -- marca el día igual (no re-evaluar cada 10 min); el front igual muestra badges en vivo
    insert into mos.config(clave,valor) values ('PROV_PEDIDOS_AVISO_DIA', v_fecha)
      on conflict (clave) do update set valor = excluded.valor;
    return jsonb_build_object('ok', true, 'proveedores', 0);
  end if;

  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMIN','ADMINISTRADOR')),
      'titulo', '🏷 Pedidos de HOY (' || initcap(lower(v_hoy)) || ') · ' || v_n || ' proveedor' || case when v_n=1 then '' else 'es' end,
      'cuerpo', coalesce(v_cuerpo,'') || 'Abre Proveedores → arma el pre-pedido y envíalo.',
      'data', jsonb_build_object('tipo','prov_pedidos_hoy','n',v_n)));
  exception when others then null; end;

  insert into mos.config(clave,valor,descripcion) values
    ('PROV_PEDIDOS_AVISO_DIA', v_fecha, 'Último día (YYYY-MM-DD) en que se avisó los pedidos por proveedor — lo escribe mos.cron_prov_pedidos_hoy')
  on conflict (clave) do update set valor = excluded.valor;
  insert into mos.cron_log(job, ok, resultado) values ('prov_pedidos_hoy', true, jsonb_build_object('proveedores', v_n, 'lista', v_prov));
  return jsonb_build_object('ok', true, 'proveedores', v_n, 'lista', v_prov);
end $fn$;
revoke all on function mos.cron_prov_pedidos_hoy() from public, anon;
grant execute on function mos.cron_prov_pedidos_hoy() to service_role;

-- 8:00 am Lima = 13:00 UTC. Corre cada 10 min entre 8 y 11 am; el candado por día evita repetir.
select cron.schedule('prov-pedidos-hoy', '*/10 13-16 * * *', 'select mos.cron_prov_pedidos_hoy();')
  where not exists (select 1 from cron.job where jobname = 'prov-pedidos-hoy');

select '1016 prov alertas listo' ok;
