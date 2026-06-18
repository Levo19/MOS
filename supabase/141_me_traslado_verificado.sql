-- 141_me_traslado_verificado.sql — TRASLADO VERIFICADO almacén→zona por ESCANEO (esquema me) — ADITIVO / INERTE-AL-STOCK
-- Diseño: flujo confirmado con el dueño (ver REPORTE). Construye SOBRE la fundación del kardex (140_me_kardex_zona).
--
-- ── QUÉ HACE ───────────────────────────────────────────────────────────────────────────────────────────────
--   El almacén central (WH) emite hacia una zona una guía de ENTRADA (en me.guias_cabecera estos despachos
--   llegan como tipo 'ENTRADA_ALMACEN' / 'ENTRADA_TRASLADO' / 'ENTRADA_LIBRE', con zona_id = la zona que RECIBE
--   y líneas en me.guias_detalle = {cod_barras, cantidad ENVIADA}). El QR de la guía codifica su id_guia.
--   El operador de la zona escanea esa guía y luego escanea PRODUCTO POR PRODUCTO lo que físicamente llegó.
--   Al "Cerrar ingreso" la PC compara ENVIADO (guía) vs ESCANEADO (real) → completo / incompleto + diferencia.
--
--   1) Tabla nueva me.zona_traslado_verificacion — 1 fila por guía verificada (enviado/escaneado/dif/estado +
--      detalle jsonb por producto). Idempotente por id_guia (PK).
--   2) RPC me.zona_traslados_pendientes(p {zona}) — LECTURA: guías de ENTRADA de esa zona que aún NO se
--      verificaron (sin fila en zona_traslado_verificacion), con antigüedad (segundos/edadLbl) para el cronómetro.
--   3) RPC me.zona_traslado_guia(p {idGuia}) — LECTURA: cabecera + líneas (producto, cantidad enviada) para
--      auto-jalar la guía al abrir el escaneo. (La cantidad enviada NO se muestra al operador en el front; se usa
--      sólo para el resumen al cerrar — pero la RPC la devuelve porque el front la necesita para la comparación.)
--   4) RPC me.zona_traslado_cerrar(p {idGuia, escaneados:[{codBarra,cantidad}], usuario}) — ESCRITURA:
--        a) registra cada escaneado en el KARDEX (me.zona_kardex_registrar, tipo TRASLADO_IN, ref por línea de guía),
--        b) calcula completo/incompleto comparando enviado vs escaneado,
--        c) persiste el resultado en me.zona_traslado_verificacion.
--      Idempotente por idGuia (si ya está verificada, devuelve {ok:true, dedup:true, data:<verificación existente>}).
--   5) RPC me.zona_traslados_resumen(p {zona}) — LECTURA: conteo ✓completo / ⚠incompleto / ⏳pendiente + el
--      detalle por guía (enviado vs escaneado) para el layout de resumen del módulo.
--   6) Wrappers mos.* (profile 'mos') — pass-through con gate, patrón 132/140.
--
-- ── GATE / INERTE AL STOCK REAL (⚠ EL PUNTO CLAVE) ──────────────────────────────────────────────────────────
--   Lo que ENTRA a la zona = lo ESCANEADO. Esa aplicación al SALDO real vive en me.stock_zonas. En esta entrega
--   esa MUTACIÓN queda **GATED / INERTE**: zona_traslado_cerrar registra el kardex + la verificación, pero NO
--   toca me.stock_zonas. El punto EXACTO donde se aplicaría está marcado con el bloque:
--        ┌─ [GATE-STOCK · INERTE] ─┐ ... └─ /GATE-STOCK ─┘
--   dentro de me.zona_traslado_cerrar (controlado por la variable v_aplicar_stock := false, hardcodeada OFF).
--   El kardex (me.stock_movimientos) SÍ se escribe — es un log de trazabilidad idempotente, no el saldo operativo
--   que leen las ventas; me.stock_zonas (saldo operativo) NO se toca. Para activar: poner v_aplicar_stock := true
--   tras la validación del dueño (ver REPORTE para el delta exacto).
--
-- ── POR QUÉ ES SEGURO ───────────────────────────────────────────────────────────────────────────────────────
--   · Tabla nueva, vacía, RLS habilitado sin políticas (service_role bypassa; RPCs definer escriben/leen).
--   · El kardex es la tabla 140 (vacía, jamás encendida) → escribir TRASLADO_IN no descuadra ningún saldo vivo.
--   · me.stock_zonas (lo que leen las ventas de ME) NO se toca (gate INERTE).
--   · No toca WH / flags / sync / cerrar_guia / dinero. Gate mos._claim_ok() en todo + módulo OFF en el front.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create schema if not exists mos;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) me.zona_traslado_verificacion — resultado de una verificación de traslado. 1 fila por guía (PK id_guia).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists me.zona_traslado_verificacion (
  id_guia        text primary key,
  zona_id        text not null,
  tipo_guia      text,                      -- ENTRADA_ALMACEN | ENTRADA_TRASLADO | ENTRADA_LIBRE | ...
  estado         text not null,             -- COMPLETO | INCOMPLETO
  total_enviado  numeric(20,3) not null default 0,
  total_escaneado numeric(20,3) not null default 0,
  total_dif      numeric(20,3) not null default 0,   -- enviado − escaneado (positivo = faltó; negativo = sobró)
  lineas_ok      int not null default 0,    -- # de productos donde escaneado == enviado
  lineas_dif     int not null default 0,    -- # de productos con diferencia
  detalle        jsonb,                     -- [{codBarra, descripcion, enviado, escaneado, dif, estado}]
  stock_aplicado boolean not null default false,  -- ⚠ ¿se aplicó a me.stock_zonas? (GATE: hoy SIEMPRE false)
  usuario        text,
  verificado_ts  timestamptz not null default now(),
  fecha_guia     timestamptz                -- fecha de emisión de la guía (para el cronómetro histórico)
);
create index if not exists ix_me_traslver_zona on me.zona_traslado_verificacion (zona_id, verificado_ts desc);
create index if not exists ix_me_traslver_estado on me.zona_traslado_verificacion (zona_id, estado);

alter table me.zona_traslado_verificacion enable row level security;
grant usage on schema me to service_role, anon, authenticated;
grant all on me.zona_traslado_verificacion to service_role;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2) me.zona_traslados_pendientes(p {zona, dias?}) — guías de ENTRADA aún no verificadas + su antigüedad.
--    Una guía es "de almacén hacia esta zona" si zona_id = la zona y tipo empieza con 'ENTRADA' (despacho WH→zona,
--    movimiento entre zonas o ingreso libre que igual hay que recibir/contar). Se excluyen las ya verificadas.
--    dias (default 30) acota la ventana para no listar histórico antiguo.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_traslados_pendientes(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona text := upper(btrim(coalesce(p->>'zona','')));
  v_dias int  := greatest(1, coalesce((p->>'dias')::int, 30));
  v_items jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  select coalesce(jsonb_agg(t order by t->>'fecha' desc), '[]'::jsonb) into v_items
  from (
    select jsonb_build_object(
        'idGuia',       g.id_guia,
        'tipoGuia',     g.tipo,
        'fecha',        g.fecha,
        'vendedor',     coalesce(g.vendedor,'—'),
        'observacion',  coalesce(g.observacion,''),
        'lineas',       count(d.*),
        'totalEnviado', coalesce(sum(d.cantidad),0),
        -- antigüedad para el cronómetro (segundos + etiqueta legible)
        'edadSeg',      floor(extract(epoch from (now() - g.fecha)))::bigint,
        'edadLbl',      me._edad_lbl(now() - g.fecha)
      ) as t
    from me.guias_cabecera g
    join me.guias_detalle  d on d.id_guia = g.id_guia
    where g.zona_id = v_zona
      and g.tipo like 'ENTRADA%'
      and g.fecha >= now() - make_interval(days => v_dias)
      and not exists (select 1 from me.zona_traslado_verificacion v where v.id_guia = g.id_guia)
    group by g.id_guia, g.tipo, g.fecha, g.vendedor, g.observacion
  ) s;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'zona', v_zona, 'dias', v_dias,
      'total', jsonb_array_length(v_items),
      'items', v_items)) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_traslados_pendientes(jsonb) from public;
grant execute on function me.zona_traslados_pendientes(jsonb) to service_role, authenticated;

-- ── helper: etiqueta legible de antigüedad ("hace 3 h", "hace 2 d") — usado por pendientes/resumen. ──────────
create or replace function me._edad_lbl(p_int interval)
returns text
language sql
immutable
as $fn$
  select case
    when p_int is null then '—'
    when extract(epoch from p_int) < 60         then 'recién'
    when extract(epoch from p_int) < 3600        then 'hace ' || floor(extract(epoch from p_int)/60)::int   || ' min'
    when extract(epoch from p_int) < 86400       then 'hace ' || floor(extract(epoch from p_int)/3600)::int || ' h'
    else 'hace ' || floor(extract(epoch from p_int)/86400)::int || ' d'
  end;
$fn$;
revoke all on function me._edad_lbl(interval) from public;
grant execute on function me._edad_lbl(interval) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 3) me.zona_traslado_guia(p {idGuia}) — cabecera + líneas (producto, cantidad enviada) para auto-jalar.
--    Enriquece cada línea con la descripción del catálogo (mos.productos por codigo_barra) cuando existe.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_traslado_guia(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_id   text := btrim(coalesce(p->>'idGuia',''));
  v_cab  me.guias_cabecera%rowtype;
  v_ver  me.zona_traslado_verificacion%rowtype;
  v_lineas jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  select * into v_cab from me.guias_cabecera where id_guia = v_id;
  if not found then return jsonb_build_object('ok',false,'error','Guía no encontrada: '||v_id); end if;

  -- ¿ya está verificada? (para que el front avise / muestre el resultado en vez de re-escanear).
  select * into v_ver from me.zona_traslado_verificacion where id_guia = v_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'linea',       d.linea,
      'codBarra',    d.cod_barras,
      'descripcion', coalesce(pr.descripcion, d.cod_barras),
      'enviado',     d.cantidad
    ) order by d.linea), '[]'::jsonb) into v_lineas
  from me.guias_detalle d
  left join lateral (
      select descripcion from mos.productos pr where pr.codigo_barra = d.cod_barras limit 1
  ) pr on true
  where d.id_guia = v_id;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'idGuia',     v_cab.id_guia,
      'tipoGuia',   v_cab.tipo,
      'zona',       v_cab.zona_id,
      'fecha',      v_cab.fecha,
      'vendedor',   coalesce(v_cab.vendedor,'—'),
      'observacion',coalesce(v_cab.observacion,''),
      'verificada', (v_ver.id_guia is not null),
      'verificacion', case when v_ver.id_guia is not null then to_jsonb(v_ver) else null end,
      'lineas',     v_lineas)) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_traslado_guia(jsonb) from public;
grant execute on function me.zona_traslado_guia(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 4) me.zona_traslado_cerrar(p {idGuia, escaneados:[{codBarra,cantidad}], usuario?, origen?}) — CIERRE.
--    · Idempotente por idGuia: si ya hay fila de verificación → {ok:true, dedup:true, data:<existente>}.
--    · Registra cada ESCANEADO en el kardex (TRASLADO_IN), ref por LÍNEA de guía o por código suelto.
--    · Compara enviado (guía) vs escaneado (real) por código → estado COMPLETO/INCOMPLETO + detalle.
--    · Persiste la verificación. ⚠ NO toca me.stock_zonas (GATE INERTE; ver bloque [GATE-STOCK]).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_traslado_cerrar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := btrim(coalesce(p->>'idGuia',''));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'MOS-PWA');
  v_cab    me.guias_cabecera%rowtype;
  v_zona   text;
  v_exist  me.zona_traslado_verificacion%rowtype;
  v_esc    jsonb := coalesce(p->'escaneados', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_linea  int;
  v_enviado_tot   numeric(20,3) := 0;
  v_escaneado_tot numeric(20,3) := 0;
  v_dif_tot       numeric(20,3) := 0;
  v_ok_n   int := 0;
  v_dif_n  int := 0;
  v_estado text;
  v_detalle jsonb := '[]'::jsonb;
  v_aplicar_stock boolean := false;   -- ⚠ [GATE-STOCK] hardcodeado OFF: NO aplica a me.stock_zonas todavía.
  v_row     me.zona_traslado_verificacion%rowtype;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  -- Dedup por guía (idempotente): si ya está verificada, no re-escribe.
  select * into v_exist from me.zona_traslado_verificacion where id_guia = v_id;
  if found then return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_exist)); end if;

  select * into v_cab from me.guias_cabecera where id_guia = v_id;
  if not found then return jsonb_build_object('ok',false,'error','Guía no encontrada: '||v_id); end if;
  v_zona := upper(btrim(coalesce(v_cab.zona_id,'')));
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Guía sin zona'); end if;

  -- ── A) Agregar los escaneados por código (sumar cantidades del array de escaneos). ─────────────────────────
  --    Cantidad por escaneo: numeric (1 por tap, o N si el front agrupa). Negativos/0 se ignoran defensivamente.
  create temp table _esc_agg (cod_barra text primary key, cant numeric) on commit drop;
  for v_e in select * from jsonb_array_elements(v_esc) loop
    v_cb   := btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barra', ''));
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;
    insert into _esc_agg(cod_barra, cant) values (v_cb, v_cant)
      on conflict (cod_barra) do update set cant = _esc_agg.cant + excluded.cant;
  end loop;

  -- ── B) Detalle por código: unir lo ENVIADO (guía) con lo ESCANEADO (real). FULL JOIN para captar también
  --       códigos escaneados que NO estaban en la guía (sobrante inesperado → dif negativa). ─────────────────
  with envi as (
      select d.cod_barras as cod_barra,
             min(d.linea)  as linea,
             sum(d.cantidad) as enviado
        from me.guias_detalle d where d.id_guia = v_id group by d.cod_barras
  ),
  uni as (
      select coalesce(en.cod_barra, es.cod_barra) as cod_barra,
             en.linea                              as linea,
             coalesce(en.enviado, 0)               as enviado,
             coalesce(es.cant, 0)                  as escaneado
        from envi en
        full join _esc_agg es on es.cod_barra = en.cod_barra
  )
  select
      coalesce(sum(enviado),0),
      coalesce(sum(escaneado),0),
      coalesce(sum(enviado - escaneado),0),
      coalesce(sum(case when enviado = escaneado then 1 else 0 end),0),
      coalesce(sum(case when enviado <> escaneado then 1 else 0 end),0),
      coalesce(jsonb_agg(jsonb_build_object(
          'codBarra',    u.cod_barra,
          'descripcion', coalesce(pr.descripcion, u.cod_barra),
          'enviado',     u.enviado,
          'escaneado',   u.escaneado,
          'dif',         (u.enviado - u.escaneado),
          'estado',      case when u.enviado = u.escaneado then 'OK'
                              when u.escaneado < u.enviado then 'FALTA'
                              else 'SOBRA' end
        ) order by (u.enviado - u.escaneado) desc, u.cod_barra), '[]'::jsonb)
  into v_enviado_tot, v_escaneado_tot, v_dif_tot, v_ok_n, v_dif_n, v_detalle
  from uni u
  left join lateral (select descripcion from mos.productos pr where pr.codigo_barra = u.cod_barra limit 1) pr on true;

  v_estado := case when v_dif_n = 0 then 'COMPLETO' else 'INCOMPLETO' end;

  -- ── C) KARDEX: registrar cada ESCANEADO como TRASLADO_IN (idempotente por ref de línea/código). ────────────
  --    ref_id por línea de guía cuando el código estaba en la guía; por código suelto si fue un sobrante.
  for v_cb, v_cant in select cod_barra, cant from _esc_agg loop
    select min(d.linea) into v_linea from me.guias_detalle d where d.id_guia = v_id and d.cod_barras = v_cb;
    perform me.zona_kardex_registrar(jsonb_build_object(
      'zona',     v_zona,
      'codBarra', v_cb,
      'tipo',     'TRASLADO_IN',
      'delta',    v_cant,
      'refTipo',  'TRASLADO',
      'refId',    'TRASLADO:'||v_id||':'||coalesce(v_linea::text, 'X-'||v_cb),
      'usuario',  v_user,
      'origen',   v_origen
    ));
  end loop;

  -- ┌─ [GATE-STOCK · INERTE] ───────────────────────────────────────────────────────────────────────────────┐
  -- │ AQUÍ se aplicaría lo ESCANEADO al SALDO operativo de la zona (me.stock_zonas). HOY ESTÁ APAGADO        │
  -- │ (v_aplicar_stock=false). Para activar tras validación: poner v_aplicar_stock:=true. El delta a aplicar  │
  -- │ por código es EXACTAMENTE lo escaneado (NO lo enviado). UPDATE atómico (suma delta), nunca               │
  -- │ read-modify-write (lección WH: lost-update). Insert si la fila (cod_barras,zona) no existe.              │
  if v_aplicar_stock then
    for v_cb, v_cant in select cod_barra, cant from _esc_agg loop
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_cb, v_zona, v_cant, v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) + excluded.cantidad,
            usuario = excluded.usuario,
            fecha_ultimo_registro = now();
    end loop;
  end if;
  -- └─ /GATE-STOCK ─────────────────────────────────────────────────────────────────────────────────────────┘

  -- ── D) Persistir la verificación (idempotente por id_guia). ────────────────────────────────────────────────
  insert into me.zona_traslado_verificacion
    (id_guia, zona_id, tipo_guia, estado, total_enviado, total_escaneado, total_dif,
     lineas_ok, lineas_dif, detalle, stock_aplicado, usuario, verificado_ts, fecha_guia)
  values
    (v_id, v_zona, v_cab.tipo, v_estado, v_enviado_tot, v_escaneado_tot, v_dif_tot,
     v_ok_n, v_dif_n, v_detalle, v_aplicar_stock, v_user, now(), v_cab.fecha)
  on conflict (id_guia) do nothing
  returning * into v_row;

  if v_row.id_guia is null then
    -- carrera: alguien la verificó entre el check y el insert → devolver la existente.
    select * into v_row from me.zona_traslado_verificacion where id_guia = v_id;
    return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_row));
  end if;

  return jsonb_build_object('ok', true, 'dedup', false,
      'stockAplicado', v_aplicar_stock, 'data', to_jsonb(v_row));
end;
$fn$;
revoke all on function me.zona_traslado_cerrar(jsonb) from public;
grant execute on function me.zona_traslado_cerrar(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 5) me.zona_traslados_resumen(p {zona, dias?}) — conteo ✓completo/⚠incompleto/⏳pendiente + detalle por guía.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_traslados_resumen(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona text := upper(btrim(coalesce(p->>'zona','')));
  v_dias int  := greatest(1, coalesce((p->>'dias')::int, 30));
  v_completo int := 0; v_incompleto int := 0; v_pendiente int := 0;
  v_verif jsonb; v_pend jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  -- conteos de verificadas (en la ventana) por estado
  select
    coalesce(sum(case when estado='COMPLETO'   then 1 else 0 end),0),
    coalesce(sum(case when estado='INCOMPLETO' then 1 else 0 end),0)
  into v_completo, v_incompleto
  from me.zona_traslado_verificacion
  where zona_id = v_zona and verificado_ts >= now() - make_interval(days => v_dias);

  -- pendientes = guías ENTRADA de la zona en ventana sin verificación
  select count(*) into v_pendiente
  from me.guias_cabecera g
  where g.zona_id = v_zona and g.tipo like 'ENTRADA%'
    and g.fecha >= now() - make_interval(days => v_dias)
    and not exists (select 1 from me.zona_traslado_verificacion v where v.id_guia = g.id_guia);

  -- detalle de las verificadas (enviado vs escaneado por guía)
  select coalesce(jsonb_agg(jsonb_build_object(
      'idGuia',         v.id_guia,
      'tipoGuia',       v.tipo_guia,
      'estado',         v.estado,
      'totalEnviado',   v.total_enviado,
      'totalEscaneado', v.total_escaneado,
      'totalDif',       v.total_dif,
      'lineasOk',       v.lineas_ok,
      'lineasDif',      v.lineas_dif,
      'stockAplicado',  v.stock_aplicado,
      'usuario',        coalesce(v.usuario,'—'),
      'verificadoTs',   v.verificado_ts,
      'fechaGuia',      v.fecha_guia,
      'edadLbl',        me._edad_lbl(now() - v.verificado_ts),
      'detalle',        v.detalle
    ) order by v.verificado_ts desc), '[]'::jsonb) into v_verif
  from me.zona_traslado_verificacion v
  where v.zona_id = v_zona and v.verificado_ts >= now() - make_interval(days => v_dias);

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'zona', v_zona, 'dias', v_dias,
      'completo', v_completo, 'incompleto', v_incompleto, 'pendiente', v_pendiente,
      'verificaciones', v_verif)) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_traslados_resumen(jsonb) from public;
grant execute on function me.zona_traslados_resumen(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 6) WRAPPERS mos.* (profile 'mos' del frontend) — pass-through con gate, patrón 132/140.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.zona_traslados_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_traslados_pendientes(p);
end; $fn$;
revoke all on function mos.zona_traslados_pendientes(jsonb) from public;
grant execute on function mos.zona_traslados_pendientes(jsonb) to service_role, authenticated;

create or replace function mos.zona_traslado_guia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_traslado_guia(p);
end; $fn$;
revoke all on function mos.zona_traslado_guia(jsonb) from public;
grant execute on function mos.zona_traslado_guia(jsonb) to service_role, authenticated;

create or replace function mos.zona_traslado_cerrar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_traslado_cerrar(p);
end; $fn$;
revoke all on function mos.zona_traslado_cerrar(jsonb) from public;
grant execute on function mos.zona_traslado_cerrar(jsonb) to service_role, authenticated;

create or replace function mos.zona_traslados_resumen(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_traslados_resumen(p);
end; $fn$;
revoke all on function mos.zona_traslados_resumen(jsonb) from public;
grant execute on function mos.zona_traslados_resumen(jsonb) to service_role, authenticated;
