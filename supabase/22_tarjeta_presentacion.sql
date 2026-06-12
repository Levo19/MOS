-- 22_tarjeta_presentacion.sql — Config de la TARJETA DE PRESENTACIÓN (impresa en térmica por los operadores).
-- Los números de WhatsApp + la marca viven en mos.config → editables sin tocar código:
--   update mos.config set valor='51987654321' where clave='TARJETA_WA_COMERCIAL';
--   update mos.config set valor='51912345678' where clave='TARJETA_WA_COMPRAS';
-- El frontend lee me.get_tarjeta_config() (anon, sin token) al abrir el módulo. NO sensible (números públicos
-- que de todos modos van impresos en la tarjeta).

-- Semilla idempotente. ⚠️ PLACEHOLDERS: reemplazar por los números reales (formato internacional sin '+', ej 51XXXXXXXXX).
insert into mos.config (clave, valor, descripcion) values
  ('TARJETA_WA_COMERCIAL','51000000000','Tarjeta: WhatsApp del canal COMERCIAL (clientes). Formato 51XXXXXXXXX'),
  ('TARJETA_WA_COMPRAS','51000000000','Tarjeta: WhatsApp del canal COMPRAS (proveedores). Formato 51XXXXXXXXX'),
  ('TARJETA_MARCA','INVERSION MOS','Tarjeta: nombre de marca que se muestra en la cabecera')
on conflict (clave) do nothing;

create or replace function me.get_tarjeta_config()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb)
  from mos.config where clave like 'TARJETA\_%';
$fn$;

revoke all on function me.get_tarjeta_config() from public;
grant execute on function me.get_tarjeta_config() to anon, authenticated;
