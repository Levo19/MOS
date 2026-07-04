-- 353: [CERO-GAS #6/#7] Push apertura/cierre de caja ME → triggers en me.cajas (reemplazan _notificarMOS del
-- GAS procesarAperturaCaja/procesarCierreCaja). me.cajas es autoritativa (escrita por me.abrir_caja / cerrar_caja
-- directos) → el trigger cubre TODOS los paths sin doble (la GAS ya no pushea tras el cutover de este SQL + clasp).
-- Audiencia = admins (el cajero no es admin → excluir_origen natural). Best-effort: el push nunca rompe la caja.

create or replace function me._tg_caja_push()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  begin
    if tg_op = 'INSERT' and NEW.estado = 'ABIERTA' then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
        'titulo', '🛒 ' || coalesce(NEW.vendedor,'Cajero') || ' aperturó caja',
        'cuerpo', coalesce(nullif(NEW.zona_id,''),'') || ' · ' || to_char(now() at time zone 'America/Lima','HH24:MI'),
        'data', jsonb_build_object('tipo','me_caja_apertura','idCaja',NEW.id_caja)));
    elsif tg_op = 'UPDATE' and coalesce(OLD.estado,'') = 'ABIERTA' and NEW.estado like 'CERRADA%' then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
        'titulo', '🔐 ' || coalesce(NEW.vendedor,'Cajero') || ' cerró caja',
        'cuerpo', coalesce(nullif(NEW.zona_id,''),'') ||
                  case when NEW.monto_final is not null then ' · S/ ' || round(NEW.monto_final)::text else '' end,
        'data', jsonb_build_object('tipo','me_caja_cierre','idCaja',NEW.id_caja)));
    end if;
  exception when others then null; end;
  return null;  -- AFTER trigger
end; $fn$;

drop trigger if exists tg_me_caja_push_ins on me.cajas;
drop trigger if exists tg_me_caja_push_upd on me.cajas;
create trigger tg_me_caja_push_ins after insert on me.cajas for each row execute function me._tg_caja_push();
create trigger tg_me_caja_push_upd after update of estado on me.cajas for each row execute function me._tg_caja_push();
