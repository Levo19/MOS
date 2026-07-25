-- ════════════════════════════════════════════════════════════════════
-- 548 — MosGo: login por PIN PERSONAL (corrección del dueño).
-- La clave de 8 dígitos es SOLO para autorizaciones/permisos (p.ej.
-- verificar rendición). Para ENTRAR a la app el admin usa su PIN
-- personal, como en ME/WH. MosGo es solo-admins → el gate de nivel
-- vive DENTRO de esta RPC (rol_efectivo nivel >= 2 o ascendido).
-- ════════════════════════════════════════════════════════════════════

create or replace function mos.ruta_login_pin(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_pin text := nullif(btrim(coalesce(p->>'pin','')), '');
  v_op  mos.personal%rowtype;
  v_rol_ef text;
begin
  if v_pin is null then return jsonb_build_object('ok', false, 'error', 'PIN requerido'); end if;

  -- mismo criterio que login_pin_wh: busca por PIN activo; si hubiera PIN
  -- duplicado, prefiere al de mayor nivel (esta app es de admins)
  select * into v_op from mos.personal
   where btrim(coalesce(pin,'')) = v_pin and coalesce(estado, false) = true
   order by mos.rol_nivel(rol) desc
   limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'PIN incorrecto'); end if;

  -- rol EFECTIVO: ascendido (acceso_mos) se presenta como ADMIN
  v_rol_ef := mos.rol_efectivo(v_op.rol, v_op.acceso_mos);
  if mos.rol_nivel(v_rol_ef) < 2 then
    return jsonb_build_object('ok', false, 'error', 'SOLO_ADMINS',
      'detalle', 'MosGo es exclusivo para administradores');
  end if;

  return jsonb_build_object('ok', true, 'autorizado', true,
    'id_personal', v_op.id_personal, 'nombre', v_op.nombre, 'rol', v_rol_ef);
end; $$;

grant execute on function mos.ruta_login_pin(jsonb) to anon, authenticated, service_role;
