-- ════════════════════════════════════════════════════════════════════════════
-- 432 · CLAVE ADMIN GLOBAL — cero-GAS, self-defending, rotación en pg_cron.
--
-- INCIDENTE (2026-07-13): el panel mostraba "Clave Global Vigente 2715" pero el
-- verificador (bcrypt) validaba 4010. Causa raíz: la rotación AUTOMÁTICA de GAS
-- (Seguridad.gs::verificarRotacionAuto → rotarClaveAdminGlobal) escribe SOLO el
-- texto plano (ADMIN_GLOBAL_PIN) + la fecha, NUNCA el hash (ADMIN_GLOBAL_PIN_HASH).
-- Resultado: display avanza, verificador congelado, y el PIN viejo (4010) quedaba
-- válido PARA SIEMPRE (hueco de seguridad: admin despedido conserva el global).
--
-- FIX (100% Supabase, cero-GAS):
--   1) GUARD a nivel tabla: mos.config se DEFIENDE SOLA. Nadie (GAS, sync, upsert
--      directo, set_config) puede escribir las 3 llaves del PIN global salvo
--      mos.rotar_clave_admin (que setea un GUC de sesión). Cualquier otra escritura
--      se IGNORA en silencio (no rompe upserts masivos de config que las incluyan).
--   2) rotar_clave_admin: setea el GUC + corrige la próxima rotación (+30 días, era +7).
--   3) get_clave_admin_global: devuelve diasDesde/diasParaProxima/vencida (el panel
--      los lee y salían undefined → "0d") + fechaProxima = últimaRotación + 30 días.
--   4) rotar_clave_admin_si_vence(): auto-rotación gateada por 30 días.
--   5) pg_cron diario → reemplaza el trigger GAS verificarRotacionAuto.
--
-- Formato de fecha estandarizado a UTC-ISO con "Z" (unambiguo; == JS toISOString).
-- Idempotente. Smoke-test en tx-rollback al final (comentado).
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) GUARD: solo rotar_clave_admin puede tocar las 3 llaves del PIN global ───
create or replace function mos._guard_global_pin()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if NEW.clave in ('ADMIN_GLOBAL_PIN','ADMIN_GLOBAL_PIN_HASH','ADMIN_GLOBAL_PIN_FECHA')
     and coalesce(current_setting('mos.allow_global_pin_write', true), '') <> '1' then
    -- Escritura NO autorizada a una llave protegida → se ignora en silencio.
    -- (RETURN NULL en BEFORE INSERT/UPDATE = fila descartada sin error; así un
    --  upsert masivo de config que incluya estas llaves no falla, solo las salta.)
    return null;
  end if;
  return NEW;
end; $fn$;

drop trigger if exists _guard_global_pin_biu on mos.config;
create trigger _guard_global_pin_biu
  before insert or update on mos.config
  for each row execute function mos._guard_global_pin();

-- ── 2) rotar_clave_admin: GUC de autorización + próxima rotación a 30 días ─────
create or replace function mos.rotar_clave_admin(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_manual boolean := coalesce((p->>'manual')::boolean, true);
  v_pinadm text := nullif(btrim(coalesce(p->>'pinAdmin','')),'');
  v_por text := 'AUTO_TRIGGER';
  v_cur text; v_new text; v_try int := 0; v_now timestamptz := now();
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [CRÍTICO-1] Rotación MANUAL exige el PIN de un admin real (rol MASTER/ADMIN, activo).
  if v_manual then
    if v_pinadm is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error','PIN requerido')); end if;
    select nombre into v_por from mos.personal
     where estado = true and upper(coalesce(rol,'')) in ('MASTER','ADMIN','ADMINISTRADOR')
       and ( (pin_hash is not null and pin_hash = extensions.crypt(v_pinadm, pin_hash)) or (coalesce(pin,'') = v_pinadm) )
     limit 1;
    if v_por is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error','PIN no reconocido')); end if;
  end if;

  select valor into v_cur from mos.config where clave='ADMIN_GLOBAL_PIN' limit 1;
  loop
    v_try := v_try + 1;
    v_new := lpad((floor(random()*10000))::int::text, 4, '0');
    if v_new not in ('0000','1111','2222','3333','4444','5555','6666','7777','8888','9999','1234','4321','0123')
       and v_new <> coalesce(v_cur,'') then exit; end if;
    if v_try > 40 then v_new := lpad(((coalesce(v_cur,'0')::int + 7) % 10000)::text, 4, '0'); exit; end if;  -- fallback no-trivial determinista
  end loop;

  -- [GUARD] autorizar la escritura de las 3 llaves protegidas SOLO en esta transacción.
  perform set_config('mos.allow_global_pin_write', '1', true);
  insert into mos.config(clave,valor) values
    ('ADMIN_GLOBAL_PIN', v_new),
    ('ADMIN_GLOBAL_PIN_HASH', extensions.crypt(v_new, extensions.gen_salt('bf'))),
    ('ADMIN_GLOBAL_PIN_FECHA', to_char(v_now at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'))
  on conflict (clave) do update set valor = excluded.valor;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'autorizado', true, 'pin', v_new, 'validadoPor', v_por,
    'diasDesdeRotacion', 0, 'diasParaProximaRotacion', 30, 'vencida', false,
    'fechaUltimaRotacion',  to_char(v_now at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'fechaProximaRotacion', to_char((v_now + interval '30 days') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
end; $fn$;

-- ── 3) get_clave_admin_global: días/vencida correctos + próxima = última + 30 ──
create or replace function mos.get_clave_admin_global(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_pin text := nullif(btrim(coalesce(p->>'pinAdmin','')),'');
  v_por text; v_global text; v_fecha text;
  v_ult timestamptz; v_dias_desde int; v_dias_para int; v_vencida boolean;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_pin is null then return jsonb_build_object('ok',false,'error','Requiere pinAdmin (PIN del solicitante)'); end if;
  select nombre into v_por from mos.personal
   where estado = true and upper(coalesce(rol,'')) in ('MASTER','ADMIN','ADMINISTRADOR')
     and ( (pin_hash is not null and pin_hash = extensions.crypt(v_pin, pin_hash)) or (coalesce(pin,'') = v_pin) )
   limit 1;
  if v_por is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error','PIN no reconocido')); end if;

  select lpad(coalesce(valor,''),4,'0') into v_global from mos.config where clave='ADMIN_GLOBAL_PIN' limit 1;
  select valor into v_fecha from mos.config where clave='ADMIN_GLOBAL_PIN_FECHA' limit 1;

  -- Parseo defensivo de la fecha (UTC-Z estándar; tolera legacy con offset).
  begin v_ult := nullif(btrim(v_fecha),'')::timestamptz; exception when others then v_ult := null; end;
  if v_ult is null then
    v_dias_desde := 0; v_dias_para := 30; v_vencida := false;
  else
    v_dias_desde := greatest(0, floor(extract(epoch from (now() - v_ult)) / 86400)::int);
    v_dias_para  := greatest(0, 30 - v_dias_desde);
    v_vencida    := v_dias_desde >= 30;
  end if;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'autorizado', true, 'pin', coalesce(v_global,''), 'validadoPor', v_por,
    'diasDesdeRotacion', v_dias_desde, 'diasParaProximaRotacion', v_dias_para, 'vencida', v_vencida,
    'fechaUltimaRotacion', coalesce(v_fecha,''),
    'fechaProximaRotacion', case when v_ult is null then ''
      else to_char((v_ult + interval '30 days') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') end));
end; $fn$;
revoke all on function mos.get_clave_admin_global(jsonb) from public, anon;
grant execute on function mos.get_clave_admin_global(jsonb) to authenticated, service_role;

-- ── 4) Auto-rotación gateada por 30 días (reemplaza verificarRotacionAuto GAS) ─
create or replace function mos.rotar_clave_admin_si_vence()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_fecha text; v_ult timestamptz; v_dias int;
begin
  select valor into v_fecha from mos.config where clave='ADMIN_GLOBAL_PIN_FECHA' limit 1;
  begin v_ult := nullif(btrim(v_fecha),'')::timestamptz; exception when others then v_ult := null; end;
  v_dias := case when v_ult is null then 999
                 else floor(extract(epoch from (now() - v_ult)) / 86400)::int end;
  if v_dias >= 30 then
    return mos.rotar_clave_admin('{"manual":false}'::jsonb);
  end if;
  return jsonb_build_object('ok',true,'rotada',false,'diasDesde',v_dias);
end; $fn$;

-- ── 5) pg_cron diario (UTC 08:10 = 03:10 Perú, off-hours) ─────────────────────
create extension if not exists pg_cron;
do $$
begin
  if exists (select 1 from cron.job where jobname = 'mos-rotacion-clave-global') then
    perform cron.unschedule('mos-rotacion-clave-global');
  end if;
end $$;
select cron.schedule('mos-rotacion-clave-global', '10 8 * * *', $$ select mos.rotar_clave_admin_si_vence(); $$);

-- ════════════════════════════════════════════════════════════════════════════
-- SMOKE (tx-rollback):
--   begin;
--   -- guard bloquea escritura directa:
--   insert into mos.config(clave,valor) values ('ADMIN_GLOBAL_PIN','9999')
--     on conflict (clave) do update set valor=excluded.valor;
--   select valor from mos.config where clave='ADMIN_GLOBAL_PIN';  -- NO cambió a 9999
--   -- rotar sí puede + sincroniza plano/hash:
--   select mos.rotar_clave_admin('{"manual":false}'::jsonb);
--   select (h.valor = extensions.crypt(p.valor,h.valor)) from mos.config h, mos.config p
--     where h.clave='ADMIN_GLOBAL_PIN_HASH' and p.clave='ADMIN_GLOBAL_PIN';  -- true
--   rollback;
-- ════════════════════════════════════════════════════════════════════════════
