-- 1053 · Advisor de Supabase «RLS Disabled in Public» (críticas, Luis 08-nov-2026).
-- Tablas: mos.accesos_dispositivos, mos.extension_requests, mos.purgas_historicas, mos.sunat_voucher
-- (las 4 alertas del 08-nov) + mos.sunat_cronograma, me.zona_por_activar_descartado y
-- mos.personal_alias_me (misma falla: esquema expuesto por PostgREST, sin RLS y con SELECT para
-- anon/authenticated; el Advisor las marca igual).
--
-- Auditoría 20-nov (vivo, solo lectura + grep en ProyectoMOS/warehouseMos/MosExpress/MosGo/mos-radio):
--   * Ningún front, Edge ni Apps Script lee o escribe estas tablas directo (.from/REST).
--   * Todo acceso es por RPC SECURITY DEFINER con dueño postgres (rolbypassrls = true), p. ej.
--     mos.extension_*, mos.registrar_sesion, me.abrir_caja, mos.sunat_voucher_*, mos.eliminar_items_catalogo,
--     me.zona_por_activar*, mos.turnos_del_dia, mos._credito_asignar_core.
--   * Las 2 funciones INVOKER que leen mos.accesos_dispositivos (mos._nota_puede,
--     mos._venta_cobrada_persona_dia) solo se llaman desde DEFINER (nota_sesion_get/set,
--     recomputar_dia), así que corren como postgres y no las afecta RLS.
--   * Ninguna está en la publicación de Realtime ni tiene vistas o triggers que dependan de ellas.
--   * Cron corre como postgres.
-- Arreglo (convención MOS 1045/1051): RLS encendido SIN políticas (deny-all para anon/authenticated)
-- + revoke all a public/anon/authenticated. postgres y service_role siguen igual (bypass RLS).
-- Así se cierra además la puerta real: hoy cualquier sesión anon puede BORRAR mos.sunat_voucher por REST.
--
-- Guarda: aborta si el estado previo no es exactamente el auditado el 20-nov (ACL, RLS, políticas);
-- así la reversa 1053_rollback.sql es exacta. Sin begin/commit: apply.cjs ya envuelve en una transacción.
-- Aplicar:  node C:/Users/ISO/.sb/apply.cjs "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/1053_rls_tablas_advisor.sql"

do $pre$
declare
  r record;
  v_acl text;
  v_rls boolean;
  v_pol int;
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
    if to_regclass(r.tabla) is null then
      raise exception '1053 ABORTA: no existe %', r.tabla;
    end if;
    select c.relrowsecurity,
           (select array_agg(a::text order by a::text) from unnest(c.relacl) a)::text,
           (select count(*) from pg_policy p where p.polrelid = c.oid)
      into v_rls, v_acl, v_pol
      from pg_class c where c.oid = to_regclass(r.tabla);
    if v_rls or v_pol > 0 then
      raise exception '1053 ABORTA: % ya tiene RLS (%) o políticas (%); ¿ya aplicado? revisar antes', r.tabla, v_rls, v_pol;
    end if;
    if v_acl is distinct from r.acl_esperada then
      raise exception '1053 ABORTA: ACL de % cambió desde la auditoría: % (esperada %)', r.tabla, v_acl, r.acl_esperada;
    end if;
  end loop;
end
$pre$;

alter table mos.accesos_dispositivos       enable row level security;
alter table mos.extension_requests         enable row level security;
alter table mos.purgas_historicas          enable row level security;
alter table mos.sunat_voucher              enable row level security;
alter table mos.sunat_cronograma           enable row level security;
alter table me.zona_por_activar_descartado enable row level security;
alter table mos.personal_alias_me          enable row level security;

revoke all on table
  mos.accesos_dispositivos, mos.extension_requests, mos.purgas_historicas, mos.sunat_voucher,
  mos.sunat_cronograma, me.zona_por_activar_descartado, mos.personal_alias_me
  from public, anon, authenticated;

do $post$
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
          or has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE')
          or has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE')
          or not has_table_privilege('service_role', c.oid, 'SELECT,INSERT,UPDATE,DELETE')
          or (select array_agg(a::text order by a::text) from unnest(c.relacl) a)::text
             is distinct from '{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}');
  if v_mal is not null then
    raise exception '1053 post-condición falló en: %', v_mal;
  end if;
end
$post$;

select '1053 OK: RLS deny-all en 7 tablas; anon/authenticated sin acceso directo' as resultado;

-- ===================== RUNBOOK 1053 =====================
-- 0. Ventana: fuera de 17:30-00:30 Lima (no hay cron ni flujo que dependa de estas ACL, pero ALTER TABLE
--    pide un candado exclusivo breve: si una tabla está tomada, apply.cjs espera; no forzar).
-- 1. Ensayo local en verde:   node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/1053_ensayo_local.cjs"
-- 2. Foto ANTES (solo lectura), guardar la salida:
--      node C:/Users/ISO/.sb/q.cjs "<contenido de 1053_verificar.sql>"   -> rls=false, total_alertas_advisor_rls=7
-- 3. Aplicar:  node C:/Users/ISO/.sb/apply.cjs "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/1053_rls_tablas_advisor.sql"
--      esperado: OK ... "1053 OK: RLS deny-all en 7 tablas". Si sale "1053 ABORTA": no se cambió nada; revisar.
-- 4. Foto DESPUÉS: misma consulta -> rls=true, anon_*/auth_* = false, service_ok=true,
--    total_alertas_advisor_rls=0.
-- 5. Humo de apps (5 min): MOS > SUNAT: listar/registrar/borrar voucher y estado de declaración;
--    ME: abrir caja + presencia; pedir/aprobar extensión de dispositivo (QR); nota de sesión;
--    "zona por activar" descartar; asignar crédito a personal; MOS eliminar ítem de catálogo (purga).
--    Ante cualquier "permission denied for table" en logs de PostgREST: aplicar 1053_rollback.sql.
-- 6. Supabase > Advisors > Security > Rerun: desaparecen las 4 alertas «RLS Disabled in Public» del 08-nov
--    (y las 3 hermanas). Pueden quedar avisos INFO «RLS Enabled No Policy»: son la convención deny-all de MOS.
-- Reversa: node C:/Users/ISO/.sb/apply.cjs "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/1053_rollback.sql"
