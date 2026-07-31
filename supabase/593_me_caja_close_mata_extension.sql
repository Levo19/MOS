-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 593_me_caja_close_mata_extension.sql — AMO cierra caja → ESCLAVO (extensión) fallece automáticamente
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- Modelo amo-esclavo (dueño): la extensión (2º equipo) NO vive sin su amo. Cuando el equipo PRINCIPAL
-- (es_principal=true) cierra su caja, TODAS las extensiones de esa sesión deben morir (cerrar sesión).
--
-- HOY el hueco: cerrar la caja del amo NO tocaba `mos.accesos_dispositivos` del esclavo → el watcher
-- del ME (`mos.extension_debe_cerrar`, que desloguea al esclavo si su acceso es CERRADA o la sesión no
-- está ACTIVA) nunca disparaba → el esclavo seguía vivo (peor: con su propia caja y botón "cerrar").
--
-- FIX (backend, contenido y seguro): TRIGGER AFTER UPDATE en me.cajas. Cuando una caja pasa A CERRADA
-- y el device que la cerró es PRINCIPAL de una sesión ACTIVA → marca los accesos NO-principales (esclavos)
-- de esa sesión como CERRADA. El watcher del ME ve el acceso CERRADA y desloguea al esclavo (fallece).
-- NO toca la caja del esclavo (money) ni `liquidaciones_dia`/liquidación (jornal); solo mata el ACCESO.
-- Best-effort (un fallo acá nunca rompe el cierre de caja). Reversible por flag (default ON).
-- ════════════════════════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor) values ('MOS_EXT_SLAVE_MUERE_CON_AMO', '1')
  on conflict (clave) do nothing;

create or replace function me._trg_caja_close_mata_extension() returns trigger
language plpgsql security definer set search_path = '' as $trg$
declare v_dia text;
begin
  -- solo cuando la caja RECIÉN pasa a cerrada
  if upper(coalesce(NEW.estado,'')) not in ('CERRADA','AUTOCERRADA') then return NEW; end if;
  if upper(coalesce(OLD.estado,'')) in ('CERRADA','AUTOCERRADA') then return NEW; end if;
  if coalesce((select valor from mos.config where clave='MOS_EXT_SLAVE_MUERE_CON_AMO' limit 1),'1') <> '1' then
    return NEW;
  end if;
  -- ¿el device que cerró es el PRINCIPAL (amo) de alguna sesión ACTIVA?
  for v_dia in
    select id_dia from mos.accesos_dispositivos
     where device_id = NEW.dispositivo_id and es_principal = true and upper(coalesce(estado,'')) = 'ACTIVA'
  loop
    -- matar los accesos ESCLAVOS (no principales) de esa sesión → el watcher los desloguea
    update mos.accesos_dispositivos
       set estado = 'CERRADA', ultima_conexion = now()
     where id_dia = v_dia and es_principal = false and upper(coalesce(estado,'')) = 'ACTIVA';
  end loop;
  return NEW;
exception when others then
  return NEW;  -- jamás romper el cierre de caja por esto
end;
$trg$;

drop trigger if exists trg_caja_close_mata_extension on me.cajas;
create trigger trg_caja_close_mata_extension
  after update on me.cajas
  for each row execute function me._trg_caja_close_mata_extension();
