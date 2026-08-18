-- 848d: el POS también entra por acá.
-- mos._claim_ok() solo acepta la app 'MOS'; el JWT de MosExpress dice 'mosExpress', así que el
-- selector de turnos y la asignación desde el POS habrían devuelto APP_NO_AUTORIZADA. Estas tres
-- funciones las usan LAS DOS apps a propósito, así que llevan su propia guarda —la misma forma que
-- ya usa me.creditar_venta_directo— en vez de ensanchar _claim_ok() para todo el sistema.
do $mig$
declare v_def text; v_new text; v_fn text;
begin
  foreach v_fn in array array['turnos_del_dia','credito_asignar','credito_desasignar'] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'mos' and p.proname = v_fn;
    v_new := replace(v_def,
      $old$  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;$old$,
      $old$  -- [848d] MOS y el POS: las dos apps usan esta función a propósito
  if coalesce(me.jwt_app(),'') not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;$old$);
    if v_new = v_def then raise exception '848d: no se encontró la guarda en mos.%', v_fn; end if;
    execute v_new;
  end loop;
end $mig$;
