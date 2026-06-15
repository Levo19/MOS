-- 49_mos_autorizacion_f0.sql — [Autorización · F0] Soporte INERTE: jerarquía de roles + auditoría única.
-- No toca nada vivo (la validación sigue en GAS). Solo crea funciones/tabla que F1 (RPC verificar_clave_admin) usará.
-- pgcrypto ya está instalada (para F3 hash de PIN). Roles reales en mos.personal: MASTER, ADMIN, ALMACENERO, CAJERO, ENVASADOR.

-- Jerarquía explícita y FAIL-SAFE: rol desconocido/null → 1 (operador, SIN poderes admin). Acumulativa.
create or replace function mos.rol_nivel(p_rol text)
returns int language sql immutable set search_path = '' as $$
  select case upper(btrim(coalesce(p_rol, '')))
    when 'MASTER' then 3
    when 'ADMIN' then 2
    when 'ADMINISTRADOR' then 2
    else 1   -- OPERADOR/VENDEDOR/ALMACENERO/CAJERO/ENVASADOR/desconocido = base
  end;
$$;

-- Auditoría ÚNICA de autorizaciones (reemplaza las 3 hojas dispersas). Append-only (solo inserta la RPC).
create table if not exists mos.auditoria_admin (
  id_accion            text primary key,
  fecha                timestamptz not null default now(),
  accion               text,
  ref_documento        text,
  id_personal_autoriza text,
  nombre_autoriza      text,
  rol_autoriza         text,
  nivel_autoriza       int,
  app_origen           text,
  dispositivo          text,
  tier                 int,
  device_id            text,
  cliente_meta         jsonb,
  detalle              text
);
create index if not exists ix_audadmin_fecha on mos.auditoria_admin (fecha desc);
create index if not exists ix_audadmin_persona on mos.auditoria_admin (id_personal_autoriza);

revoke all on function mos.rol_nivel(text) from public;
grant execute on function mos.rol_nivel(text) to service_role, authenticated;
grant select, insert on mos.auditoria_admin to service_role, authenticated;
