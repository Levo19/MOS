-- 147_me_autolock_guias_zona.sql — AUTOLOCK DE GUÍAS DE ZONA (ME) · espejo de WH — ADITIVO / INERTE-AL-STOCK
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- App de DINERO/inventario. BUILD 2 del PLAN_zona_ME_supabase.md — "Autolock guías de zona (espejo de WH)".
-- Construye SOBRE 140 (me.guias_detalle.cantidad_aplicada ya existe) + el patrón 142/143 de WH.
--
-- ── DECISIÓN DE MODELO (documentada, como pide el plan) ──────────────────────────────────────────────────────
--   Estado actual de ME: las guías de zona NACEN 'CONFIRMADO' (462 filas, sync GAS→Sheets→Supabase). El stock de
--   guías en Supabase es DIRECTO-INERTE: me.zona_registrar_guia/zona_descontar_venta existen pero NO se llaman
--   (gate GAS ME_ESCRITURA_STOCK_DIRECTA=OFF). Hoy el saldo lo mueve GAS contra la Hoja. Es decir: en el modelo
--   Supabase, una guía de zona TODAVÍA no aplica stock al cerrarse — solo "existe".
--
--   ⇒ Elegimos el MODELO DE CIERRE IDEMPOTENTE (no un simple lock de edición), por dos razones:
--     (1) Es el espejo EXACTO de WH (cerrar_guia_idempotente + autocierre 30min + reapertura), que es lo que el
--         dueño pidió ("espejo de WH"), y deja el camino listo para cuando el stock-directo de ME se active.
--     (2) La REGLA DE ORO (reabrir/recerrar = delta 0) se garantiza con la columna cantidad_aplicada (ya en 140):
--         cada línea recuerda cuánto YA impactó; cerrar aplica solo (cantidad − cantidad_aplicada). Reabrir NO
--         revierte (lo revierte editar/anular la línea); recerrar sin cambios → delta 0 → no duplica.
--
--   El "lock de edición" simple lo da, además, el estado: una guía CERRADA no se edita (eso lo hace el front al
--   ver estado='CERRADA'); para editarla hay que REABRIR (auth-admin). Así cubrimos ambas lecturas del plan.
--
-- ── GATE / INERTE AL STOCK REAL ─────────────────────────────────────────────────────────────────────────────
--   El cierre aplica al saldo me.stock_zonas SOLO si v_aplicar_stock=true. HOY ESTÁ OFF (igual que 141/146). El
--   cierre SIEMPRE registra el kardex (trazabilidad idempotente) + marca cantidad_aplicada + estado=CERRADA, pero
--   NO mueve el saldo operativo hasta que el dueño desbloquee (tras validar + apagar el sync de guías). El UPDATE
--   de saldo, cuando se active, es ATÓMICO (cantidad ± delta), nunca read-modify-write (lección WH = lost-update).
--
-- ── AUTOCIERRE + REAPERTURA ─────────────────────────────────────────────────────────────────────────────────
--   · Autocierre: cron me-autocierre-inactividad cada 15 min cierra (idempotente) las guías 'ABIERTA' cuya
--     inactividad supera ME_AUTOCIERRE_MIN (default 30). Hoy NINGUNA guía nace 'ABIERTA' (todas 'CONFIRMADO') →
--     el cron es NO-OP seguro hasta que el cutover marque las guías nuevas como 'ABIERTA'. INERTE por diseño.
--   · Reapertura: me.reabrir_guia_zona(idGuia) → estado='ABIERTA'. NO revierte stock (coherente con el modelo).
--     Gate de admin: solo service_role/PWA-MOS (mos._claim_ok). La PWA ME NO reabre (la reapertura es acción de
--     admin, igual que en WH). Idempotente: reabrir una ya ABIERTA es no-op.
--
-- ── SEGURIDAD / IDEMPOTENCIA ────────────────────────────────────────────────────────────────────────────────
--   · BACKFILL: las 462 guías 'CONFIRMADO' existentes se marcan cantidad_aplicada = cantidad (= "ya aplicadas"
--     históricamente por GAS). Así, si alguna se reabriera y recerrara SIN editar, el cierre dará delta 0 (NO
--     re-aplica). Las guías nuevas que nazcan 'ABIERTA' arrancan en 0 → su 1er cierre aplica una vez.
--   · Kardex con origen único determinista (id_guia#linea) → on conflict do nothing protege la traza.
--   · security definer · search_path='' · revoke public · grant service_role. 100% Supabase / pg_cron (sin GAS).
--   · Idempotente de punta a punta: re-correr este script es no-op seguro (no re-backfillea lo ya aplicado).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create schema if not exists mos;
create extension if not exists pg_cron;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PASO 1 — columna reloj me.guias_cabecera.ultima_actividad (aditiva) + índice para el autocierre.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
alter table me.guias_cabecera add column if not exists ultima_actividad timestamptz;
create index if not exists ix_me_guias_ultima_actividad on me.guias_cabecera (ultima_actividad);

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PASO 2 — BACKFILL cantidad_aplicada de las guías existentes (idempotente).
--   Toda guía existente (sync GAS, nace CONFIRMADO) se considera YA aplicada → cantidad_aplicada = cantidad.
--   Solo toca filas donde aún es 0 y la cantidad no es 0 (no pisa lo ya reconciliado). Re-correr = no-op.
--   Las guías nuevas que el cutover cree como 'ABIERTA' tendrán cantidad_aplicada = 0 (default) → 1er cierre aplica.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
update me.guias_detalle d
   set cantidad_aplicada = d.cantidad
  from me.guias_cabecera g
 where g.id_guia = d.id_guia
   and upper(coalesce(g.estado,'')) <> 'ABIERTA'           -- todo lo que NO esté abierto = histórico aplicado
   and coalesce(d.cantidad_aplicada,0) = 0
   and coalesce(d.cantidad,0) <> 0;

-- inicializar el reloj de las existentes (no pisa si ya tiene valor).
update me.guias_cabecera set ultima_actividad = coalesce(ultima_actividad, fecha) where ultima_actividad is null;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PASO 3 — trigger de ULTIMA_ACTIVIDAD (espejo WH 143 PASO 2).
--   Toca la cabecera = now() en INSERT de línea o cuando 'cantidad' cambia (WHEN guard → ignora re-syncs no-op).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me._tg_guia_detalle_actividad()
returns trigger
language plpgsql
security definer
set search_path = ''
as $tg$
begin
  update me.guias_cabecera set ultima_actividad = now() where id_guia = new.id_guia;
  return new;
end;
$tg$;

drop trigger if exists tg_me_guia_detalle_actividad_ins on me.guias_detalle;
drop trigger if exists tg_me_guia_detalle_actividad_upd on me.guias_detalle;

create trigger tg_me_guia_detalle_actividad_ins
  after insert on me.guias_detalle
  for each row execute function me._tg_guia_detalle_actividad();

create trigger tg_me_guia_detalle_actividad_upd
  after update on me.guias_detalle
  for each row
  when (old.cantidad is distinct from new.cantidad)
  execute function me._tg_guia_detalle_actividad();

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PASO 4 — me.cerrar_guia_zona_idempotente(p_id_guia) — cierre por delta-reconciliación (espejo WH 143 PASO 3).
--   Por cada línea: delta = cantidad − cantidad_aplicada.
--     · delta = 0 → SKIP (no toca stock ni kardex) → recerrar = no-op.
--     · delta ≠ 0 → (gated) UPDATE ATÓMICO de me.stock_zonas + kardex con ref única + cantidad_aplicada=cantidad.
--   Signo por TIPO de la guía: SALIDA* resta, ENTRADA*/TRASLADO_IN suma. SALIDA_VENTAS NO mueve saldo aquí (lo
--   maneja zona_descontar_venta por caja → evitar doble-conteo) → solo marca aplicado + cierra.
--   ⚠ v_aplicar_stock := false (INERTE): hoy registra kardex + marca, NO mueve me.stock_zonas. Estado→CERRADA.
--   FOR UPDATE en la cabecera serializa cierres concurrentes. GATE: service_role / PWA-MOS / GAS (mos._claim_ok).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.cerrar_guia_zona_idempotente(p_id_guia text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id        text := nullif(btrim(coalesce(p_id_guia,'')), '');
  v_estado    text;
  v_tipo      text;
  v_zona      text;
  v_signo_in  boolean;       -- la guía SUMA al saldo (entrada/traslado-in) vs resta (salida)
  v_es_venta  boolean;       -- SALIDA_VENTAS: no mueve saldo aquí (lo hace zona_descontar_venta)
  v_aplicar_stock boolean := true;    -- ✅ [GATE-STOCK] ACTIVO (2026-06-17 go-live, sync OFF): el cierre aplica delta a me.stock_zonas (UPDATE atómico).
  v_d         record;
  v_cb        text;
  v_cant      numeric(20,3);
  v_apl       numeric(20,3);
  v_delta     numeric(20,3);
  v_signo     numeric(20,3);
  v_refk      text;
  v_aplicadas int := 0;
  v_saltadas  int := 0;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- lock de cabecera: serializa contra cierres concurrentes (doble-tap / cron + manual)
  select estado, tipo, zona_id into v_estado, v_tipo, v_zona
    from me.guias_cabecera where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  v_tipo     := upper(coalesce(v_tipo,''));
  v_zona     := upper(btrim(coalesce(v_zona,'')));
  v_signo_in := (v_tipo like 'ENTRADA%' or v_tipo like 'TRASLADO_IN%');
  v_es_venta := (v_tipo = 'SALIDA_VENTAS' or v_tipo = 'SALIDA_VENTA');

  for v_d in
    select linea, cod_barras, cantidad, cantidad_aplicada
      from me.guias_detalle
     where id_guia = v_id
     order by linea asc nulls last
  loop
    v_cb   := nullif(btrim(coalesce(v_d.cod_barras,'')), '');
    v_cant := coalesce(v_d.cantidad, 0);
    v_apl  := coalesce(v_d.cantidad_aplicada, 0);
    v_delta := v_cant - v_apl;

    -- línea sin código → solo alinear marca, sin stock
    if v_cb is null then
      update me.guias_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
      continue;
    end if;

    -- delta 0 → SKIP TOTAL (red de seguridad anti-duplicado: recerrar no toca nada)
    if v_delta = 0 then
      v_saltadas := v_saltadas + 1;
      continue;
    end if;

    -- VENTA: no mueve saldo aquí (lo hace zona_descontar_venta por caja). Solo marca aplicado.
    if not v_es_venta then
      v_signo := case when v_signo_in then v_delta else -v_delta end;
      v_refk  := 'CIERRE-GUIA:'||v_id||':'||v_d.linea;

      -- kardex con ref única determinista (idempotente por línea aunque se recierre N veces)
      perform me.zona_kardex_registrar(jsonb_build_object(
        'zona', v_zona, 'codBarra', v_cb,
        'tipo', case when v_signo_in then 'TRASLADO_IN' else 'SALIDA_JEFA' end,
        'delta', v_signo, 'refTipo', 'GUIA', 'refId', v_refk,
        'usuario', 'sistema-cierre-zona', 'origen', 'CIERRE-IDEM'));

      -- ┌─ [GATE-STOCK · INERTE] ─ saldo operativo me.stock_zonas (OFF hoy). UPDATE ATÓMICO (suma signo). ─┐
      if v_aplicar_stock then
        insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
          values (v_cb, v_zona, v_signo, 'sistema-cierre-zona', now())
        on conflict (cod_barras, zona_id) do update
          set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_signo,
              fecha_ultimo_registro = now();
      end if;
      -- └─ /GATE-STOCK ─────────────────────────────────────────────────────────────────────────────────┘
    end if;

    update me.guias_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
    v_aplicadas := v_aplicadas + 1;
  end loop;

  update me.guias_cabecera set estado = 'CERRADA' where id_guia = v_id;

  return jsonb_build_object('ok', true, 'idGuia', v_id, 'estado', 'CERRADA',
    'stockAplicado', v_aplicar_stock, 'lineasAplicadas', v_aplicadas, 'lineasSaltadas', v_saltadas,
    'eraEstado', v_estado);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM, 'idGuia', v_id);
end;
$fn$;
revoke all on function me.cerrar_guia_zona_idempotente(text) from public, anon, authenticated;
grant execute on function me.cerrar_guia_zona_idempotente(text) to service_role;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PASO 5 — me.reabrir_guia_zona(p {idGuia}) — REAPERTURA (auth-admin). estado→ABIERTA. NO revierte stock.
--   Idempotente: reabrir una ABIERTA es no-op. Gate mos._claim_ok (PWA-MOS / service_role / GAS) — NO la PWA ME.
--   (La PWA ME mintea app='mosExpress' → mos._claim_ok=false → no puede reabrir. La reapertura es de admin, = WH.)
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.reabrir_guia_zona(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idGuia', p->>'idGuiaWH', '')), '');
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_estado text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  select estado into v_estado from me.guias_cabecera where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  if upper(coalesce(v_estado,'')) = 'ABIERTA' then
    return jsonb_build_object('ok',true,'dedup',true,'idGuia',v_id,'estado','ABIERTA','eraEstado',v_estado);
  end if;

  -- reabrir + tocar el reloj (para que el autocierre vuelva a contar la inactividad desde ahora).
  update me.guias_cabecera set estado = 'ABIERTA', ultima_actividad = now() where id_guia = v_id;

  return jsonb_build_object('ok',true,'idGuia',v_id,'estado','ABIERTA','eraEstado',v_estado,'reabiertoPor',v_user);
end;
$fn$;
revoke all on function me.reabrir_guia_zona(jsonb) from public, anon, authenticated;
grant execute on function me.reabrir_guia_zona(jsonb) to service_role;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PASO 6a — config ME_AUTOCIERRE_MIN (default 30).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
insert into mos.config (clave, valor, descripcion) values
  ('ME_AUTOCIERRE_MIN','30','ME: minutos de inactividad (sin cambios de cantidad) para autocerrar una guia de zona ABIERTA.')
on conflict (clave) do nothing;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PASO 6b — me.autocerrar_guias_zona_inactivas() — cron RPC (espejo WH 143 PASO 4b).
--   Cierra (idempotente) las guías 'ABIERTA' con inactividad > ME_AUTOCIERRE_MIN. Cada una en su propio
--   begin/exception (un error no rompe el cron). Loguea en mos.cron_log (job='me_autocierre_inactividad').
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.autocerrar_guias_zona_inactivas()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_min      int := coalesce((select (regexp_replace(valor,'[^0-9.\-]','','g'))::numeric::int
                                from mos.config where clave='ME_AUTOCIERRE_MIN' limit 1), 30);
  v_g        record;
  v_res      jsonb;
  v_cerradas int := 0;
  v_errores  int := 0;
  v_detalle  jsonb := '[]'::jsonb;
begin
  for v_g in
    select id_guia
      from me.guias_cabecera
     where upper(coalesce(estado,'')) = 'ABIERTA'
       and now() - coalesce(ultima_actividad, fecha) > make_interval(mins => v_min)
     order by coalesce(ultima_actividad, fecha) asc
  loop
    begin
      v_res := me.cerrar_guia_zona_idempotente(v_g.id_guia);
      if coalesce((v_res->>'ok')::boolean, false) then v_cerradas := v_cerradas + 1;
      else v_errores := v_errores + 1; end if;
      v_detalle := v_detalle || jsonb_build_object('idGuia', v_g.id_guia, 'rpc', v_res);
    exception when others then
      v_errores := v_errores + 1;
      v_detalle := v_detalle || jsonb_build_object('idGuia', v_g.id_guia, 'error', SQLERRM);
    end;
  end loop;

  begin
    insert into mos.cron_log(job, ok, resultado)
      values ('me_autocierre_inactividad', v_errores = 0,
              jsonb_build_object('minInactividad', v_min, 'cerradas', v_cerradas, 'errores', v_errores, 'detalle', v_detalle));
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'minInactividad', v_min, 'cerradas', v_cerradas, 'errores', v_errores, 'detalle', v_detalle);
end;
$fn$;
revoke all on function me.autocerrar_guias_zona_inactivas() from public, anon, authenticated;
grant execute on function me.autocerrar_guias_zona_inactivas() to service_role;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PASO 6c — pg_cron 'me-autocierre-inactividad' cada 15 min (espejo de 'wh-autocierre-inactividad').
--   Idempotente: desagenda si ya existía antes de re-agendar.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
select cron.unschedule('me-autocierre-inactividad') where exists (select 1 from cron.job where jobname='me-autocierre-inactividad');
select cron.schedule('me-autocierre-inactividad', '*/15 * * * *', $$ select me.autocerrar_guias_zona_inactivas(); $$);

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PASO 7 — WRAPPER mos.reabrir_guia_zona (profile 'mos') para que la PWA MOS reabra (acción de admin).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.reabrir_guia_zona(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.reabrir_guia_zona(p);
end; $fn$;
revoke all on function mos.reabrir_guia_zona(jsonb) from public;
grant execute on function mos.reabrir_guia_zona(jsonb) to service_role, authenticated;
