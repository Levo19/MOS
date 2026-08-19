-- 864b: la franja "esperando su Yape" es para lo que ACABA de cobrarse, no para todo el día.
-- Con 11 tickets del día entero se volvía un muro y perdía el sentido: lo viejo sin verificar
-- pertenece al cierre de caja, no a la pantalla de cobro. Se acota a 45 minutos y 5 filas.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='mos' and p.proname='yapes_rio';
  v_new := replace(v_def,
    $old$     and not exists (select 1 from mos.yapes_entrantes y where y.id_venta = v.id_venta);$old$,
    $old$     and v.fecha > now() - interval '45 minutes'
     and not exists (select 1 from mos.yapes_entrantes y where y.id_venta = v.id_venta)
   limit 5;$old$);
  if v_new = v_def then raise exception '864b: no se encontró el filtro'; end if;
  execute v_new;
end $mig$;
