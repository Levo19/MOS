-- ════════════════════════════════════════════════════════════════════════════
-- 433 · rotar_clave_admin → MANUAL exige rol MASTER (política ROTAR_PIN_GLOBAL = nivel 3).
--
-- Audit 2026-07-13: permisos_accion.ROTAR_PIN_GLOBAL = nivel_minimo 3 (MASTER-only),
-- pero rotar_clave_admin aceptaba rol in (MASTER, ADMIN, ADMINISTRADOR). El botón del
-- panel ya oculta la rotación a no-MASTER (UI), pero un ADMIN podía rotar llamando la
-- RPC directo. Se cierra: la rotación MANUAL exige rol_nivel >= 3 (MASTER). La rotación
-- AUTO (manual:false, pg_cron) no cambia (no lleva PIN).
--
-- Idéntica a 432 salvo el filtro de rol del bloque manual. Idempotente.
-- ════════════════════════════════════════════════════════════════════════════
create or replace function mos.rotar_clave_admin(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_manual boolean := coalesce((p->>'manual')::boolean, true);
  v_pinadm text := nullif(btrim(coalesce(p->>'pinAdmin','')),'');
  v_por text := 'AUTO_TRIGGER';
  v_cur text; v_new text; v_try int := 0; v_now timestamptz := now();
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [433] Rotación MANUAL exige el PIN de un MASTER (rol_nivel >= 3), activo. Política
  -- ROTAR_PIN_GLOBAL = MASTER-only. Un ADMIN ya NO puede rotar ni llamando la RPC directo.
  if v_manual then
    if v_pinadm is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error','PIN requerido')); end if;
    select nombre into v_por from mos.personal
     where estado = true and mos.rol_nivel(rol) >= 3
       and ( (pin_hash is not null and pin_hash = extensions.crypt(v_pinadm, pin_hash)) or (coalesce(pin,'') = v_pinadm) )
     limit 1;
    if v_por is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error','Solo un MASTER puede rotar la clave global')); end if;
  end if;

  select valor into v_cur from mos.config where clave='ADMIN_GLOBAL_PIN' limit 1;
  loop
    v_try := v_try + 1;
    v_new := lpad((floor(random()*10000))::int::text, 4, '0');
    if v_new not in ('0000','1111','2222','3333','4444','5555','6666','7777','8888','9999','1234','4321','0123')
       and v_new <> coalesce(v_cur,'') then exit; end if;
    if v_try > 40 then v_new := lpad(((coalesce(v_cur,'0')::int + 7) % 10000)::text, 4, '0'); exit; end if;
  end loop;

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
