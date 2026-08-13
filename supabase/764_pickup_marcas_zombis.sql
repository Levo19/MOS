-- 764 · BLINDAJE MARCAS ZOMBIS (13-ago-2026) — guía duplicó productos de ayer.
--
-- QUÉ PASÓ (evidencia): la guía de hoy 08:21 repitió 4 líneas de la de ayer 15:01
-- con el MISMO timestamp de escaneo (y ayer mismo pasó entre las guías 12:58→15:01).
-- El cierre pone toda separación en 0, pero `guardar_progreso_pickup` acepta el
-- `despachado` del dispositivo TAL CUAL: un autosave con la copia VIEJA de la lista
-- (en vuelo mientras se emitía la guía) re-escribía las marcas ya despachadas.
-- La consolidación nocturna las arrastra ([752] separación se arrastra) y la
-- siguiente emisión las vuelve a facturar: stock doble-descontado, deuda doble-consumida.
--
-- LA REGLA NUEVA: cada vez que las marcas se resetean (cierre, soltar, candado 1h,
-- week-death) se sella `marcas_reset_ts`. Una marca cuyo escaneo es ANTERIOR a ese
-- sello ya fue procesada o descartada — si vuelve a llegar es estado viejo del
-- dispositivo y SE IGNORA: ni el autosave la puede resucitar ni la emisión la factura.

-- ═══ (0) columna sello + backfill + helper de cast seguro ═════════════════════
alter table wh.pickups add column if not exists marcas_reset_ts timestamptz;
update wh.pickups set marcas_reset_ts = fecha_atendido
 where marcas_reset_ts is null and fecha_atendido is not null;

create or replace function wh._ts_safe(t text)
returns timestamptz language plpgsql immutable
set search_path to ''
as $function$
begin
  return t::timestamptz;
exception when others then
  return null;
end;
$function$;

-- ═══ (1) guardar_progreso_pickup: el autosave no resucita marcas ni deuda ═════
CREATE OR REPLACE FUNCTION wh.guardar_progreso_pickup(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idp   text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup','')),'');
  v_lock  text := coalesce(p->>'lock_usuario', p->>'lockUsuario', '');
  v_items jsonb := p->'items';
  v_atp   text;
  v_est   text;
  v_reset timestamptz;              -- [764] último reset de marcas
  v_now   timestamptz := now();
  v_merge jsonb;
  v_env   jsonb := '{}'::jsonb;   -- [741] payload del dispositivo indexado por producto
  v_rev   bigint;                 -- [752] rev resultante (tg_pickup_rev es BEFORE → RETURNING lo trae)
begin
  if coalesce((select valor from mos.config where clave='WH_PICKUP_ESTADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_PICKUP_ESTADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPickup'); end if;

  select atendido_por, estado, marcas_reset_ts into v_atp, v_est, v_reset
    from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok',false,'error','Pickup no encontrado'); end if;

  -- [741] indexar lo que manda el dispositivo por clave de producto
  if jsonb_typeof(v_items) = 'array' then
    select coalesce(jsonb_object_agg(wh._pickup_item_key(e.value), e.value), '{}'::jsonb)
      into v_env from jsonb_array_elements(v_items) e;
  end if;

  -- Conflicto de lock; si no había lock, tomarlo (autosave implica que estoy trabajando)
  if v_lock <> '' then
    if coalesce(btrim(v_atp),'') <> '' and not wh._pickup_same_user(v_atp, v_lock) then
      return jsonb_build_object('ok',false,'error','Pickup atendido por '||v_atp,'atendidoPor',v_atp,'conflicto',true);
    end if;
  end if;

  -- [741] FUSIÓN por producto en vez de reemplazo. Del payload solo se toma el
  -- PROGRESO (despachado y su hora); los productos que el dispositivo no tenía se
  -- conservan intactos.
  -- [764] GUARDA ZOMBI: una SUBIDA de despachado cuyo tsDespacho es anterior al
  -- último reset de marcas es estado viejo del dispositivo (ya se emitió o se
  -- descartó) → se ignora y manda la base. Bajar o corregir a cero sigue libre.
  if jsonb_typeof(v_items) = 'array' then
    select coalesce(jsonb_agg(
             case when v_env ? wh._pickup_item_key(base.value)
                  then base.value
                       || case
                          when v_reset is not null
                           and coalesce(((v_env -> wh._pickup_item_key(base.value))->>'despachado')::numeric, 0)
                               > coalesce((base.value->>'despachado')::numeric, 0)
                           and ( wh._ts_safe((v_env -> wh._pickup_item_key(base.value))->>'tsDespacho') is null
                                 or wh._ts_safe((v_env -> wh._pickup_item_key(base.value))->>'tsDespacho') < v_reset )
                          then '{}'::jsonb   -- [764] marca vieja: no vuelve
                          else jsonb_build_object('despachado',
                                 coalesce(((v_env -> wh._pickup_item_key(base.value))->>'despachado')::numeric,
                                          coalesce((base.value->>'despachado')::numeric,0)))
                               || case when (v_env -> wh._pickup_item_key(base.value)) ? 'tsDespacho'
                                       then jsonb_build_object('tsDespacho', (v_env -> wh._pickup_item_key(base.value))->'tsDespacho')
                                       else '{}'::jsonb end
                          end
                  else base.value end), '[]'::jsonb)
      into v_merge
      from wh.pickups pk, jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) base
     where pk.id_pickup = v_idp;

    -- Productos que el dispositivo trae y en la base NO existen. [764] Solo entran
    -- los legítimos: constancias sinSku o EXTRAS con escaneo FRESCO (posterior al
    -- reset). Un item con marca vieja es un residuo de una lista ya emitida/reseteada:
    -- re-agregarlo resucitaba deuda saldada (así se duplicó el spaghetti x60).
    select v_merge || coalesce(jsonb_agg(nue.value), '[]'::jsonb)
      into v_merge
      from jsonb_array_elements(v_items) nue
     where not exists (
             select 1 from jsonb_array_elements(v_merge) b
              where wh._pickup_item_key(b.value) = wh._pickup_item_key(nue.value))
       and ( coalesce((nue.value->>'sinSku')::boolean, false)
             or v_reset is null
             or ( wh._ts_safe(nue.value->>'tsDespacho') is not null
                  and wh._ts_safe(nue.value->>'tsDespacho') >= v_reset ) );
  end if;

  update wh.pickups
     set items            = coalesce(v_merge, items),
         atendido_por     = case when v_lock <> '' and coalesce(btrim(atendido_por),'')='' then v_lock else atendido_por end,
         estado           = case when upper(coalesce(estado,'')) = 'PENDIENTE' then 'EN_PROCESO' else estado end,
         ultima_actividad = v_now
   where id_pickup = v_idp
   returning rev into v_rev;
  -- [752] el front sella este rev: su propio autosave deja de parecer "cambio ajeno"
  return jsonb_build_object('ok',true,'rev',v_rev);
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;
$function$;

-- ═══ (2) cerrar_pickup_con_despacho: la emisión filtra marcas viejas y sella el reset ═══
CREATE OR REPLACE FUNCTION wh.cerrar_pickup_con_despacho(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '20s'
AS $function$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup', '')), '');
  v_usuario text := coalesce(p->>'usuario', '');
  v_items   jsonb := coalesce(p->'items', '[]'::jsonb);
  v_det     jsonb := coalesce(p->'despacho_detalle', p->'despachoDetalle', '[]'::jsonb);
  v_pickup  record;
  v_est_up  text;
  v_fp      text := '';
  v_env     jsonb := '{}'::jsonb;   -- [749] despacho del celular indexado por producto
  v_it      jsonb;
  v_cod     text;
  v_qty     numeric;
  v_total_desp numeric := 0;
  v_no_desp int := 0;
  v_nuevo_estado text;
  v_idguia  text := null;
  v_guia_prev text;
  v_desp_res jsonb;
  v_now     timestamptz := now();
begin
  -- Gate propio (kill-switch). OFF → frontend cae a GAS.
  if coalesce((select valor from mos.config where clave = 'WH_CERRAR_PICKUP_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'WH_CERRAR_PICKUP_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok', false, 'error', 'Requiere idPickup'); end if;

  -- Leer pickup con lock (serializa contra retry/doble-tap concurrente del mismo id)
  select * into v_pickup from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Pickup no encontrado'); end if;

  -- ── IDEMPOTENCIA NIVEL 1: solo PENDIENTE/EN_PROCESO son despachables ──
  v_est_up := upper(coalesce(v_pickup.estado, ''));
  if v_est_up not in ('PENDIENTE', 'EN_PROCESO', '') then
    return jsonb_build_object('ok', false,
      'error', 'El pickup ya no es despachable (estado=' || v_est_up || ')', 'yaCerrado', true);
  end if;

  -- ── [764] BLINDAJE ZOMBI: marca con escaneo ANTERIOR al último reset de marcas
  -- (cierre/soltar/vencimiento) ya fue emitida o descartada — un dispositivo con
  -- estado viejo no la puede volver a facturar. Se filtra ANTES de la firma, del
  -- detalle y del colapso de deuda.
  if v_pickup.marcas_reset_ts is not null then
    select coalesce(jsonb_agg(
             case when wh._num(coalesce(e.value->>'despachado','0')) > 0
                   and wh._ts_safe(e.value->>'tsDespacho') is not null
                   and wh._ts_safe(e.value->>'tsDespacho') < v_pickup.marcas_reset_ts
                  then e.value || jsonb_build_object('despachado', 0)
                  else e.value end), '[]'::jsonb)
      into v_items from jsonb_array_elements(v_items) e;
    if jsonb_typeof(v_det) = 'array' and jsonb_array_length(v_det) > 0 then
      select coalesce(jsonb_agg(e.value), '[]'::jsonb) into v_det
        from jsonb_array_elements(v_det) e
       where not ( wh._ts_safe(e.value->>'ts') is not null
                   and wh._ts_safe(e.value->>'ts') < v_pickup.marcas_reset_ts );
    end if;
  end if;

  -- ── IDEMPOTENCIA NIVEL 2 (FIX 414): guía para este pickup en los ÚLTIMOS 90 MIN ──
  v_fp := wh._fp_despacho(case when jsonb_typeof(v_det) = 'array' and jsonb_array_length(v_det) > 0
                               then v_det else v_items end);
  select id_guia into v_guia_prev
  from wh.guias
  where comentario like '%[pickup:' || v_idp || ']%'
    and (v_fp = '' or comentario like '%[fp:' || v_fp || ']%')
    and fecha > v_now - interval '90 minutes'
  order by fecha desc
  limit 1;
  if v_guia_prev is not null then
    update wh.pickups
       set estado           = case
                                when upper(coalesce(estado,'')) not in ('PENDIENTE','EN_PROCESO','') then estado
                                when coalesce(fuente,'') = 'ACUMULADO_SEMANAL'
                                     and exists (select 1 from jsonb_array_elements(coalesce(items,'[]'::jsonb)) e
                                                  where wh._num(coalesce(e->>'solicitado','0')) > wh._num(coalesce(e->>'despachado','0')))
                                  then 'PENDIENTE'
                                else 'COMPLETADO' end,
           fecha_atendido   = coalesce(fecha_atendido, v_now),
           atendido_por     = '',
           ultima_actividad = v_now
     where id_pickup = v_idp;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'idGuia', v_guia_prev, 'estado', 'COMPLETADO', 'yaCerrado', true, 'idempotente', true));
  end if;

  -- ── Derivar despachoDetalle desde items si no vino (codigosOriginales[0]) ──
  if jsonb_typeof(v_det) <> 'array' or jsonb_array_length(v_det) = 0 then
    v_det := '[]'::jsonb;
    for v_it in select * from jsonb_array_elements(v_items) loop
      v_qty := wh._num(coalesce(v_it->>'despachado', '0'));
      if v_qty <= 0 then continue; end if;
      v_cod := nullif(btrim(coalesce(v_it->'codigosOriginales'->>0, '')), '');
      if v_cod is null then continue; end if;
      v_det := v_det || jsonb_build_array(jsonb_build_object('codigo_barra', v_cod, 'cantidad', v_qty, 'ts', v_it->>'tsDespacho'));   -- [608] hora del escaneo
    end loop;
  end if;

  -- Total despachado
  for v_it in select * from jsonb_array_elements(v_det) loop
    v_total_desp := v_total_desp + wh._num(coalesce(v_it->>'cantidad', '0'));
  end loop;

  -- No despachados: solicitado > despachado
  select count(*) into v_no_desp
  from jsonb_array_elements(v_items) e
  where wh._num(coalesce(e->>'solicitado', '0')) > wh._num(coalesce(e->>'despachado', '0'));

  -- [603] CUENTA CORRIENTE: el acumulador semanal con deuda restante queda PENDIENTE
  v_nuevo_estado := case
    when v_no_desp = 0 then 'COMPLETADO'
    when coalesce(v_pickup.fuente,'') = 'ACUMULADO_SEMANAL' then 'PENDIENTE'
    when v_total_desp > 0 then 'PARCIAL'
    else 'CANCELADO'
  end;

  -- ── Crear GUIA_SALIDA si hubo al menos un item despachado ──
  if v_total_desp > 0 then
    -- [750] La firma del contenido va en el id: dos despachos DISTINTOS dentro del
    -- mismo segundo compartian id de guia y se mezclaban en un solo documento.
    v_idguia := 'GPCK_' || v_idp || '_' || to_char(v_now at time zone 'America/Lima', 'YYYYMMDD_HH24MISS')
                || case when coalesce(v_fp,'') <> '' then '_' || left(v_fp, 4) else '' end;
    v_desp_res := wh.crear_despacho_rapido(jsonb_build_object(
      'id_guia',    v_idguia,
      'tipo',       'SALIDA_ZONA',
      'id_zona',    coalesce(v_pickup.id_zona, ''),
      'usuario',    v_usuario,
      'comentario', '[pickup:' || v_idp || '][fp:' || coalesce(v_fp,'') || ']',
      'items',      v_det
    ));
    if coalesce((v_desp_res->>'ok'), 'false') <> 'true' then
      return jsonb_build_object('ok', false,
        'error', 'Falló GUIA_SALIDA: ' || coalesce(v_desp_res->>'error', '?'));
    end if;
    v_idguia := coalesce(v_desp_res->>'idGuia', v_idguia);
  end if;

  -- ── [743] Colapsar a SALDO antes de guardar ──
  if coalesce(v_pickup.fuente,'') = 'ACUMULADO_SEMANAL' then
    -- [749] El payload del celular solo dice CUANTO se despacho de cada producto.
    select coalesce(jsonb_object_agg(wh._pickup_item_key(e.value), e.value), '{}'::jsonb)
      into v_env from jsonb_array_elements(coalesce(v_items,'[]'::jsonb)) e;

    select coalesce(jsonb_agg(nuevo_it), '[]'::jsonb) into v_items
    from (
      select wh._mov_add(
               jsonb_set(
                 jsonb_set(e.value, '{solicitado}',
                   to_jsonb(greatest(0, wh._num(coalesce(e.value->>'solicitado','0'))
                                      - wh._num(coalesce(e.value->>'despachado','0'))))),
                 '{despachado}', to_jsonb(0)),
               'despacho', wh._num(coalesce(e.value->>'despachado','0')),
               -- [745] La hora del movimiento es la del ESCANEO de ese producto
               'despacho a zona', coalesce(v_idguia,''),
               coalesce((e.value->>'tsDespacho')::timestamptz, v_now)) as nuevo_it
      -- [749] Se parte de la lista de la BASE, no del envio
      from wh.pickups pk_base
      cross join lateral jsonb_array_elements(coalesce(pk_base.items,'[]'::jsonb)) e0
      cross join lateral (select case
               when v_env ? wh._pickup_item_key(e0.value)
               then e0.value || jsonb_build_object('despachado',
                      coalesce(((v_env -> wh._pickup_item_key(e0.value))->>'despachado')::numeric, 0))
               else e0.value || jsonb_build_object('despachado', 0) end as value) e
      -- se queda solo lo que AÚN SE DEBE; lo saldado sale de la lista.
      where pk_base.id_pickup = v_idp
        and ( greatest(0, wh._num(coalesce(e.value->>'solicitado','0'))
                        - wh._num(coalesce(e.value->>'despachado','0'))) > 0
              or coalesce(e.value->>'sinSku','false') = 'true' )
    ) z;
  end if;

  -- ── Actualizar pickup ── [764] sella marcas_reset_ts: desde este instante,
  -- toda marca anterior está muerta para siempre.
  update wh.pickups
     set items            = v_items,
         estado           = v_nuevo_estado,
         fecha_atendido   = v_now,
         atendido_por     = '',
         marcas_reset_ts  = v_now,
         ultima_actividad = v_now
   where id_pickup = v_idp;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idGuia',        v_idguia,
    'estado',        v_nuevo_estado,
    'despachados',   jsonb_array_length(v_det),
    'noDespachados', v_no_desp
  ));
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM);
end;
$function$;

-- ═══ (3) liberar_pickup: soltar también sella el reset ════════════════════════
CREATE OR REPLACE FUNCTION wh.liberar_pickup(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idp   text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup','')),'');
  v_items jsonb;
  v_hay   boolean;
  v_now   timestamptz := now();
begin
  if coalesce((select valor from mos.config where clave='WH_PICKUP_ESTADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_PICKUP_ESTADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPickup'); end if;

  select items into v_items from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok',false,'error','Pickup no encontrado'); end if;

  select exists (
    select 1 from jsonb_array_elements(case when jsonb_typeof(v_items)='array' then v_items else '[]'::jsonb end) e
    where wh._num(coalesce(e->>'despachado','0')) > 0
  ) into v_hay;

  -- [753] soltar = descartar la separación. [764] y sellar el reset: esas marcas
  -- no pueden volver por un autosave rezagado.
  update wh.pickups
     set items            = wh._items_sin_separacion(items),
         atendido_por     = '',
         estado           = case when upper(coalesce(estado,'')) = 'EN_PROCESO' then 'PENDIENTE' else estado end,
         marcas_reset_ts  = v_now,
         ultima_actividad = v_now
   where id_pickup = v_idp;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('separacionDescartada', v_hay));
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;
$function$;

-- ═══ (4) consolidar_pickup_zona: candado vencido y week-death sellan el reset ═
CREATE OR REPLACE FUNCTION wh.consolidar_pickup_zona(p_zona text, p_bucket date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_acum_id   text := 'PCK-ACU-' || p_zona || '-' || to_char(p_bucket, 'YYYY-MM-DD');
  v_existing  jsonb;
  v_est       text;
  v_map       jsonb := '{}'::jsonb;
  v_it        jsonb;
  v_sku       text;
  v_key       text;
  v_c         numeric;
  v_pend      numeric;
  v_sol_add   numeric;
  v_desp_add  numeric;
  v_cand      record;
  v_items_out jsonb;
  v_abs       int := 0;
  v_rez       int := 0;
  v_lib       int := 0;
  v_now       timestamptz := now();
begin
  -- [753] candado vencido (1h) = soltar: la separación se descarta.
  -- [764] + sello del reset: la marca descartada no puede volver.
  update wh.pickups
     set estado = 'PENDIENTE', atendido_por = '',
         items  = wh._items_sin_separacion(items),
         marcas_reset_ts = v_now
   where coalesce(id_zona,'') = p_zona
     and upper(coalesce(estado,'')) = 'EN_PROCESO'
     and ultima_actividad < v_now - interval '1 hour';
  get diagnostics v_lib = row_count;

  select items, estado into v_existing, v_est
    from wh.pickups where id_pickup = v_acum_id for update;

  if v_existing is not null and jsonb_typeof(v_existing) = 'array' then
    for v_it in select * from jsonb_array_elements(v_existing) loop
      v_sku := coalesce(v_it->>'skuBase', '');
      if v_sku = '' then
        if coalesce((v_it->>'sinSku')::boolean, false) then
          v_c := wh._num(coalesce(v_it->>'constancia', v_it->>'solicitado', '0'));
          if v_c > 0 then
            v_key := 'SINSKU::' || coalesce(nullif(btrim(v_it->>'nombre'),''), 'SIN NOMBRE');
            v_map := jsonb_set(v_map, array[v_key], jsonb_build_object(
              'skuBase','', 'sinSku', true,
              'nombre', coalesce(nullif(btrim(v_it->>'nombre'),''), 'SIN NOMBRE'),
              'solicitado', 0, 'despachado', 0, 'constancia', v_c,
              'tsSolicitud', v_it->>'tsSolicitud'), true);
          end if;
        end if;
        continue;
      end if;
      -- [752] SEPARAR ≠ DESPACHAR: el seed ya NO netea `solicitado − despachado`.
      v_pend := wh._num(coalesce(v_it->>'solicitado','0'));
      if v_pend <= 0 then continue; end if;
      v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
        'skuBase', v_sku,
        'nombre', coalesce(v_it->>'nombre', v_sku),
        'solicitado', v_pend,
        'despachado', wh._num(coalesce(v_it->>'despachado','0')),   -- [752] separación en curso: se arrastra
        'tsSolicitud', v_it->>'tsSolicitud',
        'tsDespacho',  v_it->>'tsDespacho',
        'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb)
      ), true);
    end loop;
  end if;

  for v_cand in
    select id_pickup, items, coalesce(fuente,'') as fuente, fecha_creado from wh.pickups
    where coalesce(id_zona,'') = p_zona
      and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
      and coalesce(fuente,'') <> 'ACUMULADO_SEMANAL'
      and wh._bucket_dom((fecha_creado at time zone 'America/Lima')::date) <= p_bucket
    for update
  loop
    if jsonb_typeof(v_cand.items) = 'array' then
      for v_it in select * from jsonb_array_elements(v_cand.items) loop
        v_sku := coalesce(v_it->>'skuBase', '');
        if v_sku = '' then
          if coalesce((v_it->>'sinSku')::boolean, false) then
            v_c := wh._num(coalesce(v_it->>'constancia', v_it->>'solicitado', '0'));
            if v_c > 0 then
              v_key := 'SINSKU::' || coalesce(nullif(btrim(v_it->>'nombre'),''), 'SIN NOMBRE');
              if v_map ? v_key then
                v_map := jsonb_set(v_map, array[v_key,'constancia'],
                  to_jsonb(wh._num(coalesce(v_map->v_key->>'constancia','0')) + v_c), true);
              else
                v_map := jsonb_set(v_map, array[v_key], jsonb_build_object(
                  'skuBase','', 'sinSku', true,
                  'nombre', coalesce(nullif(btrim(v_it->>'nombre'),''), 'SIN NOMBRE'),
                  'solicitado', 0, 'despachado', 0, 'constancia', v_c,
                  'tsSolicitud', to_char(v_cand.fecha_creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')), true);
              end if;
            end if;
          end if;
          continue;
        end if;
        if v_cand.fuente = 'LISTA_IA' then
          v_sol_add  := wh._num(coalesce(v_it->>'solicitado','0'));
          v_desp_add := wh._num(coalesce(v_it->>'despachado','0'));
          if v_sol_add <= 0 and v_desp_add <= 0 then continue; end if;
        else
          v_sol_add  := greatest(0, wh._num(coalesce(v_it->>'solicitado','0')) - wh._num(coalesce(v_it->>'despachado','0')));
          v_desp_add := 0;
          if v_sol_add <= 0 then continue; end if;
        end if;
        if v_map ? v_sku then
          -- [752] neteo 540 INLINE: deuda = max(0, deuda + pedido − despachado_de_la_sombra).
          v_map := jsonb_set(v_map, array[v_sku,'solicitado'],
            to_jsonb(greatest(0, wh._num(coalesce(v_map->v_sku->>'solicitado','0')) + v_sol_add - v_desp_add)), true);
        else
          -- [752] item nuevo: entra ya neteado (piso 0 por producto).
          if greatest(0, v_sol_add - v_desp_add) > 0 then
            v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
              'skuBase', v_sku,
              'nombre', coalesce(v_it->>'nombre', v_sku),
              'solicitado', greatest(0, v_sol_add - v_desp_add),
              'despachado', 0,
              'tsSolicitud', coalesce(v_it->>'tsSolicitud',
                                      to_char(v_cand.fecha_creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')),
              'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb),
              'mov', (wh._mov_add(
                        coalesce(v_map -> v_key, '{}'::jsonb),
                        'pedido', coalesce((v_it->>'solicitado')::numeric,0),
                        coalesce(v_cand.fuente,''), v_cand.id_pickup, v_cand.fecha_creado
                      ))->'mov'
            ), true);
          end if;
        end if;
      end loop;
    end if;
    update wh.pickups
       set estado = 'ABSORBIDO',
           notas = coalesce(notas,'') || ' [abs:' || v_acum_id || ']',
           ultima_actividad = v_now
     where id_pickup = v_cand.id_pickup;
    v_abs := v_abs + 1;
  end loop;

  select coalesce(jsonb_agg(value), '[]'::jsonb) into v_items_out from jsonb_each(v_map);

  if v_existing is not null then
    -- [741] NO se toca ultima_actividad: es el reloj del candado.
    update wh.pickups
       set items = v_items_out,
           estado = case when upper(coalesce(estado,'')) in ('PENDIENTE','EN_PROCESO') then estado else 'PENDIENTE' end
     where id_pickup = v_acum_id;
  elsif jsonb_array_length(v_items_out) > 0 then
    insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
    values (v_acum_id, 'ACUMULADO_SEMANAL', 'PENDIENTE', v_items_out, p_zona,
            'ACUMULADO semana-domingo ' || to_char(p_bucket,'YYYY-MM-DD'), 'sistema', v_now, v_now);
  end if;

  -- [753] week-death: la separación muere con la semana. [764] + sello del reset.
  update wh.pickups
     set estado = 'REZAGADO', atendido_por = '',
         items  = wh._items_sin_separacion(items),
         marcas_reset_ts = v_now
   where coalesce(id_zona,'') = p_zona
     and fuente = 'ACUMULADO_SEMANAL'
     and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL','EN_PROCESO')
     and id_pickup <> v_acum_id
     and id_pickup like 'PCK-ACU-' || p_zona || '-%'
     and right(id_pickup, 10) ~ '^\d{4}-\d{2}-\d{2}$'
     and to_date(right(id_pickup, 10), 'YYYY-MM-DD') < p_bucket;
  get diagnostics v_rez = row_count;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'acum', v_acum_id, 'absorbidos', v_abs, 'rezagados', v_rez, 'liberados', v_lib,
    'items', jsonb_array_length(v_items_out)));
end;
$function$;
