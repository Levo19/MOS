-- 15_fase2_dispositivo_zonas.sql — Binding autoritativo dispositivo->zona (admin-only) para RLS de Fase 2.
-- La RLS deriva la zona del JWT; el mint-token (GAS) llena el claim 'zonas' leyendo ESTA tabla.
-- NUNCA se escribe desde el cliente (resuelve el bloqueante #1 del plan: ultima_zona es falsificable).
create table if not exists mos.dispositivo_zonas (
  id_dispositivo text   not null,
  id_zona        text   not null,
  app            text,
  activo         boolean not null default true,
  asignado_por   text,
  asignado_at    timestamptz not null default now(),
  primary key (id_dispositivo, id_zona)
);
comment on table mos.dispositivo_zonas is 'Binding autoritativo dispositivo->zona (admin-only) para RLS Fase 2. NO escribir desde cliente.';

insert into mos.dispositivo_zonas (id_dispositivo, id_zona, app, asignado_por)
select d.id_dispositivo, d.ultima_zona, d.app, 'SEED_INICIAL'
from mos.dispositivos d
where d.app='mosExpress' and upper(coalesce(d.estado,''))='ACTIVO'
  and d.ultima_zona is not null and d.ultima_zona <> ''
  and d.ultima_zona in (select id_zona from mos.zonas)
on conflict (id_dispositivo, id_zona) do nothing;
