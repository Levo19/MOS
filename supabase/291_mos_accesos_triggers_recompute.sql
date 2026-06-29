-- ============================================================================
-- 291_mos_accesos_triggers_recompute.sql — FASE 2: pago EN VIVO (triggers)
-- ----------------------------------------------------------------------------
-- Dispara mos.recomputar_dia / recomputar_zona_dia cuando cambia la actividad:
--   · wh.envasados  (INSERT/UPDATE/DELETE) → recalcula el pago del envasador/almacenero
--     de ese día (envasa → su pago_envasado/total sube al instante).
--   · me.ventas     (INSERT/UPDATE/DELETE) → recalcula la comisión de TODA la zona ese día.
-- Como wh.envasados se escribe directo (WH_REGISTRAR_ENVASADO_DIRECTO=1), el envasador
-- ve subir su pago en vivo. me.ventas se refresca por el flujo de ventas.
--
-- ⚠️ GATED: las RPC de recompute ya checan MOS_ACCESOS_DIRECTO; igual el trigger sale
--    barato si el flag está OFF. A PRUEBA DE FALLOS (BEGIN/EXCEPTION): un error en el
--    recompute NUNCA rompe el registro de un envasado o una venta (dinero/operación).
-- ============================================================================

-- helper: recomputar las filas de envasado (WH) que matchean un usuario+día (por nombre).
create or replace function mos._recompute_envasado_usuario(p_usuario text, p_dia date)
returns void language plpgsql security definer set search_path = '' as $fn$
declare rec record; v_fecha_s text := to_char(p_dia,'YYYY-MM-DD');
begin
  for rec in
    select l.id_personal
      from mos.liquidaciones_dia l
     where (l.fecha at time zone 'America/Lima')::date = p_dia
       and upper(coalesce(l.rol,'')) in ('ENVASADOR','ALMACENERO')
       and mos._norm_nom(coalesce((select btrim(nombre||' '||coalesce(apellido,'')) from mos.personal where id_personal = l.id_personal limit 1), l.nombre))
           = mos._norm_nom(p_usuario)
  loop
    perform mos.recomputar_dia(jsonb_build_object('idPersonal',rec.id_personal,'fecha',v_fecha_s));
  end loop;
end;
$fn$;
revoke all on function mos._recompute_envasado_usuario(text,date) from public;
grant execute on function mos._recompute_envasado_usuario(text,date) to service_role;

-- trigger fn envasados
create or replace function mos._tg_recompute_envasado()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare r record := coalesce(NEW, OLD);
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') = '1' then
    begin
      perform mos._recompute_envasado_usuario(r.usuario, (r.fecha at time zone 'America/Lima')::date);
    exception when others then null;  -- nunca romper el registro de envasado
    end;
  end if;
  return null;
end;
$fn$;

-- trigger fn ventas (recalcula la zona del día)
create or replace function mos._tg_recompute_venta()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare r record := coalesce(NEW, OLD);
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') = '1' then
    begin
      perform mos.recomputar_zona_dia(jsonb_build_object(
        'zona', coalesce(r.zona_id,''),
        'fecha', to_char((r.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD')));
    exception when others then null;  -- nunca romper el registro de venta
    end;
  end if;
  return null;
end;
$fn$;

drop trigger if exists tg_recompute_envasado on wh.envasados;
create trigger tg_recompute_envasado
  after insert or update or delete on wh.envasados
  for each row execute function mos._tg_recompute_envasado();

drop trigger if exists tg_recompute_venta on me.ventas;
create trigger tg_recompute_venta
  after insert or update or delete on me.ventas
  for each row execute function mos._tg_recompute_venta();
