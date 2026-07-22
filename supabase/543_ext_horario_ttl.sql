-- ════════════════════════════════════════════════════════════════════════════
-- 543 · Solicitudes de extensión de horario: TTL 2 horas
-- ════════════════════════════════════════════════════════════════════════════
-- Caso real (2026-07-22): el buzón del dueño mostraba una solicitud "+1 HORA"
-- del sábado 19-jul 22:15 (cajero xf, motivo "fff") — 2 días PENDIENTE. Una
-- extensión de +1h pierde sentido con la noche: si el admin no la atendió en
-- 2 horas, se vence sola (VENCIDA, no rechazada — sin culpa para el cajero).
create or replace function mos.vencer_extensiones_horario()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
  update mos.seguridad_alertas
     set estado = 'VENCIDA'
   where tipo = 'EXTENSION_HORARIO_PENDIENTE'
     and estado = 'PENDIENTE'
     and fecha < now() - interval '2 hours';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'vencidas', v_n);
end;
$fn$;
revoke all on function mos.vencer_extensiones_horario() from public;
select cron.schedule('mos-ext-horario-vencer', '35 * * * *', $$ select mos.vencer_extensiones_horario(); $$);
select mos.vencer_extensiones_horario();  -- one-shot: vence la de xf del sábado YA
