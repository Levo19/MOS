-- [1053] ENSAYO LOCAL (Postgres de ensayos C:/Users/ISO/.levo-pg, puerto 54329). Nunca toca lo vivo.
-- Todo en UNA transacción que termina en ROLLBACK: réplica mínima de las 7 tablas con la ACL viva del
-- 20-nov, dueño postgres (en local y en vivo: no superusuario, rolbypassrls = true, como en Supabase).
-- Casos:
--   A antes: authenticated lee mos.accesos_dispositivos y anon BORRA mos.sunat_voucher directo (el hueco)
--   B aplica 1053 y comprueba: anon/authenticated reciben permission denied en las 7 tablas;
--     una RPC SECURITY DEFINER (dueño postgres) llamada por anon y por authenticated sigue leyendo y
--     escribiendo, incluido un helper INVOKER anidado (como mos._nota_puede / _venta_cobrada_persona_dia);
--     service_role sigue leyendo y escribiendo directo.
--   C 1053 por segunda vez aborta (guarda) sin cambiar nada
--   D aplica 1053_rollback y la ACL/RLS vuelven a ser idénticas a la foto previa; A vuelve a ser cierto
-- Correr:  node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/1053_ensayo_local.cjs"
\set ON_ERROR_STOP 1
begin;
set local client_min_messages = warning;
create schema if not exists mos;
create schema if not exists me;
grant usage on schema mos, me to anon, authenticated, service_role;

create table mos.accesos_dispositivos (id text primary key, dato text);
create table mos.extension_requests (id text primary key, dato text);
create table mos.purgas_historicas (id text primary key, dato text);
create table mos.sunat_voucher (id text primary key, igv numeric);
create table mos.sunat_cronograma (id text primary key, dato text);
create table me.zona_por_activar_descartado (id text primary key, dato text);
create table mos.personal_alias_me (id text primary key, dato text);

revoke all on mos.accesos_dispositivos, mos.extension_requests, mos.purgas_historicas, mos.sunat_voucher,
  mos.sunat_cronograma, me.zona_por_activar_descartado, mos.personal_alias_me from public, anon, authenticated, service_role;
grant all on mos.accesos_dispositivos, mos.extension_requests, mos.purgas_historicas, mos.sunat_voucher,
  mos.sunat_cronograma, me.zona_por_activar_descartado, mos.personal_alias_me to service_role;
grant select, insert, update on mos.accesos_dispositivos       to authenticated;
grant select, insert, update on mos.extension_requests         to authenticated;
grant select, insert         on mos.purgas_historicas          to authenticated;
grant select, insert, delete on mos.sunat_voucher              to authenticated, anon;
grant select                 on mos.sunat_cronograma           to authenticated, anon;
grant select, insert, delete on me.zona_por_activar_descartado to authenticated;
grant select                 on mos.personal_alias_me          to authenticated;

insert into mos.accesos_dispositivos values ('d1','x'),('d2','y');
insert into mos.extension_requests values ('e1','x');
insert into mos.purgas_historicas values ('p1','x');
insert into mos.sunat_voucher values ('v1', 10.50),('v2', 3.20);
insert into mos.sunat_cronograma values ('c1','x');
insert into me.zona_por_activar_descartado values ('z1','x');
insert into mos.personal_alias_me values ('a1','x');

-- helper INVOKER (como mos._nota_puede) y RPC DEFINER (como mos.nota_sesion_get / sunat_voucher_*)
create function mos.zz1053_inv_cuenta() returns int language sql stable
  as $f$ select count(*)::int from mos.accesos_dispositivos $f$;
grant execute on function mos.zz1053_inv_cuenta() to authenticated;
create function mos.zz1053_rpc(p jsonb) returns jsonb language plpgsql security definer set search_path = ''
as $f$
begin
  insert into mos.sunat_voucher values (p->>'id', 1.00);
  insert into mos.extension_requests values (p->>'id', 'rpc');
  update mos.accesos_dispositivos set dato = 'rpc' where id = 'd1';
  delete from me.zona_por_activar_descartado where id = 'nada';
  return jsonb_build_object(
    'acc_inv', mos.zz1053_inv_cuenta(),
    'vouchers', (select count(*) from mos.sunat_voucher),
    'igv', (select sum(igv) from mos.sunat_voucher),
    'ext', (select count(*) from mos.extension_requests),
    'purg', (select count(*) from mos.purgas_historicas),
    'cron', (select count(*) from mos.sunat_cronograma),
    'zona', (select count(*) from me.zona_por_activar_descartado),
    'alias', (select count(*) from mos.personal_alias_me));
end
$f$;
revoke all on function mos.zz1053_rpc(jsonb) from public;
grant execute on function mos.zz1053_rpc(jsonb) to anon, authenticated, service_role;

create temp table zz1053_foto as
  select c.oid::regclass::text as tabla, c.relrowsecurity as rls,
         (select array_agg(a::text order by a::text) from unnest(c.relacl) a)::text as acl
    from pg_class c
   where c.oid in ('mos.accesos_dispositivos'::regclass, 'mos.extension_requests'::regclass,
                   'mos.purgas_historicas'::regclass, 'mos.sunat_voucher'::regclass,
                   'mos.sunat_cronograma'::regclass, 'me.zona_por_activar_descartado'::regclass,
                   'mos.personal_alias_me'::regclass);
grant select on zz1053_foto to anon, authenticated;

-- ===== A: el hueco de hoy =====
savepoint a;
set local role anon;
delete from mos.sunat_voucher where id = 'v2';
reset role;
do $a$ begin
  assert (select count(*) from mos.sunat_voucher) = 1, 'A: anon debía poder borrar directo (estado previo)';
end $a$;
rollback to savepoint a;
set local role authenticated;
do $a2$ begin
  assert (select count(*) from mos.accesos_dispositivos) = 2, 'A: authenticated leía directo';
end $a2$;
reset role;
select 'A OK: antes, anon borra sunat_voucher y authenticated lee accesos_dispositivos directo' as caso;

-- ===== B: aplicar 1053 =====
\ir 1053_rls_tablas_advisor.sql

do $b$
declare
  t text;
  rol text;
begin
  foreach rol in array array['anon','authenticated'] loop
    foreach t in array array['mos.accesos_dispositivos','mos.extension_requests','mos.purgas_historicas',
                             'mos.sunat_voucher','mos.sunat_cronograma','me.zona_por_activar_descartado',
                             'mos.personal_alias_me'] loop
      execute format('set local role %I', rol);
      begin
        execute format('select count(*) from %s', t);
        raise exception 'B: % todavía LEE % directo', rol, t;
      exception when insufficient_privilege then null;
      end;
      begin
        execute format('delete from %s where true', t);
        raise exception 'B: % todavía BORRA % directo', rol, t;
      exception when insufficient_privilege then null;
      end;
      reset role;
    end loop;
  end loop;
end
$b$;

set local role anon;
do $b2$ declare r jsonb; begin
  r := mos.zz1053_rpc('{"id":"anon1"}');
  assert (r->>'acc_inv')::int = 2 and (r->>'vouchers')::int = 3 and (r->>'igv')::numeric = 14.70
     and (r->>'ext')::int = 2 and (r->>'purg')::int = 1 and (r->>'cron')::int = 1
     and (r->>'zona')::int = 1 and (r->>'alias')::int = 1, 'B: RPC DEFINER como anon: ' || r::text;
end $b2$;
reset role;
set local role authenticated;
do $b3$ declare r jsonb; begin
  r := mos.zz1053_rpc('{"id":"auth1"}');
  assert (r->>'vouchers')::int = 4 and (r->>'acc_inv')::int = 2, 'B: RPC DEFINER como authenticated: ' || r::text;
end $b3$;
reset role;
set local role service_role;
do $b4$ begin
  insert into mos.purgas_historicas values ('p2','sr');
  assert (select count(*) from mos.purgas_historicas) = 2, 'B: service_role directo';
  assert (select count(*) from mos.accesos_dispositivos where dato = 'rpc') = 1, 'B: update de la RPC';
end $b4$;
reset role;
select 'B OK: anon/authenticated sin acceso directo; RPC DEFINER (+INVOKER anidado) y service_role intactos' as caso;

-- ===== C: re-aplicar aborta por la guarda =====
savepoint c;
\set ON_ERROR_STOP 0
\ir 1053_rls_tablas_advisor.sql
\set ON_ERROR_STOP 1
rollback to savepoint c;
do $c2$ begin
  assert (select bool_and(c.relrowsecurity) from pg_class c
           where c.oid in ('mos.sunat_voucher'::regclass,'mos.accesos_dispositivos'::regclass)), 'C: estado cambió';
end $c2$;
select 'C OK: 1053 por segunda vez aborta en la guarda (ver ERROR esperado arriba) y no cambia nada' as caso;

-- ===== D: reversa exacta =====
\ir 1053_rollback.sql
do $d$ declare v int; begin
  select count(*) into v
    from zz1053_foto f
    join pg_class c on c.oid = f.tabla::regclass
   where c.relrowsecurity = f.rls
     and (select array_agg(a::text order by a::text) from unnest(c.relacl) a)::text = f.acl;
  assert v = 7, 'D: reversa no idéntica a la foto (' || v || '/7)';
end $d$;
set local role anon;
do $d2$ begin
  assert (select count(*) from mos.sunat_voucher) >= 1, 'D: anon vuelve a leer como antes';
end $d2$;
reset role;
select 'D OK: rollback deja RLS y ACL idénticas a la foto previa' as caso;

rollback;
select 'ENSAYO 1053 COMPLETO (todo revertido)' as fin;
