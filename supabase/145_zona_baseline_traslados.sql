-- 145_zona_baseline_traslados.sql — BASELINE de traslados existentes (esquema me + wrapper mos) — ADITIVO
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- POR QUÉ
--   El módulo Zona deja de mostrar una lista LARGA de "traslados por verificar" en la vista principal y pasa a
--   un botón "🚚 Guías" que abre un layout guía-por-guía agrupado por día. Para EMPEZAR LIMPIO, todas las guías
--   ENTRADA_* que hoy NO tienen verificación se marcan como BASELINE (estado VERIFICADO de arranque) de modo que
--   mos.zona_traslados_pendientes ya NO las liste. De ahora en adelante solo las guías NUEVAS entran a verificar.
--
-- QUÉ HACE
--   me.zona_baseline_traslados(p {zona?, usuario?}) — inserta en me.zona_traslado_verificacion UNA fila por cada
--   guía ENTRADA_* SIN verificación, con:
--     · estado        = 'BASELINE'  (no descuadra COMPLETO/INCOMPLETO; el front lo trata como verificado de origen)
--     · total_enviado = Σ cantidades de la guía,  total_escaneado = total_enviado,  total_dif = 0
--     · lineas_ok     = # de líneas,  lineas_dif = 0
--     · detalle       = NULL  (baseline no escanea nada; no hay discrepancias que mostrar)
--     · stock_aplicado= false (no toca me.stock_zonas — coherente con el gate INERTE de 141)
--     · usuario       = 'BASELINE'  (o el usuario que envíe el caller)
--   Idempotente: ON CONFLICT (id_guia) DO NOTHING. Reejecutar no duplica ni revierte verificaciones reales.
--   Sin filtro de fecha: marca TODO el histórico ENTRADA_* para que nada viejo reaparezca al ampliar la ventana.
--   Si se pasa {zona} acota a esa zona; sin zona → todas. Devuelve {ok, marcadas, total_pendientes_antes}.
--
-- SEGURIDAD
--   · Solo INSERT en me.zona_traslado_verificacion (tabla de verificación, no saldo). NO toca me.stock_zonas,
--     ni el kardex, ni dinero, ni WH, ni flags/sync. Gate mos._claim_ok() en el wrapper mos.*.
--   · ON CONFLICT DO NOTHING = no pisa una verificación real previa (COMPLETO/INCOMPLETO).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create schema if not exists mos;

create or replace function me.zona_baseline_traslados(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona  text := nullif(upper(btrim(coalesce(p->>'zona',''))),'');
  v_user  text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'BASELINE');
  v_antes int := 0;
  v_marc  int := 0;
begin
  -- conteo de pendientes ANTES (todo el histórico ENTRADA_*, opcionalmente acotado a la zona).
  select count(*) into v_antes
  from me.guias_cabecera g
  where g.tipo like 'ENTRADA%'
    and (v_zona is null or upper(btrim(coalesce(g.zona_id,''))) = v_zona)
    and not exists (select 1 from me.zona_traslado_verificacion v where v.id_guia = g.id_guia);

  -- marca BASELINE: 1 fila por guía sin verificación, con totales = enviado (dif 0).
  with cand as (
    select g.id_guia,
           upper(btrim(coalesce(g.zona_id,''))) as zona_id,
           g.tipo                                as tipo_guia,
           g.fecha                               as fecha_guia,
           coalesce(sum(d.cantidad), 0)          as tot_env,
           count(d.*)                            as n_lineas
      from me.guias_cabecera g
      left join me.guias_detalle d on d.id_guia = g.id_guia
     where g.tipo like 'ENTRADA%'
       and (v_zona is null or upper(btrim(coalesce(g.zona_id,''))) = v_zona)
       and not exists (select 1 from me.zona_traslado_verificacion v where v.id_guia = g.id_guia)
     group by g.id_guia, g.zona_id, g.tipo, g.fecha
  ),
  ins as (
    insert into me.zona_traslado_verificacion
      (id_guia, zona_id, tipo_guia, estado, total_enviado, total_escaneado, total_dif,
       lineas_ok, lineas_dif, detalle, stock_aplicado, usuario, verificado_ts, fecha_guia)
    select c.id_guia, c.zona_id, c.tipo_guia, 'BASELINE', c.tot_env, c.tot_env, 0,
           c.n_lineas, 0, null, false, v_user, now(), c.fecha_guia
      from cand c
    on conflict (id_guia) do nothing
    returning 1
  )
  select count(*) into v_marc from ins;

  return jsonb_build_object('ok', true, 'marcadas', v_marc, 'total_pendientes_antes', v_antes,
                            'zona', coalesce(v_zona, 'TODAS'));
end;
$fn$;
revoke all on function me.zona_baseline_traslados(jsonb) from public;
grant execute on function me.zona_baseline_traslados(jsonb) to service_role, authenticated;

-- Wrapper mos.* (profile 'mos' del front) — pass-through con gate, patrón 132/140/141.
create or replace function mos.zona_baseline_traslados(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_baseline_traslados(p);
end; $fn$;
revoke all on function mos.zona_baseline_traslados(jsonb) from public;
grant execute on function mos.zona_baseline_traslados(jsonb) to service_role, authenticated;
