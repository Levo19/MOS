-- [883] el panel MosGuard (yape_guard_estado) también expone capturaYapes para el toggle por equipo
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('mos.yape_guard_estado'::regproc);
  if position($q$'guardEstado', coalesce(d.guard_estado,'NORMAL'),$q$ in v_def) = 0 then raise notice 'ancla no'; return; end if;
  v_def := replace(v_def, $q$'guardEstado', coalesce(d.guard_estado,'NORMAL'),$q$,
                          $q$'guardEstado', coalesce(d.guard_estado,'NORMAL'), 'capturaYapes', coalesce(d.captura_yapes,true),$q$);
  execute v_def;
end $$;
select (mos.yape_guard_estado('{}'::jsonb)->'data'->'equipos'->0->>'capturaYapes') c0;
