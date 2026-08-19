-- 864c: el `limit 5` de la franja "esperando su Yape" no limitaba nada.
--
-- Estaba puesto DESPUÉS de un jsonb_agg, y un agregado sin group by devuelve una sola fila:
-- el limit recortaba esa fila única, no las ventas. La franja quedaba abierta a cuantos
-- tickets virtuales hubiera en 45 minutos, y en hora punta eso es una tira que cruza la
-- pantalla de cobro entera. Se mueve el corte adentro, donde sí manda sobre las filas.

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'yapes_rio';

  v_new := replace(v_def,
$old$  select coalesce(jsonb_agg(jsonb_build_object(
      'idVenta', v.id_venta, 'correlativo', coalesce(v.correlativo,''),
      'monto', me._monto_virtual(v.forma_pago, v.total),
      'hora', to_char(v.fecha at time zone 'America/Lima','HH24:MI')
    ) order by v.fecha desc), '[]'::jsonb) into v_esperando
    from me.ventas v
   where v_caja is not null and v.id_caja = v_caja
     and me._monto_virtual(v.forma_pago, v.total) is not null
     and v.fecha > now() - interval '45 minutes'
     and not exists (select 1 from mos.yapes_entrantes y where y.id_venta = v.id_venta)
   limit 5;$old$,
$new$  select coalesce(jsonb_agg(jsonb_build_object(
      'idVenta', f.id_venta, 'correlativo', coalesce(f.correlativo,''),
      'monto', f.monto_vir,
      'hora', to_char(f.fecha at time zone 'America/Lima','HH24:MI')
    ) order by f.fecha desc), '[]'::jsonb) into v_esperando
    from (
      select v.id_venta, v.correlativo, v.fecha,
             me._monto_virtual(v.forma_pago, v.total) as monto_vir
        from me.ventas v
       where v_caja is not null and v.id_caja = v_caja
         and me._monto_virtual(v.forma_pago, v.total) is not null
         and v.fecha > now() - interval '45 minutes'
         and not exists (select 1 from mos.yapes_entrantes y where y.id_venta = v.id_venta)
       order by v.fecha desc
       limit 5
    ) f;$new$);

  if v_new = v_def then raise exception '864c: no calzó el bloque de esperando'; end if;
  execute v_new;
end $mig$;

-- el espejo en `me` reenvía, así que no hay nada que tocar ahí
select 'mos.yapes_rio' f, (mos.yapes_rio('{"zona":"ZONA-02","idCaja":"NADA","min":90}'::jsonb)->>'ok') ok;
