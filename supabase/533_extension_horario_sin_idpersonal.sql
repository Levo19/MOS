-- 533_extension_horario_sin_idpersonal.sql — FIX del dueño: "permiso remoto → error id_personal,
-- no llega ningún permiso a MOS". El RPC exigía idPersonal, pero los configs viejos de ME no lo
-- traían y el guardia moría ANTES de enviar. La solicitud SIEMPRE viaja con deviceId y la
-- aprobación es por UUID (memoria: extensión 1h remota por UUID) → hacerla tolerante:
--   1) si falta idPersonal → resolverlo desde la CAJA ABIERTA de ese dispositivo (vendedor →
--      mos.personal por nombre, case-insensitive);
--   2) si tampoco → registrar como 'DEV:'+uuid (trazable; el admin aprueba por dispositivo).
-- Solo cambia el bloque del guardia; el resto del cuerpo queda idéntico (redefinición dinámica).
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'solicitar_extension_horario';
  v_src := replace(v_src,
    'if v_id is null then return jsonb_build_object(''ok'',false,''error'',''idPersonal requerido''); end if;',
    'if v_id is null and v_dev is not null then
    -- [533] resolver desde la caja ABIERTA del dispositivo (la sesión existe aunque esté bloqueada por horario)
    select p2.id_personal into v_id
      from me.cajas c
      join mos.personal p2 on lower(btrim(p2.nombre || '' '' || coalesce(p2.apellido,''''))) = lower(btrim(c.vendedor))
                           or lower(btrim(p2.nombre)) = lower(btrim(c.vendedor))
     where c.dispositivo_id = v_dev and upper(coalesce(c.estado,'''')) = ''ABIERTA''
     order by c.fecha_apertura desc limit 1;
    if v_id is null then v_id := ''DEV:'' || v_dev; end if;   -- trazable por UUID (la aprobación es por device)
  end if;
  if v_id is null then return jsonb_build_object(''ok'',false,''error'',''idPersonal requerido''); end if;');
  execute v_src;
end $$;
