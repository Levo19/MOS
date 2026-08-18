-- 848b: el POS necesita saber, de un vistazo, qué tickets de crédito YA tienen dueño.
-- Se agrega `asignadoA` (el nombre del turno al que se asignó) al ticket que devuelve
-- me.datos_turno — la misma fuente que alimenta la lista de tickets de MosExpress.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'me' and p.proname = 'datos_turno';

  v_new := replace(v_def,
$old$      'obs',         coalesce(tk.obs,''),
      'items',       coalesce(items.its, '[]'::jsonb)$old$,
$new$      'obs',         coalesce(tk.obs,''),
      -- [848] a qué turno se le asignó este crédito ('' = todavía sin dueño)
      'asignadoA',   coalesce((select cp.nombre_dia from mos.creditos_planilla cp
                                where cp.id_venta = tk.id_venta and cp.estado = 'ASIGNADO' limit 1),''),
      'items',       coalesce(items.its, '[]'::jsonb)$new$);
  if v_new = v_def then raise exception '848b: no se encontró el objeto ticket en datos_turno'; end if;
  execute v_new;
end $mig$;
