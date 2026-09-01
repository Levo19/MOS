-- ============================================================================
-- 1008_tickets_fantasma_visibilidad_master.sql
-- ----------------------------------------------------------------------------
-- Pedido del dueño (incidente 01-sep): los "tickets fantasma" de ME (venta cobrada que el
-- backend rebotó) y los RESCATES (SQL 1007) deben verse desde MOS como MASTER:
--   1) push inmediato a MASTER cuando ME archiva un fantasma o rescata un ticket;
--   2) listado central para el flotante de MOS (solo cuando hay algo), con "revisado".
-- Tabla mos.tickets_fantasma + 3 RPCs. Idempotente (on conflict local_id+device).
-- ============================================================================

create table if not exists mos.tickets_fantasma (
  id          bigint generated always as identity primary key,
  local_id    text not null,
  device_id   text not null default '',
  vendedor    text not null default '',
  zona        text not null default '',
  total       numeric(12,2) not null default 0,
  metodo      text not null default '',
  motivo      text not null default '',
  mensaje     text not null default '',
  impreso     boolean not null default false,
  estado      text not null default 'PENDIENTE',   -- PENDIENTE | RESCATADO | REVISADO
  correlativo text not null default '',            -- si fue rescatado (SQL 1007)
  caja_original text not null default '',
  revisado_por text,
  revisado_ts  timestamptz,
  created_at  timestamptz not null default now(),
  unique (local_id, device_id)
);
alter table mos.tickets_fantasma enable row level security;
alter table mos.tickets_fantasma force row level security;

-- 1) Reporte desde ME (fire-and-forget del cliente). Idempotente. Push a MASTER.
create or replace function me.fantasma_reportar(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_local text := nullif(btrim(coalesce(p->>'localId','')),'');
  v_dev   text := btrim(coalesce(p->>'deviceId',''));
  v_est   text := upper(btrim(coalesce(p->>'estado','PENDIENTE')));
  v_ins   int;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_local is null then return jsonb_build_object('ok', false, 'error', 'localId requerido'); end if;
  if v_est not in ('PENDIENTE','RESCATADO') then v_est := 'PENDIENTE'; end if;

  insert into mos.tickets_fantasma (local_id, device_id, vendedor, zona, total, metodo, motivo, mensaje,
                                    impreso, estado, correlativo, caja_original)
  values (v_local, v_dev,
          left(btrim(coalesce(p->>'vendedor','')), 80), left(btrim(coalesce(p->>'zona','')), 40),
          coalesce(nullif(btrim(coalesce(p->>'total','')),'')::numeric, 0),
          left(btrim(coalesce(p->>'metodo','')), 40), left(btrim(coalesce(p->>'motivo','')), 60),
          left(btrim(coalesce(p->>'mensaje','')), 300), coalesce((p->>'impreso')::boolean, false),
          v_est, left(btrim(coalesce(p->>'correlativo','')), 30), left(btrim(coalesce(p->>'cajaOriginal','')), 40))
  on conflict (local_id, device_id) do nothing;
  get diagnostics v_ins = row_count;

  -- push SOLO en el primer reporte (idempotencia: reintentos no re-notifican)
  if v_ins > 0 then
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
        'titulo', case when v_est = 'RESCATADO' then '🛟 Ticket rescatado' else '⛔ Venta fantasma' end,
        'cuerpo', 'S/ ' || to_char(coalesce(nullif(btrim(coalesce(p->>'total','')),'')::numeric,0),'FM999990.00')
                  || ' · ' || coalesce(nullif(btrim(coalesce(p->>'vendedor','')),''),'?')
                  || ' · ' || coalesce(nullif(btrim(coalesce(p->>'zona','')),''),'?')
                  || case when v_est = 'RESCATADO'
                          then ' → POR_COBRAR (' || coalesce(nullif(btrim(coalesce(p->>'correlativo','')),''),'s/n') || ')'
                          else ' · ' || coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'rechazo') end,
        'data', jsonb_build_object('tipo','ticket_fantasma','estado',v_est)));
    exception when others then null;   -- el push jamás rompe el reporte
    end;
  end if;
  return jsonb_build_object('ok', true, 'nuevo', v_ins > 0);
end; $fn$;
revoke all on function me.fantasma_reportar(jsonb) from public, anon;
grant execute on function me.fantasma_reportar(jsonb) to authenticated, service_role;

-- 2) Listado para el flotante de MOS (no revisados). Gate app MOS.
create or replace function mos.fantasmas_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return jsonb_build_object('ok', true, 'data', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'localId', t.local_id, 'vendedor', t.vendedor, 'zona', t.zona,
      'total', t.total, 'metodo', t.metodo, 'motivo', t.motivo, 'mensaje', t.mensaje,
      'impreso', t.impreso, 'estado', t.estado, 'correlativo', t.correlativo,
      'cajaOriginal', t.caja_original,
      'hora', to_char(t.created_at at time zone 'America/Lima', 'DD/MM HH24:MI:SS'))
      order by t.created_at desc)
    from (select * from mos.tickets_fantasma where estado <> 'REVISADO' order by created_at desc limit 60) t), '[]'::jsonb));
end; $fn$;
revoke all on function mos.fantasmas_listar(jsonb) from public, anon;
grant execute on function mos.fantasmas_listar(jsonb) to authenticated, service_role;

-- 3) Marcar revisado (master en MOS).
create or replace function mos.fantasma_resolver(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id bigint := nullif(btrim(coalesce(p->>'id','')),'')::bigint;
  v_user text := left(btrim(coalesce(p->>'usuario','')), 80);
  v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'id requerido'); end if;
  update mos.tickets_fantasma set estado = 'REVISADO', revisado_por = v_user, revisado_ts = now()
   where id = v_id and estado <> 'REVISADO';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'actualizado', v_n > 0);
end; $fn$;
revoke all on function mos.fantasma_resolver(jsonb) from public, anon;
grant execute on function mos.fantasma_resolver(jsonb) to authenticated, service_role;
