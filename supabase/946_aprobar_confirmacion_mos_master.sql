-- [946] Coherencia de jerarquía MOS: el aviso de confirmación "✅ aprobado/reactivado" iba a
-- MASTER+ADMINISTRADOR+ADMIN incluso para un equipo MOS (que SOLO el master puede aprobar). El dueño:
-- "un dispositivo MOS: solo el master notificado". Ahora la confirmación es app-aware:
--   MOS  → solo MASTER · ME/WH → MASTER+ADMINISTRADOR+ADMIN (incluye ascendidos).
-- Solo cambia la audiencia de ESE push; todo lo demás (autorización por nivel, quién aprobó) queda igual.
do $$
declare v_def text; v_old text; v_new text;
begin
  v_def := pg_get_functiondef('mos.aprobar_dispositivo(jsonb)'::regprocedure);
  v_old := $q$      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
      'titulo', case when v_origen = 'INSITU'$q$;
  if position(v_old in v_def) = 0 then raise exception 'aprobar_dispositivo: ancla de audiencia no encontrada'; end if;
  v_new := $q$      'audiencia', jsonb_build_object('roles', case when v_es_mos
                     then jsonb_build_array('MASTER') else jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN') end),
      'titulo', case when v_origen = 'INSITU'$q$;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $$;

select 'aprobar_dispositivo: confirmación MOS → solo master' as ok;
