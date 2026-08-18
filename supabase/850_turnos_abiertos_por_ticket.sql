-- 850: el botón ASIGNAR solo donde puede funcionar.
--
-- La mesa de créditos muestra 365 días. Pintar "ASIGNAR" en los 102 tickets vivos es ruido: en un
-- día cuyos turnos ya se liquidaron, el servidor rechaza la asignación (el monto está sellado) y el
-- admin se lleva un mensaje de error por curiosear. Cada ticket dice ahora si SU día todavía tiene
-- algún turno abierto; el botón se pinta solo ahí.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'me' and p.proname = 'creditos_pendientes';

  v_new := replace(v_def,
$old$      'asignado',   a.asignado,
      -- [848] a qué TURNO se le carga este consumo (null = todavía sin dueño)$old$,
$old$      'asignado',   a.asignado,
      -- [850] ¿el día de este ticket todavía tiene algún turno abierto al que cargarlo?
      'turnosAbiertos', exists (
          select 1 from mos.liquidaciones_dia l
           where (l.fecha at time zone 'America/Lima')::date = (vt.fecha at time zone 'America/Lima')::date
             and upper(coalesce(l.estado,'PENDIENTE')) = 'PENDIENTE'
             and upper(coalesce(l.rol,'')) not in ('MASTER','ADMIN','ADMINISTRADOR')),
      -- [848] a qué TURNO se le carga este consumo (null = todavía sin dueño)$old$);
  if v_new = v_def then raise exception '850: no se encontró el campo trabajador en creditos_pendientes'; end if;
  execute v_new;
end $mig$;
