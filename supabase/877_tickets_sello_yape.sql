-- [877] SELLO DE VERIFICACIÓN en los tickets de MOS (Cajas → Tickets de Caja y rangos).
-- El dueño: "aquí debo poder ver los verificados también (aunque en el otro lado los desverifico)".
-- mos.cierres_caja y mos.tickets_rango no traían el Yape que verifica cada ticket; me.datos_turno
-- sí (855). Se agrega el MISMO campo `yape` ({pagador, hora, monto} | null) a los dos, con el
-- índice ux_yapes_venta (id_venta) ya existente: costo despreciable.
do $$
declare v_def text;
begin
  -- ── cierres_caja: el objeto de ticket del CTE tk ──
  v_def := pg_get_functiondef('mos.cierres_caja'::regproc);
  if position($q$'zona',        vc.cm_zona
      ) as obj$q$ in v_def) = 0 then raise exception 'cierres_caja: ancla no encontrada'; end if;
  v_def := replace(v_def,
    $q$'zona',        vc.cm_zona
      ) as obj$q$,
    $q$'zona',        vc.cm_zona,
        -- [877] Yape que verifica este ticket (null = sin verificar / no aplica)
        'yape',        (select jsonb_build_object('pagador', coalesce(y.pagador,''), 'monto', y.monto,
                                                   'hora', to_char(y.ts_notificacion at time zone v_tz,'HH24:MI'))
                          from mos.yapes_entrantes y
                         where y.id_venta = vc.id_venta and y.estado = 'MATCHEADO' limit 1)
      ) as obj$q$);
  execute v_def;

  -- ── tickets_rango ──
  v_def := pg_get_functiondef('mos.tickets_rango'::regproc);
  if position($q$'vendedor', coalesce(nullif(btrim(vendedor),''), cm_vendedor, ''), 'zona', cm_zona)$q$ in v_def) = 0 then raise exception 'tickets_rango: ancla no encontrada'; end if;
  v_def := replace(v_def,
    $q$'vendedor', coalesce(nullif(btrim(vendedor),''), cm_vendedor, ''), 'zona', cm_zona)$q$,
    $q$'vendedor', coalesce(nullif(btrim(vendedor),''), cm_vendedor, ''), 'zona', cm_zona,
           'yape', (select jsonb_build_object('pagador', coalesce(y.pagador,''), 'monto', y.monto,
                                              'hora', to_char(y.ts_notificacion at time zone v_tz,'HH24:MI'))
                      from mos.yapes_entrantes y where y.id_venta = enr.id_venta and y.estado = 'MATCHEADO' limit 1))$q$);
  execute v_def;
end $$;

-- prueba: los tickets virtuales de hoy con su sello
select count(*) filter (where t->>'metodo' in ('VIRTUAL') or t->>'metodo' like 'MIXTO%') virtuales,
       count(*) filter (where (t->>'metodo' in ('VIRTUAL') or t->>'metodo' like 'MIXTO%') and t->'yape' is not null and t->'yape' <> 'null'::jsonb) verificados
  from jsonb_array_elements((mos.tickets_rango(jsonb_build_object('desde', (now() at time zone 'America/Lima')::date, 'hasta', (now() at time zone 'America/Lima')::date))->'todosTickets')) t;
