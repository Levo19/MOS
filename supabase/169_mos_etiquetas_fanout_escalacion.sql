-- 169_mos_etiquetas_fanout_escalacion.sql — [MIGRACIÓN MOS · CIERRE ETIQUETAS_ZONA · DELETE-SAFE de la HOJA]
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- CONTEXTO: etiquetas_zona seguía con MOS_ETIQ_DIRECTO='0' porque faltaban DOS piezas que en GAS NO eran
--   RPCs equivalentes, sino lógica que escaneaba la HOJA:
--     (1) GENERACIÓN — fan-out por zona disparado por el hook publicarPrecio (_etiqGenerarParaZonas):
--         leía ZONAS de la hoja y hacía 1 UPSERT por zona ACTIVA NO-ALMACÉN, sobre la fila abierta
--         (estado != PEGADA/OBSOLETA) de (idProducto,idZona). Sólo CANÓNICOS (factor=1).
--     (2) ESCALACIÓN / AUTO-OBSOLETA — cron horario (_etiqCronEscalacion) que escaneaba la HOJA entera:
--         marca OBSOLETA toda etiqueta abierta con ts_cambio > 3 días + agrupa para push (cajero/admin).
--   Los PRIMITIVOS atómicos de 1 fila (crear_etiqueta_zona / actualizar_etiqueta_zona) ya existían (82).
--   Este lote PORTA esas 2 piezas a Supabase para que el flujo de precio→etiquetas NO toque la HOJA.
--
-- ── POR QUÉ ESTO HABILITA EL DELETE-SAFE ─────────────────────────────────────────────────────────────────
--   etiquetas_zona NO es dinero. El front NO consume etiquetas directamente (la lectura GAS getEtiquetasPendientes
--   ya lee la sombra con _fresh+fallback, P6.5). El único que ESCRIBÍA la hoja era el hook de precio (GAS) y el
--   cron (GAS). Con estas 2 RPCs, en directo-puro (MOS_ETIQ_DIRECTO='1' + sync-off de la tabla) la generación y
--   la escalación operan 100% sobre mos.etiquetas_zona / mos.zonas / mos.productos → borrar la HOJA
--   ETIQUETAS_ZONA NO rompe nada del flujo de etiquetas.
--
-- ── PARIDAD HONESTA con GAS ──────────────────────────────────────────────────────────────────────────────
--   · GENERACIÓN: idéntica al UPSERT por (idProducto,idZona) de _etiqGenerarParaZonas:
--       - Filtro CANÓNICO: factor_conversion=1 (o NULL ⇒ asumir canónico). No-canónico ⇒ creadas=0.
--       - Zonas: mos.zonas.estado=true, EXCLUYE ALMACÉN (id/nombre contiene 'ALMACEN'/'ALMACÉN', o id='ALM').
--       - Si hay fila ABIERTA (estado NOT IN PEGADA/OBSOLETA) para (idProducto,idZona) ⇒ UPDATE precio_nuevo,
--         ts_cambio, cambiado_por, estado='PENDIENTE', visto_csv='' (reset). Sino ⇒ INSERT nueva PENDIENTE.
--       - El PUSH a cajeros/vendedores queda en GAS (orquestación de notificaciones) — esta RPC NO empuja.
--   · ESCALACIÓN: la AUTO-OBSOLETA (>3 días) se hace acá (UPDATE atómico sobre la sombra). Los PUSHES de
--     escalación (>2h sin visto / >4h impresa sin pegar) quedan en GAS por diseño (igual que el resto de
--     orquestación de notificaciones). La RPC DEVUELVE los grupos para observabilidad/diagnóstico, sin empujar.
--
-- ── INERTE HASTA EL CUTOVER ──────────────────────────────────────────────────────────────────────────────
--   Ambas RPCs respetan el flag MOS_ETIQ_DIRECTO. Hoy = '0' ⇒ devuelven *_OFF sin tocar datos. El job
--   pg_cron de escalación se crea pero la función no marca nada con el flag en '0' (doble-inerte). La
--   ACTIVACIÓN real (flag '1' + sync-off + job activo) la hace el runner cutover_etiq_fanout_on.js tras 40x.

create schema if not exists mos;
create extension if not exists pg_cron;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 0) HELPER — mos._etiq_es_zona_almacen(id, nombre)  (espeja _etiqEsZonaAlmacen de GAS)
--    Excluye zonas tipo almacén del fan-out (no se ponen etiquetas de precio de cara al cliente en almacén).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos._etiq_es_zona_almacen(p_id text, p_nombre text)
returns boolean
language sql
immutable
set search_path = ''
as $fn$
  select
    -- normaliza acentos (ALMACÉN→ALMACEN) y mayúsculas, igual que el normalize('NFD') de GAS
    upper(translate(coalesce(p_id,''),    'áéíóúÁÉÍÓÚ','aeiouAEIOU')) like '%ALMACEN%'
 or upper(translate(coalesce(p_nombre,''),'áéíóúÁÉÍÓÚ','aeiouAEIOU')) like '%ALMACEN%'
 or upper(btrim(coalesce(p_id,''))) = 'ALM';
$fn$;
revoke all on function mos._etiq_es_zona_almacen(text,text) from public;
grant execute on function mos._etiq_es_zona_almacen(text,text) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) GENERACIÓN (fan-out por zona) — mos.generar_etiquetas_zona(p jsonb)
--    Espeja _etiqGenerarParaZonas: 1 UPSERT por zona ACTIVA NO-ALMACÉN, por (idProducto,idZona) sobre la
--    fila abierta. Idempotente: re-llamar con el MISMO precio NO duplica (UPDATE de la misma fila abierta).
--    p: { idProducto, codigoBarra, skuBase, descripcion, precioAnterior, precioNuevo, usuario }
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.generar_etiquetas_zona(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idprod text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_cb     text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_sku    text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_desc   text := nullif(btrim(coalesce(p->>'descripcion','')), '');
  v_usr    text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_pant   numeric := coalesce(mos._numn(p->>'precioAnterior'),0);
  v_pnue   numeric := coalesce(mos._numn(p->>'precioNuevo'),0);
  v_ts     timestamptz;
  v_factor numeric;
  v_creadas int := 0;
  v_actualizadas int := 0;
  v_nzonas int := 0;
  v_zona record;
  v_idetiq text;
  v_existe text;
  v_n int;
begin
  if coalesce((select valor from mos.config where clave='MOS_ETIQ_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_ETIQ_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_idprod is null and v_cb is null then
    return jsonb_build_object('ok',false,'error','Requiere idProducto o codigoBarra');
  end if;

  -- ts_cambio: del front o now() (GAS usa _etiqNowIso()).
  begin v_ts := nullif(btrim(coalesce(p->>'tsCambio','')),'')::timestamptz; exception when others then v_ts := null; end;
  v_ts := coalesce(v_ts, now());

  -- ── FILTRO CANÓNICO (paridad GAS): sólo factor_conversion=1 (o NULL ⇒ canónico) genera etiquetas.
  --    Presentaciones/derivados (factor != 1) NO generan (el cliente ve el precio del base en el estante).
  select factor_conversion into v_factor
    from mos.productos
   where (v_idprod is not null and id_producto = v_idprod)
      or (v_idprod is null and v_cb is not null and codigo_barra = v_cb)
   limit 1;
  if found and v_factor is not null and v_factor <> 1 then
    return jsonb_build_object('ok',true,'data',
      jsonb_build_object('creadas',0,'actualizadas',0,'zonas',0,
        'msg','No-canónico (factor='||v_factor||'): no genera etiquetas'));
  end if;

  -- ── FAN-OUT por zona ACTIVA NO-ALMACÉN ──
  for v_zona in
    select id_zona, coalesce(nombre, id_zona) as nombre
      from mos.zonas
     where estado is true
       and not mos._etiq_es_zona_almacen(id_zona, nombre)
  loop
    v_nzonas := v_nzonas + 1;

    -- ¿hay fila ABIERTA (estado != PEGADA/OBSOLETA) para (idProducto,idZona)?  for update = sin lost-update.
    select id_etiq into v_existe
      from mos.etiquetas_zona
     where id_producto is not distinct from v_idprod
       and id_zona = v_zona.id_zona
       and upper(coalesce(estado,'')) not in ('PEGADA','OBSOLETA')
     order by ts_cambio desc nulls last
     limit 1
     for update;

    if found then
      -- UPDATE: precio cambió antes de pegar → resetear a PENDIENTE + limpiar vistos (paridad GAS).
      update mos.etiquetas_zona set
        precio_nuevo = v_pnue,
        ts_cambio    = v_ts,
        cambiado_por = v_usr,
        estado       = 'PENDIENTE',
        visto_csv    = ''
      where id_etiq = v_existe;
      v_actualizadas := v_actualizadas + 1;
    else
      -- INSERT nueva fila PENDIENTE. id = 'ETQ-'||epoch_ms||'-'||zona (paridad GAS 'ETQ-'+ts+'-'+zona),
      -- pero usamos el id_zona COMPLETO + un sufijo aleatorio corto. Motivo: dentro de un mismo fan-out,
      -- clock_timestamp() puede repetir el ms entre zonas y left(id_zona,6) colapsa 'ZONA-01'/'ZONA-02' a
      -- 'ZONA-0' → colisión de PK → 'on conflict do nothing' PERDÍA la etiqueta de una zona. El id_zona
      -- entero + sufijo garantiza unicidad por (ms,zona) y evita ese drop. (GAS no lo sufría: appendRow no
      -- dedupea, pero acá la PK es real.)
      v_idetiq := 'ETQ-'||(extract(epoch from clock_timestamp())*1000)::bigint::text||'-'||v_zona.id_zona
                  ||'-'||substr(md5(random()::text||clock_timestamp()::text),1,4);
      insert into mos.etiquetas_zona (
        id_etiq, id_zona, zona_nombre, id_producto, descripcion,
        codigo_barra, sku_base, precio_anterior, precio_nuevo,
        ts_cambio, cambiado_por, estado, visto_csv
      ) values (
        v_idetiq, v_zona.id_zona, v_zona.nombre, v_idprod, coalesce(v_desc,''),
        coalesce(v_cb,''), coalesce(v_sku,''), v_pant, v_pnue,
        v_ts, coalesce(v_usr,''), 'PENDIENTE', ''
      )
      on conflict (id_etiq) do nothing;
      get diagnostics v_n = row_count;
      if v_n > 0 then v_creadas := v_creadas + 1; end if;
    end if;
  end loop;

  if v_nzonas = 0 then
    return jsonb_build_object('ok',true,'data',
      jsonb_build_object('creadas',0,'actualizadas',0,'zonas',0,'msg','Sin zonas activas (no-almacén)'));
  end if;

  return jsonb_build_object('ok',true,'data',
    jsonb_build_object('creadas',v_creadas,'actualizadas',v_actualizadas,'zonas',v_nzonas));
end;
$fn$;
revoke all on function mos.generar_etiquetas_zona(jsonb) from public;
grant execute on function mos.generar_etiquetas_zona(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) ESCALACIÓN / AUTO-OBSOLETA — mos.escalar_etiquetas_zona()
--    Espeja _etiqCronEscalacion operando sobre la SOMBRA (no la HOJA):
--      (1) AUTO-OBSOLETA: marca OBSOLETA toda etiqueta ABIERTA con ts_cambio > 3 días (UPDATE atómico).
--      (2) Agrupa para escalación (>2h PENDIENTE sin visto / >4h IMPRESA sin pegar) → DEVUELVE el conteo
--          para que GAS (o un futuro Edge) decida los PUSHES. Esta RPC NO empuja (orquestación queda en GAS).
--    Idempotente: re-correr no re-obsoleta lo ya cerrado. Gateada por MOS_ETIQ_DIRECTO ⇒ inerte si '0'.
--    SECURITY DEFINER + search_path='' ; el cron corre como owner ⇒ mos._claim_ok() pasa (jwt_app NULL).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.escalar_etiquetas_zona()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_obsoletas int := 0;
  v_novistas  int := 0;
  v_sinpegar  int := 0;
  v_ahora     timestamptz := now();
begin
  if coalesce((select valor from mos.config where clave='MOS_ETIQ_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_ETIQ_DIRECTO_OFF','obsoletas',0);
  end if;

  -- (1) AUTO-OBSOLETA: abiertas con ts_cambio > 3 días. Comentario append (paridad GAS).
  with upd as (
    update mos.etiquetas_zona t set
      estado = 'OBSOLETA',
      comentario = coalesce(nullif(t.comentario,''),'')
                   || case when coalesce(t.comentario,'')<>'' then ' · ' else '' end
                   || 'Auto-obsoleta >3d ('||to_char(v_ahora,'YYYY-MM-DD"T"HH24:MI:SS"Z"')||')'
    where upper(coalesce(t.estado,'')) not in ('PEGADA','OBSOLETA')
      and t.ts_cambio is not null
      and t.ts_cambio < v_ahora - interval '3 days'
    returning 1
  )
  select count(*) into v_obsoletas from upd;

  -- (2) ESCALACIÓN (solo conteo para observabilidad; el push lo hace GAS):
  --     PENDIENTE > 2h sin visto_csv → revisar (cajero/vendedor)
  select count(*) into v_novistas
    from mos.etiquetas_zona
   where upper(coalesce(estado,'')) = 'PENDIENTE'
     and coalesce(visto_csv,'') = ''
     and ts_cambio is not null
     and ts_cambio < v_ahora - interval '120 minutes';

  --     IMPRESA > 4h sin pegar → escalar a admin
  select count(*) into v_sinpegar
    from mos.etiquetas_zona
   where upper(coalesce(estado,'')) = 'IMPRESA'
     and ts_impresa is not null
     and ts_impresa < v_ahora - interval '240 minutes';

  return jsonb_build_object('ok',true,
    'obsoletas',v_obsoletas,'noVistas',v_novistas,'sinPegar',v_sinpegar);
end;
$fn$;
revoke all on function mos.escalar_etiquetas_zona() from public, anon;
grant execute on function mos.escalar_etiquetas_zona() to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) WRAPPER pg_cron — mos.cron_escalar_etiquetas()  (loguea en mos.cron_log; nunca propaga excepción)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.cron_escalar_etiquetas()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_res jsonb;
begin
  v_res := mos.escalar_etiquetas_zona();
  insert into mos.cron_log(job, ok, resultado)
    values ('escalar_etiquetas', coalesce((v_res->>'ok')::boolean,false), v_res);
  return v_res;
exception when others then
  insert into mos.cron_log(job, ok, resultado)
    values ('escalar_etiquetas', false, jsonb_build_object('excepcion', SQLERRM));
  return jsonb_build_object('ok',false,'error','excepcion','detalle',SQLERRM);
end;
$fn$;
revoke all on function mos.cron_escalar_etiquetas() from public, anon, authenticated;
grant execute on function mos.cron_escalar_etiquetas() to service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) AGENDA pg_cron — job horario. Se crea ACTIVO pero la función es INERTE mientras MOS_ETIQ_DIRECTO='0'
--    (doble candado: el flag corta el efecto aunque el job corra). 1h, espeja everyHours(1) de GAS.
--    Idempotente: desagenda si ya existía (evita duplicado al re-aplicar).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
select cron.unschedule('mos-escalar-etiquetas') where exists (select 1 from cron.job where jobname='mos-escalar-etiquetas');
select cron.schedule('mos-escalar-etiquetas', '7 * * * *', $$ select mos.cron_escalar_etiquetas(); $$);
