-- [1053] ROLLBACK: deja las 7 tablas EXACTAMENTE como estaban vivas el 20-nov-2026 antes de 1053
-- (RLS apagado, sin políticas, y las mismas ACL: mismos privilegios para anon/authenticated).
-- Solo usar si alguna app deja de funcionar tras 1053 (no se espera: nadie las usa directo).
-- Guarda: aborta si el estado no es el que deja 1053 (para no pisar un cambio posterior).
-- Franja: 01:00-05:00 Lima si es posible; lock_timeout 3s: si aborta por timeout, reintentar.
-- Aplicar:  node C:/Users/ISO/.sb/apply.cjs "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/1053_rollback.sql"

do $pre$
declare
  v_mal text;
begin
  select string_agg(c.oid::regclass::text, ', ') into v_mal
    from pg_class c
   where c.oid in ('mos.accesos_dispositivos'::regclass, 'mos.extension_requests'::regclass,
                   'mos.purgas_historicas'::regclass, 'mos.sunat_voucher'::regclass,
                   'mos.sunat_cronograma'::regclass, 'me.zona_por_activar_descartado'::regclass,
                   'mos.personal_alias_me'::regclass)
     and (not c.relrowsecurity
          or exists (select 1 from pg_policy p where p.polrelid = c.oid)
          or (select array_agg(a::text order by a::text) from unnest(c.relacl) a)::text
             is distinct from '{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}');
  if v_mal is not null then
    raise exception '1053 ROLLBACK ABORTA: estado distinto al que deja 1053 en: %', v_mal;
  end if;
end
$pre$;

-- candado: si una tabla está tomada, abortar a los 3 s (reintentar) en vez de encolar a las RPC detrás
set local lock_timeout = '3s';

alter table mos.accesos_dispositivos       disable row level security;
alter table mos.extension_requests         disable row level security;
alter table mos.purgas_historicas          disable row level security;
alter table mos.sunat_voucher              disable row level security;
alter table mos.sunat_cronograma           disable row level security;
alter table me.zona_por_activar_descartado disable row level security;
alter table mos.personal_alias_me          disable row level security;

grant select, insert, update on mos.accesos_dispositivos       to authenticated;
grant select, insert, update on mos.extension_requests         to authenticated;
grant select, insert         on mos.purgas_historicas          to authenticated;
grant select, insert, delete on mos.sunat_voucher              to authenticated, anon;
grant select                 on mos.sunat_cronograma           to authenticated, anon;
grant select, insert, delete on me.zona_por_activar_descartado to authenticated;
grant select                 on mos.personal_alias_me          to authenticated;

do $post$
declare
  r record;
  v_acl text;
begin
  for r in
    select * from (values
      ('mos.accesos_dispositivos',        '{authenticated=arw/postgres,postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}'),
      ('mos.extension_requests',          '{authenticated=arw/postgres,postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}'),
      ('mos.purgas_historicas',           '{authenticated=ar/postgres,postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}'),
      ('mos.sunat_voucher',               '{anon=ard/postgres,authenticated=ard/postgres,postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}'),
      ('mos.sunat_cronograma',            '{anon=r/postgres,authenticated=r/postgres,postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}'),
      ('me.zona_por_activar_descartado',  '{authenticated=ard/postgres,postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}'),
      ('mos.personal_alias_me',           '{authenticated=r/postgres,postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}')
    ) t(tabla, acl_esperada)
  loop
    select (select array_agg(a::text order by a::text) from unnest(c.relacl) a)::text into v_acl
      from pg_class c where c.oid = to_regclass(r.tabla) and not c.relrowsecurity;
    if v_acl is distinct from r.acl_esperada then
      raise exception '1053 ROLLBACK post-condición falló en %: % (esperada %)', r.tabla, v_acl, r.acl_esperada;
    end if;
  end loop;
end
$post$;

select '1053 ROLLBACK OK: 7 tablas como el 20-nov (sin RLS, ACL original)' as resultado;
