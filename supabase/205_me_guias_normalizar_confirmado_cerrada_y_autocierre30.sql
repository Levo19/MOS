-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 205_me_guias_normalizar_confirmado_cerrada_y_autocierre30.sql
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- App de DINERO/INVENTARIO. Dos ajustes al ciclo de guías ME, MONEY-SAFE, idempotentes, reversibles.
-- Construye sobre 147 (cerrar/reabrir/autocierre) + 204 (modelo ABIERTA, flag ME_GUIAS_CICLO_ABIERTA).
--
-- ── TAREA 1 — Autocierre a 30 min (paridad WH) ────────────────────────────────────────────────────────────────
--   El umbral YA es 30 (config mos.ME_AUTOCIERRE_MIN='30', igual que WH_AUTOCIERRE_MIN; el default de la función
--   me.autocerrar_guias_zona_inactivas también es 30). Este archivo solo lo RE-AFIRMA de forma idempotente
--   (upsert a '30') para dejarlo explícito y versionado. El cron `me-autocierre-inactividad` (cada 15 min, jobid 12)
--   ya cierra las ABIERTA con >30 min de inactividad vía me.cerrar_guia_zona_idempotente (aplica stock UNA vez).
--   Validado en rollback: >30min→CERRADA+stock 1 vez; 2do pase/recerrar→delta 0 (no dobla); <30min→intacta.
--   El trigger me._tg_guia_detalle_actividad mantiene viva la guía mientras se editan ítems (la inactividad
--   se cuenta desde el último cambio de cantidad), igual que WH.
--
-- ── TAREA 2 — Normalizar guías viejas CONFIRMADO → CERRADA (SOLO ESTADO, JAMÁS stock) ─────────────────────────
--   🔴 CRÍTICO MONEY-SAFE: las 409 guías manuales viejas en estado 'CONFIRMADO' ya aplicaron su stock al crear
--      (cantidad_aplicada=cantidad en TODAS sus líneas — verificado: 0 desalineadas). Para coherencia con el
--      modelo nuevo (ABIERTA→CERRADA), pasan a 'CERRADA' con un UPDATE de SOLO ESTADO. NO se llama cerrar_guia
--      (aunque daría delta 0, el UPDATE directo es estrictamente más seguro: no toca kardex ni stock_zonas).
--   GUARDA DURA: solo migra guías cuyo detalle esté 100% alineado (cantidad_aplicada = cantidad en todas las líneas).
--      Si alguna tuviera cantidad_aplicada<>cantidad NO se migra (se reporta) → cero riesgo de cerrar a ciegas algo
--      con stock pendiente. (Hoy: 0 omitidas.)
--   SALIDA_VENTAS: NO se tocan (siguen 'CONFIRMADO'); su stock va por ticket (zona_descontar_venta), no por cierre.
--      El frontend trata CONFIRMADO y CERRADA por igual como "cerrada/no editable" (solo ABIERTA es editable).
--   IDEMPOTENTE: re-correr no afecta filas (ya no hay CONFIRMADO no-ventas alineadas). REVERSIBLE: los id_guia
--      migrados quedan logueados en mos.cron_log (job='me_migr_confirmado_cerrada_205'); para revertir un lote:
--      update me.guias_cabecera set estado='CONFIRMADO' where id_guia = any(<ids del log>).
--
-- ── SEGURIDAD ────────────────────────────────────────────────────────────────────────────────────────────────
--   NO redefine funciones. Solo: (1) upsert idempotente del config 30, (2) UPDATE de estado con guarda dura,
--   (3) INSERT de auditoría en mos.cron_log. Validado end-to-end en transacción ROLLBACK antes de aplicar:
--   stock_zonas y cantidad_aplicada IDÉNTICOS antes/después (ni un decimal movido). Re-correr = no-op.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── TAREA 1: re-afirmar umbral 30 min (idempotente) ───────────────────────────────────────────────────────────
insert into mos.config (clave, valor, descripcion) values
  ('ME_AUTOCIERRE_MIN','30',
   'ME: minutos de inactividad (sin cambios de cantidad) para autocerrar una guia de zona ABIERTA. Paridad WH (30).')
on conflict (clave) do update set valor = '30', descripcion = excluded.descripcion;

-- ── TAREA 2: normalizar CONFIRMADO → CERRADA (solo estado, con guarda dura + auditoría) ────────────────────────
do $mig$
declare
  v_ids        text[];
  v_n          int := 0;
  v_omitidas   int := 0;
begin
  -- Reporte de seguridad: ¿alguna candidata con cantidad_aplicada<>cantidad? (no se migrará)
  select count(distinct gc.id_guia) into v_omitidas
    from me.guias_cabecera gc
    join me.guias_detalle gd on gd.id_guia = gc.id_guia
   where gc.estado = 'CONFIRMADO' and gc.tipo <> 'SALIDA_VENTAS'
     and coalesce(gd.cantidad_aplicada,0) <> coalesce(gd.cantidad,0);

  -- Migración SOLO ESTADO, gateada por "todas las líneas alineadas" (not exists desalineada).
  with upd as (
    update me.guias_cabecera gc
       set estado = 'CERRADA'
     where gc.estado = 'CONFIRMADO'
       and gc.tipo <> 'SALIDA_VENTAS'
       and not exists (
         select 1 from me.guias_detalle gd
          where gd.id_guia = gc.id_guia
            and coalesce(gd.cantidad_aplicada,0) <> coalesce(gd.cantidad,0)
       )
    returning gc.id_guia
  )
  select array_agg(id_guia), count(*) into v_ids, v_n from upd;

  -- Auditoría reversible (solo si hubo cambios → re-correr no ensucia el log).
  if coalesce(v_n,0) > 0 then
    insert into mos.cron_log(job, ok, resultado)
      values ('me_migr_confirmado_cerrada_205', true,
              jsonb_build_object('migradas', v_n, 'omitidas', v_omitidas, 'idsMigrados', to_jsonb(v_ids)));
  end if;

  raise notice '[205] CONFIRMADO->CERRADA migradas=% omitidas(cant_aplicada<>cant, NO tocadas)=%', coalesce(v_n,0), v_omitidas;
end;
$mig$;
