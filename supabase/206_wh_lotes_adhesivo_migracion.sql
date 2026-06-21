-- 206_wh_lotes_adhesivo_migracion.sql
-- ════════════════════════════════════════════════════════════════════════════
-- FASE 1 (INERTE) — Migración de la IMPRESIÓN DE ADHESIVOS (lotes) GAS+Sheets → Supabase.
--
-- HOY: el motor de etiquetas vive en GAS (hoja LOTES_ADHESIVO + trigger time-based
-- procesarLotesPendientes + PrintNode). El contador `completadas` se persistía DESPUÉS
-- del poll de 25s y FUERA del lock → ventana de duplicación = sub-jobs repetidos
-- (40 envasados → 50 u 80 adhesivos). Ver Envasados.gs:imprimirSubLoteAdhesivo.
--
-- AQUÍ: la pieza de DINERO/OPERACIÓN (el contador del lote) se migra a Supabase con la
-- mejora nativa: RESERVA ATÓMICA del rango vía UPDATE bajo FOR UPDATE (una sola tx) →
-- ningún driver concurrente (cron, retry, 2ª pestaña) puede reclamar el mismo rango.
-- La generación TSPL2 + el POST a PrintNode (API key server-side) van en una Edge Function
-- (Fase 2). El "fire-and-forget" pasa a pg_cron→Edge Function (Fase 3).
--
-- ⚠️ La tabla `wh.lotes_adhesivo` YA EXISTE (sombra del dual-write GAS): columnas
-- codigo_barra/total_etq(numeric)/completadas(numeric)/sub_job_size(numeric)/items_json(jsonb),
-- SIN idempotency_key. Esta fase se ADAPTA a ese esquema: solo AGREGA idempotency_key +
-- índices + RPCs. NO toca RLS ni el resto (para no romper el dual-write vivo ni lectores
-- existentes). El CHECK `completadas <= total_etq` (garantía dura) se DIFIERE al cutover
-- (mientras GAS siga escribiendo valores posiblemente buggy, el CHECK los rechazaría).
-- La RPC `reservar` con least() ya impide sobre-conteo sin necesitar el CHECK.
--
-- INERTE: flag `WH_LOTE_ADHESIVO_DIRECTO` default '0'. Las RPCs de escritura gatean en el
-- flag → mientras OFF, GAS sigue siendo la vía viva. Patrón = 60_wh_registrar_envasado.
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor, descripcion) values
  ('WH_LOTE_ADHESIVO_DIRECTO','0','WH: impresion de adhesivos (lotes) directo a Supabase (Edge + RPC atomica). OFF=GAS.')
on conflict (clave) do nothing;

-- Solo agregamos lo que falta sobre la sombra existente.
alter table wh.lotes_adhesivo add column if not exists idempotency_key text;

create unique index if not exists ux_lotes_adhesivo_idem
  on wh.lotes_adhesivo(idempotency_key) where idempotency_key is not null;
create index if not exists ix_lotes_adhesivo_cola
  on wh.lotes_adhesivo(status, fecha_creacion) where completadas < total_etq;

-- Serializa una fila a jsonb (shape camelCase paritario con el frontend GAS).
create or replace function wh._lote_adh_json(l wh.lotes_adhesivo)
returns jsonb language sql immutable set search_path = '' as $fn$
  select jsonb_build_object(
    'idLote', l.id_lote, 'codigoBarra', l.codigo_barra, 'descripcion', l.descripcion,
    'vto', l.vto, 'total', l.total_etq, 'totalEtq', l.total_etq, 'completadas', l.completadas,
    'subJobSize', l.sub_job_size, 'status', l.status, 'ultimoError', l.ultimo_error,
    'ultimoPrintNodeJobId', l.ultimo_printnode_job_id, 'printerId', l.printer_id,
    'tipoEtiqueta', l.tipo_etiqueta, 'itemsJson', l.items_json, 'usuario', l.usuario, 'origen', l.origen
  );
$fn$;

-- ── 1) CREAR (idempotente por idempotency_key) ──────────────────────────────
create or replace function wh.lote_adhesivo_crear(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_cod   text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_total int  := floor(wh._num(p->>'total'))::int;
  v_idem  text := nullif(btrim(coalesce(p->>'idempotencyKey','')), '');
  v_size  int  := floor(wh._num(p->>'subJobSize'))::int;
  v_id    text;
  v_row   wh.lotes_adhesivo;
begin
  if coalesce((select valor from mos.config where clave='WH_LOTE_ADHESIVO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LOTE_ADHESIVO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_cod is null then return jsonb_build_object('ok',false,'error','FALTA_codigoBarra'); end if;
  if v_total <= 0 then return jsonb_build_object('ok',false,'error','TOTAL_INVALIDO'); end if;
  if v_size is null or v_size <= 0 then
    v_size := coalesce(floor(wh._num((select valor from mos.config where clave='ADHESIVO_SUB_JOB_SIZE' limit 1)))::int, 25);
    if v_size <= 0 then v_size := 25; end if;
  end if;

  if v_idem is not null then
    select * into v_row from wh.lotes_adhesivo where idempotency_key = v_idem limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', wh._lote_adh_json(v_row)); end if;
  end if;

  v_id := 'LA' || (extract(epoch from clock_timestamp())*1000)::bigint
               || '_' || coalesce(v_idem, substr(md5(random()::text),1,6));

  insert into wh.lotes_adhesivo (id_lote, idempotency_key, codigo_barra, descripcion, vto,
    total_etq, completadas, sub_job_size, status, printer_id, tipo_etiqueta, items_json,
    usuario, origen, fecha_creacion, fecha_ultimo_update)
  values (v_id, v_idem, v_cod, coalesce(p->>'descripcion',''), coalesce(p->>'vto',''),
    v_total, 0, v_size, 'ENCOLADO', coalesce(p->>'printerId',''),
    upper(coalesce(p->>'tipoEtiqueta','ADHESIVO_ENVASADO')), p->'itemsJson',
    coalesce(p->>'usuario',''), upper(coalesce(p->>'origen','WH')), now(), now())
  on conflict (idempotency_key) where idempotency_key is not null do nothing
  returning * into v_row;

  if not found then
    select * into v_row from wh.lotes_adhesivo where idempotency_key = v_idem limit 1;
    return jsonb_build_object('ok',true,'dedup',true,'data', wh._lote_adh_json(v_row));
  end if;
  return jsonb_build_object('ok',true,'dedup',false,'data', wh._lote_adh_json(v_row));
end;
$fn$;

-- ── 2) RESERVAR sub-job (LA MEJORA: claim ATÓMICO del rango) ─────────────────
-- Devuelve [desde, hasta) a imprimir. FOR UPDATE serializa concurrentes: el 2º reservador
-- espera el commit del 1º y lee el `completadas` YA avanzado → nunca reclama el mismo rango.
create or replace function wh.lote_adhesivo_reservar(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'idLote','')), '');
  v_old int; v_total int; v_size int; v_status text;
  v_qty int; v_nuevas int;
begin
  if coalesce((select valor from mos.config where clave='WH_LOTE_ADHESIVO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LOTE_ADHESIVO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTA_idLote'); end if;

  select completadas::int, total_etq::int, sub_job_size::int, status
    into v_old, v_total, v_size, v_status
    from wh.lotes_adhesivo where id_lote = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','LOTE_NO_ENCONTRADO'); end if;
  if v_status = 'CANCELADO' then return jsonb_build_object('ok',false,'error','LOTE_CANCELADO'); end if;

  v_qty := least(v_size, v_total - v_old);
  if v_qty <= 0 then
    update wh.lotes_adhesivo set status='COMPLETADO', fecha_ultimo_update=now() where id_lote=v_id;
    return jsonb_build_object('ok',true,'data', jsonb_build_object(
      'idLote',v_id,'qty',0,'desde',v_old,'hasta',v_old,'completadas',v_old,'total',v_total,'status','COMPLETADO'));
  end if;

  v_nuevas := v_old + v_qty;
  update wh.lotes_adhesivo
     set completadas = v_nuevas, status = 'IMPRIMIENDO', fecha_ultimo_update = now()
   where id_lote = v_id;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'idLote', v_id, 'qty', v_qty, 'desde', v_old, 'hasta', v_nuevas,
    'completadas', v_nuevas, 'total', v_total, 'status', 'IMPRIMIENDO'));
end;
$fn$;

-- ── 3) MARCAR resultado (confirmar / pausar / revertir rango no impreso) ─────
-- p: { idLote, status, ultimoError?, ultimoPrintNodeJobId?, reembolsar?, completadasEsperado? }
create or replace function wh.lote_adhesivo_marcar(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'idLote','')), '');
  v_st   text := nullif(btrim(coalesce(p->>'status','')), '');
  v_reemb int := coalesce(floor(wh._num(p->>'reembolsar'))::int, 0);
  v_esp  int := case when (p ? 'completadasEsperado') then floor(wh._num(p->>'completadasEsperado'))::int else null end;
  v_cur  int; v_total int; v_row wh.lotes_adhesivo;
begin
  if coalesce((select valor from mos.config where clave='WH_LOTE_ADHESIVO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LOTE_ADHESIVO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTA_idLote'); end if;

  select completadas::int, total_etq::int into v_cur, v_total
    from wh.lotes_adhesivo where id_lote=v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','LOTE_NO_ENCONTRADO'); end if;

  -- Revertir el rango no impreso (out-of-paper). Guard: solo si `completadas` sigue donde
  -- lo dejó la reserva (v_esp) → no pisar el avance de otro driver.
  if v_reemb > 0 and (v_esp is null or v_cur = v_esp) then
    update wh.lotes_adhesivo set completadas = greatest(0, v_cur - v_reemb) where id_lote=v_id;
  end if;

  update wh.lotes_adhesivo
     set status = coalesce(v_st, status),
         ultimo_error = coalesce(p->>'ultimoError', ultimo_error),
         ultimo_printnode_job_id = coalesce(p->>'ultimoPrintNodeJobId', ultimo_printnode_job_id),
         fecha_ultimo_update = now()
   where id_lote = v_id
   returning * into v_row;

  if v_row.completadas >= v_row.total_etq
     and coalesce(v_st,'') not like 'PAUSADO%' and coalesce(v_st,'') <> 'CANCELADO' then
    update wh.lotes_adhesivo set status='COMPLETADO' where id_lote=v_id returning * into v_row;
  end if;

  return jsonb_build_object('ok',true,'data', wh._lote_adh_json(v_row));
end;
$fn$;

-- ── 4) PENDIENTES (cola para pg_cron / Edge) ────────────────────────────────
create or replace function wh.lote_adhesivo_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_lim int := coalesce(floor(wh._num(p->>'limit'))::int, 8);
begin
  if coalesce((select valor from mos.config where clave='WH_LOTE_ADHESIVO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LOTE_ADHESIVO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_lim <= 0 or v_lim > 50 then v_lim := 8; end if;
  return jsonb_build_object('ok',true,'data', coalesce((
    select jsonb_agg(wh._lote_adh_json(l) order by l.fecha_creacion)
    from (
      select * from wh.lotes_adhesivo l
      where l.completadas < l.total_etq
        and ( l.status in ('ENCOLADO','CREADO')
              or ( l.status in ('IMPRIMIENDO','CALIBRANDO')
                   and l.fecha_ultimo_update < now() - interval '90 seconds' ) )
      order by l.fecha_creacion
      limit v_lim
    ) l
  ), '[]'::jsonb));
end;
$fn$;

-- ── 5) GET (polling de progreso del frontend) ───────────────────────────────
create or replace function wh.lote_adhesivo_get(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idLote','')), ''); v_row wh.lotes_adhesivo;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTA_idLote'); end if;
  select * into v_row from wh.lotes_adhesivo where id_lote = v_id;
  if not found then return jsonb_build_object('ok',false,'error','LOTE_NO_ENCONTRADO'); end if;
  return jsonb_build_object('ok',true,'data', wh._lote_adh_json(v_row));
end;
$fn$;

-- ── 6) CANCELAR ─────────────────────────────────────────────────────────────
create or replace function wh.lote_adhesivo_cancelar(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idLote','')), ''); v_row wh.lotes_adhesivo;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTA_idLote'); end if;
  update wh.lotes_adhesivo set status='CANCELADO', fecha_ultimo_update=now()
   where id_lote=v_id and status <> 'COMPLETADO' returning * into v_row;
  if not found then
    select * into v_row from wh.lotes_adhesivo where id_lote=v_id;
    if not found then return jsonb_build_object('ok',false,'error','LOTE_NO_ENCONTRADO'); end if;
  end if;
  return jsonb_build_object('ok',true,'data', wh._lote_adh_json(v_row));
end;
$fn$;

-- ── GRANTS (= 60_wh_registrar_envasado) ─────────────────────────────────────
revoke all on function wh.lote_adhesivo_crear(jsonb)      from public;
revoke all on function wh.lote_adhesivo_reservar(jsonb)   from public;
revoke all on function wh.lote_adhesivo_marcar(jsonb)     from public;
revoke all on function wh.lote_adhesivo_pendientes(jsonb) from public;
revoke all on function wh.lote_adhesivo_get(jsonb)        from public;
revoke all on function wh.lote_adhesivo_cancelar(jsonb)   from public;
grant execute on function wh.lote_adhesivo_crear(jsonb)      to service_role, authenticated;
grant execute on function wh.lote_adhesivo_reservar(jsonb)   to service_role, authenticated;
grant execute on function wh.lote_adhesivo_marcar(jsonb)     to service_role, authenticated;
grant execute on function wh.lote_adhesivo_pendientes(jsonb) to service_role, authenticated;
grant execute on function wh.lote_adhesivo_get(jsonb)        to service_role, authenticated;
grant execute on function wh.lote_adhesivo_cancelar(jsonb)   to service_role, authenticated;
