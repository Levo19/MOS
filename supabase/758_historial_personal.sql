-- 758 · getHistorialPersonal cero-GAS (12-ago-2026) — el ÚLTIMO dato que vivía solo en la Hoja.
-- El log de auditoría por persona vivía en una columna-JSON del Sheet PERSONAL_MASTER
-- (gas/Auditoria.gs getHistorialPersonal). Backfill congelado vía el endpoint GAS (una sola
-- vez, 2026-08-12): 10 personas, 2 eventos en total — la función apenas acumuló historia.
-- Nota: la escritura de auditoría NUEVA corre por el camino directo (las ediciones de
-- personal ya no pasan por GAS); si la RPC de edición no appendeara a esta columna, es
-- follow-up aparte (hoy: lectura fiel de lo que existía).

alter table mos.personal add column if not exists historial_cambios jsonb not null default '[]'::jsonb;

-- Backfill congelado (export GAS 2026-08-12; el resto de personas: [] = sin historia)
update mos.personal set historial_cambios = '[{"usuario":"Luis","rol":"MASTER","source":"MOS_PERSONAL","accion":"editar","cambios":[{"campo":"estado","antes":0,"despues":"1"}],"motivo":"","ts":"2026-05-09T14:00:00.902Z"}]'::jsonb
 where id_personal = 'OP002' and historial_cambios = '[]'::jsonb;
update mos.personal set historial_cambios = '[{"usuario":"Luis","rol":"MASTER","source":"MOS_PERSONAL","accion":"crear","ref":{"nombre":"Andersor","apellido":"","tipo":"OPERADOR","appOrigen":"warehouseMos","rol":"ENVASADOR","montoBase":0,"tarifaHora":0,"tienePin":true},"ts":"2026-05-29T20:17:32.324Z"}]'::jsonb
 where id_personal = 'PER1780085850810' and historial_cambios = '[]'::jsonb;

-- Reader: mismo shape que el endpoint GAS ({ok, data:[...]})
create or replace function mos.historial_personal(p jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_id text := nullif(btrim(coalesce(p->>'idPersonal', p->>'id_personal', '')), '');
  v_h  jsonb;
begin
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'Requiere idPersonal'); end if;
  select coalesce(historial_cambios, '[]'::jsonb) into v_h from mos.personal where id_personal = v_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'Personal no encontrado'); end if;
  return jsonb_build_object('ok', true, 'data', v_h);
end;
$function$;

revoke all on function mos.historial_personal(jsonb) from public;
grant execute on function mos.historial_personal(jsonb) to authenticated, service_role;
