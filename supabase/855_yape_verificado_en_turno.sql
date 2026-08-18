-- 855: el ticket tiene que saber si su Yape llegó, y el cierre de caja tiene que separar
-- lo VERIFICADO de lo que no. Todo sale de me.datos_turno, la misma fuente que ya alimenta
-- la lista de tickets y el cierre de MosExpress — sin una segunda verdad.
--
-- OJO CON EL LENGUAJE: un ticket sin Yape NO es un ticket no pagado. Puede que el Yape aún no
-- haya llegado, o que el cliente pagara con otra billetera. Se dice "sin verificar".
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='me' and p.proname='datos_turno';

  -- (a) por ticket: quién lo verificó y con cuánto
  v_new := replace(v_def,
    $old$      'asignadoA',   coalesce((select cp.nombre_dia from mos.creditos_planilla cp$old$,
    $old$      -- [855] Yape que verifica este ticket ('' = todavía sin verificar)
      'yape',        (select jsonb_build_object('pagador', coalesce(y.pagador,''), 'monto', y.monto,
                                'hora', to_char(y.ts_notificacion at time zone v_tz,'HH24:MI'))
                        from mos.yapes_entrantes y
                       where y.id_venta = tk.id_venta and y.estado = 'MATCHEADO' limit 1),
      'asignadoA',   coalesce((select cp.nombre_dia from mos.creditos_planilla cp$old$);
  if v_new = v_def then raise exception '855: no se encontró el objeto ticket'; end if;
  v_def := v_new;

  -- (b) resumen para el cierre de caja
  v_new := replace(v_def,
    $old$      'metaAudit',      v_meta_audit,$old$,
    $old$      -- [855] cierre: cuánto de lo cobrado por VIRTUAL tiene su Yape verificado
      'yapes', (
        select jsonb_build_object(
          'verificados',      count(*) filter (where y.id is not null),
          'sinVerificar',     count(*) filter (where y.id is null),
          'montoVerificado',  coalesce(sum(v.total) filter (where y.id is not null),0),
          'montoSinVerificar',coalesce(sum(v.total) filter (where y.id is null),0),
          'ambiguos', (select count(*) from mos.yapes_entrantes ya
                        where ya.estado='AMBIGUO' and ya.dia = v_fecha_dia),
          'sinUsar',  (select count(*) from mos.yapes_entrantes yn
                        where yn.estado='NUEVO' and yn.dia = v_fecha_dia and yn.monto is not null))
          from me.ventas v
          left join mos.yapes_entrantes y on y.id_venta = v.id_venta and y.estado='MATCHEADO'
         where v.id_caja = p_id_caja
           and upper(coalesce(v.forma_pago,'')) = 'VIRTUAL'),
      'metaAudit',      v_meta_audit,$old$);
  if v_new = v_def then raise exception '855: no se encontró metaAudit'; end if;
  execute v_new;
end $mig$;
