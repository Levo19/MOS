-- 141_mos_reconciliar_stock.sql — [ASEGURAR LA DATA · RECONCILIACIÓN DE STOCK ZONA+ALMACÉN] — SOLO LECTURA/DIAGNÓSTICO
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- QUÉ HACE (nada de esto MUTA stock real; solo reporta diferencias en una tabla de diagnóstico):
--   1) Tabla nueva  mos.stock_diferencias        — bitácora de descuadres (real vs teórico) por ámbito+producto+día.
--   2) RPC  mos.reconciliar_stock(p)             — calcula real vs teórico y persiste las diferencias con |dif|>umbral.
--        · ZONA    : real = me.stock_zonas.cantidad ; teórico = ANCLA(última auditoría) + guías posteriores
--                    − ventas posteriores (sin doble-contar las guías SALIDA_VENTAS). Es exactamente el saldo
--                    final del modelo de me.zona_kardex_historial (140), recomputado por código.
--        · ALMACEN : real = wh.stock.cantidad_disponible ; teórico = corte + Σ(delta kardex posterior al corte)
--                    (modelo supabase/73 wh.auditar_cuadre_stock). Además se reporta el último saldo del kardex
--                    (wh.stock_movimientos.stock_despues) como segundo testigo (campo saldo_kardex en detalle).
--   3) RPC  mos.stock_diferencias_listar(p)      — LECTURA para el botón master "Log de errores".
--   4) pg_cron 'riz-reconciliar-stock'           — nocturno 02:30 Lima (07:30 UTC). Reusa patrón 130/138.
--
-- POR QUÉ ES SEGURO:
--   · La RPC NO escribe en me.stock_zonas / wh.stock / kardex / ajustes / guías / ventas. Solo INSERTA/UPSERTEA
--     en mos.stock_diferencias (tabla nueva de diagnóstico que nadie más toca). Es un REPORTE, no una corrección.
--   · No toca flags/sync/GAS/cerrar_guia ni ninguna RPC de dinero. No cambia el comportamiento de hoy.
--   · El cron nace ACTIVO (como 130) porque su efecto es inerte: solo materializa la bitácora de diagnóstico;
--     el botón master que la lee está gated por rol='master' en el frontend, y el módulo zona por su propio flag.
--
-- GATES (patrón del proyecto):
--   security definer + search_path='' + revoke public + grants service_role/authenticated.
--   Las RPCs mos.* exigen mos._claim_ok() (app='MOS' o service_role/GAS). Lecturas anexan mos._frescura_sombra().
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;
create extension if not exists pg_cron;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) TABLA — mos.stock_diferencias (bitácora de descuadres). Idempotente por (ambito, zona_id, cod_barra, dia).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists mos.stock_diferencias (
  id               bigint generated always as identity primary key,
  ambito           text        not null,                 -- 'ZONA' | 'ALMACEN'
  zona_id          text        not null default '',      -- '' para ALMACEN (clave estable; no nulos en la uq)
  cod_barra        text        not null,
  descripcion      text,
  real_qty         numeric(20,3),                          -- stock real observado (me.stock_zonas | wh.stock)
  teorico_qty      numeric(20,3),                          -- stock teórico reconstruido (ancla+delta | corte+delta)
  diferencia       numeric(20,3),                          -- real − teorico (firmado)
  motivo_hipotesis text,                                   -- texto humano: hipótesis de la causa
  detalle          jsonb       not null default '{}'::jsonb, -- testigos extra (p.ej. saldo_kardex en ALMACEN)
  dia              date        not null,                   -- día de negocio Lima de la corrida (clave idempotencia)
  detectado_ts     timestamptz not null default now(),
  estado           text        not null default 'ABIERTA' -- ABIERTA | REVISADA (el master puede archivar a futuro)
);

-- Idempotencia: una diferencia por (ámbito, zona, código, día). Re-correr el mismo día actualiza, no duplica.
create unique index if not exists uq_mos_stockdif_dia
  on mos.stock_diferencias (ambito, zona_id, cod_barra, dia);
create index if not exists ix_mos_stockdif_listar
  on mos.stock_diferencias (ambito, abs(diferencia) desc, detectado_ts desc);

alter table mos.stock_diferencias enable row level security;   -- sin policies → solo SECURITY DEFINER/service_role.
revoke all on table mos.stock_diferencias from anon, authenticated;
grant all on table mos.stock_diferencias to service_role;

comment on table mos.stock_diferencias is
  'Bitácora de descuadres real vs teórico (ZONA: ancla-auditoría+guías−ventas; ALMACEN: corte+delta). '
  'SOLO diagnóstico: la pueblan mos.reconciliar_stock / el cron riz-reconciliar-stock. No corrige stock.';

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1b) UMBRAL configurable (mos.config.MOS_RECON_UMBRAL). Default 0.5 (igual que wh.auditar_cuadre_stock).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos._recon_umbral()
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v numeric;
begin
  begin
    select nullif(btrim(valor),'')::numeric into v from mos.config where clave = 'MOS_RECON_UMBRAL' limit 1;
  exception when others then v := null;
  end;
  v := coalesce(v, 0.5);
  if v < 0 then v := 0.5; end if;
  return v;
end;
$fn$;
revoke all on function mos._recon_umbral() from public;
grant execute on function mos._recon_umbral() to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2a) HELPER — mos._recon_teorico_zona(zona, codes[]) → numeric
--     Recomputa el saldo teórico de un código (o grupo multi-barcode) en una zona con el MISMO modelo que
--     me.zona_kardex_historial (140): saldo corrido cronológico con RE-ANCLA en cada auditoría (set-absoluto),
--     guías SALIDA_VENTAS informativas (no suman, ventas_detalle es la fuente de salida por venta), ventas no
--     anuladas restan. El saldo final = teórico. NO lee me.stock_zonas (eso es el "real").
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos._recon_teorico_zona(p_zona text, p_codes text[])
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_ev    me._kardex_evento[];
  v_e     me._kardex_evento;
  v_run   numeric(20,3) := 0;
begin
  with eventos as (
    -- AUDITORIA (set absoluto → re-ancla a cant_real)
    select a.fecha, 'AUDITORIA'::text as tipo, (a.cant_real - a.cant_sistema) as delta,
           a.cant_real as saldo_set, true as es_set, true as aplicado,
           coalesce(a.vendedor,'—') as usuario, ''::text as id_guia, 'auditoria'::text as fuente
      from me.auditorias a
     where a.zona_id = p_zona and a.cod_barras = any(p_codes)
    union all
    -- GUÍAS (SALIDA_VENTAS informativa: no suma; ventas_detalle es la fuente real de la salida por venta)
    select gc.fecha,
           case
             when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%' then 'TRASLADO_IN'
             when gc.tipo = 'SALIDA_JEFA' then 'SALIDA_JEFA'
             when gc.tipo like '%MOVIMIENTO%' or gc.tipo like 'TRASLADO%' then 'TRASLADO_OUT'
             when gc.tipo = 'SALIDA_VENTAS' then 'SALIDA_VENTA'
             else 'SALIDA_JEFA'
           end as tipo,
           case when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%'
                then gd.cantidad else -gd.cantidad end as delta,
           null::numeric as saldo_set, false as es_set,
           (gc.tipo <> 'SALIDA_VENTAS') as aplicado,           -- guías de venta NO suman (anti-doble-conteo)
           coalesce(gc.vendedor,'—') as usuario, gc.id_guia as id_guia, 'guia'::text as fuente
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = p_zona and gd.cod_barras = any(p_codes)
    union all
    -- VENTAS (no anuladas) = SALIDA_VENTA
    select v.fecha, 'SALIDA_VENTA'::text as tipo, -vd.cantidad as delta,
           null::numeric as saldo_set, false as es_set, true as aplicado,
           coalesce(v.vendedor,'—') as usuario, v.id_venta as id_guia, 'venta'::text as fuente
      from me.ventas_detalle vd
      join me.ventas v on v.id_venta = vd.id_venta
     where v.zona_id = p_zona and vd.cod_barras = any(p_codes)
       and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  )
  select array_agg(
           row((e).fecha,(e).tipo,(e).delta,(e).saldo_set,(e).es_set,(e).aplicado,(e).usuario,(e).id_guia,(e).fuente)::me._kardex_evento
           order by (e).fecha asc, case when (e).es_set then 1 else 0 end, (e).tipo)
         into v_ev
    from eventos e;

  if v_ev is not null then
    foreach v_e in array v_ev loop
      if (v_e).es_set then
        v_run := (v_e).saldo_set;                 -- re-ancla
      elsif (v_e).aplicado then
        v_run := v_run + (v_e).delta;             -- acumula
      end if;                                      -- informativo (aplicado=false) → no mueve el saldo
    end loop;
  end if;
  return coalesce(v_run, 0);
end;
$fn$;
revoke all on function mos._recon_teorico_zona(text, text[]) from public;
grant execute on function mos._recon_teorico_zona(text, text[]) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2b) RPC — mos.reconciliar_stock(p {ambito?, zona?})
--     ambito ∈ {ZONA, ALMACEN}; ausente/'' → AMBOS. zona (opcional) acota la reconciliación de ZONA a una zona.
--     Persiste en mos.stock_diferencias las filas con |real − teorico| > umbral (UPSERT por ambito,zona,cod,dia).
--     Las que vuelven a cuadrar ese día se ELIMINAN (estado ABIERTA) para no dejar falsos positivos colgados.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.reconciliar_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_amb    text := upper(btrim(coalesce(p->>'ambito','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_umb    numeric := mos._recon_umbral();
  v_dia    date := (now() at time zone 'America/Lima')::date;
  v_n_zona int := 0;
  v_n_alm  int := 0;
  r        record;
  v_teo    numeric(20,3);
  v_dif    numeric(20,3);
  v_desc   text;
  v_hip    text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- ══ ZONA ════════════════════════════════════════════════════════════════════════════════════════════════
  if v_amb = '' or v_amb = 'ZONA' then
    -- universo: cada (zona, cod_barras) con stock de zona registrado. real = cantidad actual de me.stock_zonas.
    -- El grupo multi-barcode se trata por código individual (el ancla/guías/ventas son por cod_barras).
    for r in
      select upper(btrim(sz.zona_id)) as zona, btrim(sz.cod_barras) as cod,
             sum(coalesce(sz.cantidad,0)) as realq
        from me.stock_zonas sz
       where nullif(btrim(sz.cod_barras),'') is not null
         and nullif(btrim(sz.zona_id),'') is not null
         and (v_zona = '' or upper(btrim(sz.zona_id)) = v_zona)
       group by upper(btrim(sz.zona_id)), btrim(sz.cod_barras)
    loop
      v_teo := mos._recon_teorico_zona(r.zona, array[r.cod]);
      v_dif := coalesce(r.realq,0) - coalesce(v_teo,0);

      if abs(v_dif) > v_umb then
        select coalesce(nullif(btrim(pr.descripcion),''), r.cod) into v_desc
          from mos.productos pr where pr.codigo_barra = r.cod limit 1;
        v_desc := coalesce(v_desc, r.cod);
        v_hip := case
          when v_teo = 0 and r.realq <> 0 then 'Sin ancla de auditoría ni movimientos en la sombra para este código → teórico=0; falta auditar o sombra incompleta.'
          when v_dif > 0 then 'Sobrante físico: hay más en zona que lo que explican auditoría+guías−ventas (ventas no registradas / ingreso sin guía / mal conteo).'
          else 'Faltante físico: hay menos en zona que lo teórico (merma / venta no descontada / traslado sin guía).'
        end;

        insert into mos.stock_diferencias
          (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado)
        values
          ('ZONA', r.zona, r.cod, v_desc, r.realq, v_teo, v_dif, v_hip, '{}'::jsonb, v_dia, now(), 'ABIERTA')
        on conflict (ambito, zona_id, cod_barra, dia) do update set
          descripcion = excluded.descripcion, real_qty = excluded.real_qty,
          teorico_qty = excluded.teorico_qty, diferencia = excluded.diferencia,
          motivo_hipotesis = excluded.motivo_hipotesis, detectado_ts = now(),
          estado = case when mos.stock_diferencias.estado = 'REVISADA' then 'REVISADA' else 'ABIERTA' end;
        v_n_zona := v_n_zona + 1;
      else
        -- ya cuadra hoy → limpiar una diferencia ABIERTA previa del mismo día (no tocar las REVISADAS).
        delete from mos.stock_diferencias
         where ambito='ZONA' and zona_id=r.zona and cod_barra=r.cod and dia=v_dia and estado='ABIERTA';
      end if;
    end loop;
  end if;

  -- ══ ALMACEN ═════════════════════════════════════════════════════════════════════════════════════════════
  --   real = Σ wh.stock.cantidad_disponible (consolidado por cod_producto).
  --   teorico = corte(base) + Σ(delta del kardex posterior al corte) — modelo supabase/73.
  --   saldo_kardex (testigo) = último stock_despues del kardex por código.
  if v_amb = '' or v_amb = 'ALMACEN' then
    for r in
      with stk as (
        select btrim(cod_producto) cod, sum(coalesce(cantidad_disponible,0)) realq
          from wh.stock where btrim(coalesce(cod_producto,'')) <> '' group by btrim(cod_producto)
      ),
      corte as (
        select cod_producto cod, cantidad_base base, fecha_corte fc from wh.auditoria_corte
      ),
      mov as (
        select btrim(m.cod_producto) cod, sum(coalesce(m.delta,0)) d
          from wh.stock_movimientos m
          join corte c on c.cod = btrim(m.cod_producto)
         where m.fecha > c.fc
         group by btrim(m.cod_producto)
      ),
      kar as (   -- último saldo del libro mayor por producto (testigo secundario)
        select distinct on (btrim(m.cod_producto)) btrim(m.cod_producto) cod, m.stock_despues saldo
          from wh.stock_movimientos m
         where btrim(coalesce(m.cod_producto,'')) <> ''
         order by btrim(m.cod_producto), m.fecha desc, m.id_mov desc
      )
      select coalesce(s.cod, c.cod) as cod,
             coalesce(s.realq, 0)                          as realq,
             coalesce(c.base, 0) + coalesce(m.d, 0)        as teorico,
             k.saldo                                       as saldo_kardex,
             (c.cod is null)                               as sin_corte
        from stk s
        full outer join corte c on c.cod = s.cod
        left  join mov   m on m.cod = coalesce(s.cod, c.cod)
        left  join kar   k on k.cod = coalesce(s.cod, c.cod)
    loop
      v_dif := coalesce(r.realq,0) - coalesce(r.teorico,0);
      if abs(v_dif) > v_umb then
        select coalesce(nullif(btrim(pr.descripcion),''), r.cod) into v_desc
          from mos.productos pr where pr.codigo_barra = r.cod limit 1;
        v_desc := coalesce(v_desc, r.cod);
        v_hip := case
          when r.sin_corte then 'Producto sin snapshot de corte → teórico parcial; tomar/renovar corte de almacén.'
          when v_dif > 0 then 'Sobrante en almacén vs corte+delta del kardex (ingreso sin movimiento / corte desfasado).'
          else 'Faltante en almacén vs corte+delta del kardex (merma / salida sin movimiento / corte desfasado).'
        end;

        insert into mos.stock_diferencias
          (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado)
        values
          ('ALMACEN', '', r.cod, v_desc, r.realq, r.teorico, v_dif, v_hip,
           jsonb_build_object('saldoKardex', r.saldo_kardex, 'sinCorte', r.sin_corte), v_dia, now(), 'ABIERTA')
        on conflict (ambito, zona_id, cod_barra, dia) do update set
          descripcion = excluded.descripcion, real_qty = excluded.real_qty,
          teorico_qty = excluded.teorico_qty, diferencia = excluded.diferencia,
          motivo_hipotesis = excluded.motivo_hipotesis, detalle = excluded.detalle, detectado_ts = now(),
          estado = case when mos.stock_diferencias.estado = 'REVISADA' then 'REVISADA' else 'ABIERTA' end;
        v_n_alm := v_n_alm + 1;
      else
        delete from mos.stock_diferencias
         where ambito='ALMACEN' and zona_id='' and cod_barra=r.cod and dia=v_dia and estado='ABIERTA';
      end if;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'dia', to_char(v_dia,'YYYY-MM-DD'),
    'umbral', v_umb, 'difZona', v_n_zona, 'difAlmacen', v_n_alm,
    'total', v_n_zona + v_n_alm);
end;
$fn$;
revoke all on function mos.reconciliar_stock(jsonb) from public;
grant execute on function mos.reconciliar_stock(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 3) RPC — mos.stock_diferencias_listar(p {ambito?, zona?, estado?}) — LECTURA (botón master "Log de errores").
--     Devuelve {ok, data:{total, items:[{ambito,zonaId,codBarra,descripcion,real,teorico,diferencia,
--     motivoHipotesis,detalle,dia,detectadoTs,estado}]}, _fresh...}. Orden: |diferencia| desc, fecha desc.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.stock_diferencias_listar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_amb  text := nullif(upper(btrim(coalesce(p->>'ambito',''))),'');
  v_zona text := nullif(upper(btrim(coalesce(p->>'zona',''))),'');
  v_est  text := nullif(upper(btrim(coalesce(p->>'estado',''))),'');
  v_arr  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',              d.id,
           'ambito',          d.ambito,
           'zonaId',          d.zona_id,
           'codBarra',        d.cod_barra,
           'descripcion',     coalesce(d.descripcion, d.cod_barra),
           'real',            d.real_qty,
           'teorico',         d.teorico_qty,
           'diferencia',      d.diferencia,
           'motivoHipotesis', coalesce(d.motivo_hipotesis,''),
           'detalle',         coalesce(d.detalle,'{}'::jsonb),
           'dia',             to_char(d.dia,'YYYY-MM-DD'),
           'detectadoTs',     to_char(d.detectado_ts at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'estado',          d.estado
         ) order by abs(d.diferencia) desc, d.detectado_ts desc), '[]'::jsonb) into v_arr
    from mos.stock_diferencias d
   where (v_amb  is null or d.ambito = v_amb)
     and (v_zona is null or d.zona_id = v_zona)
     and (v_est  is null or d.estado = v_est);

  return jsonb_build_object('ok', true, 'data',
           jsonb_build_object('total', jsonb_array_length(v_arr), 'items', v_arr))
         || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.stock_diferencias_listar(jsonb) from public;
grant execute on function mos.stock_diferencias_listar(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 4) WRAPPER — mos.almacen_kardex_historial(p {codBarra | skuBase}) — LECTURA del kardex de ALMACÉN (wh).
--     wh.stock_movimientos NO es alcanzable por el front (profile 'mos'); este definer lo lee por cod_producto
--     (base + equivalentes, igual que getHistorialStock) y devuelve el MISMO shape que mos.zona_kardex_historial.
--     Saldo = dato (stock_despues del kardex), no recálculo. Orden fecha desc.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.almacen_kardex_historial(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_cod   text := nullif(btrim(coalesce(p->>'codBarra','')),'');
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_codes text[];
  v_movs  jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- Resolver el conjunto de códigos: WH solo maneja canónicos (codigo_barra) + equivalentes activos.
  if v_cod is not null then
    -- incluir equivalentes que cuelgan del mismo sku_base de este código (grupo multi-barcode de WH)
    select coalesce(array_agg(distinct c), array[v_cod]) into v_codes
      from (
        select v_cod as c
        union all
        select upper(btrim(ev.codigo_barra))
          from mos.equivalencias ev
         where coalesce(ev.activo,true)
           and ev.sku_base in (select pr.sku_base from mos.productos pr where pr.codigo_barra = v_cod)
           and nullif(btrim(ev.codigo_barra),'') is not null
      ) q;
  elsif v_sku is not null then
    select coalesce(array_agg(distinct c), array[]::text[]) into v_codes
      from (
        select pr.codigo_barra c from mos.productos pr where pr.sku_base = v_sku and pr.codigo_barra is not null
        union all
        select upper(btrim(ev.codigo_barra)) from mos.equivalencias ev
         where coalesce(ev.activo,true) and ev.sku_base = v_sku and nullif(btrim(ev.codigo_barra),'') is not null
      ) q;
    if coalesce(array_length(v_codes,1),0) = 0 then
      return jsonb_build_object('ok', false, 'error', 'skuBase sin codigo_barra en catálogo');
    end if;
    v_cod := v_codes[1];
  else
    return jsonb_build_object('ok', false, 'error', 'Requiere codBarra o skuBase');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'idGuia',        coalesce(m.origen,''),                         -- origen = idGuia para movs de guía
      'fecha',         m.fecha,
      'tipo',          me._kardex_label(
                          case
                            when upper(coalesce(m.tipo_operacion,'')) like '%AUDITORIA%' then 'AUDITORIA'
                            when upper(coalesce(m.tipo_operacion,'')) like '%AJUSTE%'    then 'AJUSTE'
                            when upper(coalesce(m.tipo_operacion,'')) like '%ENVASADO%'  then 'ENVASADO'
                            when upper(coalesce(m.tipo_operacion,'')) like '%INICIAL%'   then 'INICIAL'
                            else (case when coalesce(m.delta,0) >= 0 then 'INGRESO' else 'SALIDA' end)
                          end, coalesce(m.delta,0)),
      'tipoOperacion', coalesce(m.tipo_operacion,''),
      'esIngreso',     (coalesce(m.delta,0) > 0),
      'cantidad',      abs(coalesce(m.delta,0)),
      'saldo',         m.stock_despues,
      'stockAntes',    m.stock_antes,
      'usuario',       coalesce(nullif(btrim(m.usuario),''),'—'),
      'origen',        coalesce(m.origen,''),
      'estado',        'CERRADA',
      'fuente',        case when upper(coalesce(m.tipo_operacion,'')) like '%AJUSTE%'
                             or upper(coalesce(m.tipo_operacion,'')) like '%AUDITORIA%' then 'ajuste' else 'guia' end,
      'aplicado',      true,
      'idLote',        null
    ) order by m.fecha desc, m.id_mov desc), '[]'::jsonb) into v_movs
  from wh.stock_movimientos m
  where btrim(m.cod_producto) = any(v_codes);

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'ambito', 'ALMACEN', 'codBarra', v_cod, 'codBarras', to_jsonb(v_codes), 'skuBase', v_sku,
      'reconstruido', false, 'totalMovimientos', jsonb_array_length(v_movs),
      'movimientos', v_movs)) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.almacen_kardex_historial(jsonb) from public;
grant execute on function mos.almacen_kardex_historial(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 5) WRAPPER de CRON — mos.cron_reconciliar_stock(). Sin args. Reconcilia AMBOS ámbitos. Loguea en mos.cron_log.
--    Envuelto en begin/exception → NUNCA propaga error a pg_cron.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists mos.cron_log (
  id        bigint generated always as identity primary key,
  ts        timestamptz not null default now(),
  job       text        not null,
  ok        boolean,
  resultado jsonb
);

create or replace function mos.cron_reconciliar_stock()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_res jsonb;
begin
  v_res := mos.reconciliar_stock('{}'::jsonb);
  insert into mos.cron_log(job, ok, resultado)
    values ('reconciliar_stock', coalesce((v_res->>'ok')::boolean,false), v_res);
  return v_res;
exception when others then
  insert into mos.cron_log(job, ok, resultado)
    values ('reconciliar_stock', false, jsonb_build_object('excepcion', SQLERRM));
  return jsonb_build_object('ok', false, 'error', 'excepcion', 'detalle', SQLERRM);
end;
$fn$;
revoke all on function mos.cron_reconciliar_stock() from public, anon, authenticated;
grant execute on function mos.cron_reconciliar_stock() to service_role;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 6) AGENDA pg_cron — 'riz-reconciliar-stock' nocturno 02:30 Lima (= 07:30 UTC, Perú UTC-5 fijo).
--    Idempotente (desagenda si existía). Queda ACTIVO (efecto inerte: solo materializa la bitácora de diagnóstico).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
select cron.unschedule('riz-reconciliar-stock') where exists (select 1 from cron.job where jobname='riz-reconciliar-stock');
select cron.schedule('riz-reconciliar-stock', '30 7 * * *', $$ select mos.cron_reconciliar_stock(); $$);
