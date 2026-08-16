-- 815: la Mesa/Paso 1 arma sus operaciones con mos.operaciones_unificadas, que devuelve `foto`
-- pero no cómo debe mostrarse. Sin esto el Paso 1 abriría siempre en 0° y el giro guardado en el
-- 814 no se vería al reabrir la compra.
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'operaciones_unificadas' order by p.oid limit 1;
  if position($a$'foto', coalesce(g.foto,''), 'esPreingreso', false) as obj,$a$ in v_def) = 0 then
    raise exception '[815] no encontré la clave foto en operaciones_unificadas';
  end if;
  v_new := replace(v_def,
    $a$'foto', coalesce(g.foto,''), 'esPreingreso', false) as obj,$a$,
    $b$'foto', coalesce(g.foto,''), 'fotoRot', coalesce(g.foto_rot,0), 'esPreingreso', false) as obj,$b$);
  execute v_new;
end $$;
