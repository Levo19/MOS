-- 848c: la mesa de créditos de MOS necesita ver si un ticket ya está cargado a un trabajador.
-- OJO con el cruce de nombres: en este módulo `asignado` YA significa otra cosa (el crédito
-- enviado a la caja de un cajero para que lo COBRE, el ✈ "en vuelo"). Lo nuevo se llama
-- `trabajador` para que las dos ideas no se confundan nunca.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'me' and p.proname = 'creditos_pendientes';

  v_new := replace(v_def,
$old$      'asignado',   a.asignado,$old$,
$old$      'asignado',   a.asignado,
      -- [848] a qué TURNO se le carga este consumo (null = todavía sin dueño)
      'trabajador', (select jsonb_build_object('nombre', coalesce(cp.nombre_dia,''), 'idDia', coalesce(cp.id_dia,''),
                                               'idPersonal', cp.id_personal, 'estado', cp.estado,
                                               'fechaDia', to_char(cp.fecha_dia,'YYYY-MM-DD'))
                       from mos.creditos_planilla cp
                      where cp.id_venta = vt.id_venta and cp.estado in ('ASIGNADO','DESCONTADO') limit 1),$old$);
  if v_new = v_def then raise exception '848c: no se encontró el campo asignado en creditos_pendientes'; end if;
  execute v_new;
end $mig$;
