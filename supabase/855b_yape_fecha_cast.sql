-- 855b: v_fecha_dia es TEXT en datos_turno; comparar contra una date reventaba en ejecución.
-- Se usa el día de las ventas de la propia caja, que es la fuente correcta de todos modos:
-- el resumen tiene que hablar del día que se está cerrando, no del calendario del servidor.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='me' and p.proname='datos_turno';
  v_new := replace(v_def,
    $old$          'ambiguos', (select count(*) from mos.yapes_entrantes ya
                        where ya.estado='AMBIGUO' and ya.dia = v_fecha_dia),
          'sinUsar',  (select count(*) from mos.yapes_entrantes yn
                        where yn.estado='NUEVO' and yn.dia = v_fecha_dia and yn.monto is not null))$old$,
    $old$          'ambiguos', (select count(*) from mos.yapes_entrantes ya
                        where ya.estado='AMBIGUO'
                          and ya.dia = (select max((v2.fecha at time zone v_tz)::date)
                                          from me.ventas v2 where v2.id_caja = p_id_caja)),
          'sinUsar',  (select count(*) from mos.yapes_entrantes yn
                        where yn.estado='NUEVO' and yn.monto is not null
                          and yn.dia = (select max((v3.fecha at time zone v_tz)::date)
                                          from me.ventas v3 where v3.id_caja = p_id_caja)))$old$);
  if v_new = v_def then raise exception '855b: no se encontró el bloque ambiguos'; end if;
  execute v_new;
end $mig$;
