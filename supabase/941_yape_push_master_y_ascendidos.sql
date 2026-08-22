-- [941] Dos arreglos de notificaciones que el dueño vio en producción (22-ago-2026):
--
-- PUNTO 1 · Los avisos de MosGuard/Yape (equipo caído / perdió permiso) iban a roles
--   MASTER/ADMINISTRADOR/ADMIN → le llegaban a TODOS los admin y ascendidos = spam. Son cosa del
--   dueño (dinero/vigilancia). Ahora van a SOLO MASTER. (874 redefinió cron_yape_vigilar sobre 862;
--   es UNA sola función y UN solo cron 'yape-vigilar'.)
--
-- PUNTO 2 · Los avisos de nivel ADMIN (ej "🎯 Ingresó X · considera enviarlo") le llegaban al master
--   pero NO a los ascendidos (Jesus, Jorgenis). La audiencia SÍ los incluía, pero [878] los ruteaba
--   "solo por MOS si tienen token MOS"; si ese token MOS falla en FCM (se vio entregadas 7/10, 3
--   errores), se quedaban sin aviso aunque tuvieran WH vivo. Fix: el ascendido = admin efectivo →
--   recibe los push ADMIN por TODAS sus apps (MOS + WH). Sigue sin recibir los MASTER-only (punto 1),
--   porque su rama exige que la audiencia pida ADMIN/ADMINISTRADOR.

begin;

-- ── PUNTO 1 · cron_yape_vigilar → solo MASTER ──
do $$
declare v_def text; v_old text; v_new text;
begin
  v_def := pg_get_functiondef('mos.cron_yape_vigilar()'::regprocedure);
  v_old := $q$'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),$q$;
  if position(v_old in v_def) = 0 then raise exception 'cron_yape_vigilar: ancla de audiencia no encontrada'; end if;
  v_new := $q$'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),   -- [941] MosGuard/Yape solo al dueño$q$;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $$;

-- ── PUNTO 2 · push_tokens_para → el ascendido admin recibe por todas sus apps ──
do $$
declare v_def text; v_old text; v_new text;
begin
  v_def := pg_get_functiondef('mos.push_tokens_para(jsonb)'::regprocedure);
  v_old := $q$                      ( coalesce(pe.acceso_mos, false)
                        and (array['ADMIN','ADMINISTRADOR'] && v_roles)
                        and ( v_admin_app = '*'
                              or btrim(coalesce(t.app_origen,'')) = v_admin_app
                              or not exists (
                                   select 1 from mos.push_tokens t2
                                    where coalesce(t2.activo, true)
                                      and nullif(btrim(coalesce(t2.token,'')),'') is not null
                                      and btrim(coalesce(t2.app_origen,'')) = v_admin_app
                                      and upper(btrim(coalesce(t2.usuario,''))) in (
                                            upper(btrim(pe.nombre)),
                                            upper(btrim(coalesce(pe.nombre,'')||' '||coalesce(pe.apellido,''))) ) ) ) )$q$;
  if position(v_old in v_def) = 0 then raise exception 'push_tokens_para: ancla ascendido no encontrada'; end if;
  -- [941] sin gate de app: el ascendido (admin efectivo) recibe los push ADMIN por TODAS sus apps
  -- activas (MOS + WH) → un token FCM caído en una no lo deja sin aviso. Los MASTER-only quedan fuera
  -- porque exige ADMIN/ADMINISTRADOR en la audiencia.
  v_new := $q$                      ( coalesce(pe.acceso_mos, false)
                        and (array['ADMIN','ADMINISTRADOR'] && v_roles) )$q$;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $$;

commit;

-- pruebas
select 'yape → solo master' etiqueta,
       (select jsonb_array_length((mos.push_tokens_para(jsonb_build_object('roles', jsonb_build_array('MASTER'))))->'tokens')) tokens_master;
-- la audiencia admin debe incluir tokens WH de los ascendidos (Jesus/Jorgenis)
with r as (select mos.push_tokens_para(jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN'))) j),
     toks as (select jsonb_array_elements_text(j->'tokens') tk from r)
select t.usuario, t.app_origen, count(*) n
  from toks join mos.push_tokens t on t.token = toks.tk
 where upper(btrim(t.usuario)) in ('JESUS','JORGENIS','JORGENIS GONZALEZ')
 group by 1,2 order by 1,2;
