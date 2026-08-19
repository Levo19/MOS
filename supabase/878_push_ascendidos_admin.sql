-- [878] PUSH A LOS ASCENDIDOS (19-ago-2026)
-- "Cuando entra un preingreso la notificación me llega a mí (admin/master) pero no a los ascendidos."
-- Cierto: wh.crear_preingreso (y los ~18 emisores admin) mandan a roles MASTER/ADMINISTRADOR/ADMIN, y
-- mos.push_tokens_para empareja por el rol REAL de mos.personal. Un ascendido (acceso_mos=true,
-- rol real ALMACENERO — Jorgenis, Jesus) es ADMIN EFECTIVO en MOS, pero acá nunca calzaba.
--
-- Fix centralizado (1 función, cubre todos los emisores): en la rama `roles`, el ascendido cuenta
-- como ADMIN cuando la audiencia pide ADMIN/ADMINISTRADOR. Ruteo [584] respetado: le llega por la
-- app admin (MOS) si tiene token MOS activo; si no tiene, por la app donde esté (WH). Los pushes a
-- su rol REAL (p.ej. roles:['ALMACENERO']) siguen igual que antes. Nada cambia para no-ascendidos.
do $$
declare v_def text; v_old text; v_new text;
begin
  v_def := pg_get_functiondef('mos.push_tokens_para'::regproc);
  v_old := $q$                  where pe.estado = true
                    and upper(coalesce(pe.rol,'')) = any(v_roles)
                    and nullif(btrim(coalesce(pe.nombre,'')),'') is not null
                    and ( upper(btrim(coalesce(pe.nombre,'')||' '||coalesce(pe.apellido,''))) = upper(btrim(t.usuario))
                          or upper(btrim(pe.nombre)) = upper(btrim(t.usuario)) )
                    -- [584] ruteo por rol: admin/master solo por la app admin (MOS por defecto).
                    --   Roles NO-admin (operador/vendedor) sin restricción → siguen recibiendo por su app.
                    and ( v_admin_app = '*'
                          or upper(coalesce(pe.rol,'')) <> all(array['MASTER','ADMINISTRADOR','ADMIN'])
                          or btrim(coalesce(t.app_origen,'')) = v_admin_app )
            ))$q$;
  if position(v_old in v_def) = 0 then raise exception 'push_tokens_para: ancla no encontrada'; end if;
  v_new := $q$                  where pe.estado = true
                    and nullif(btrim(coalesce(pe.nombre,'')),'') is not null
                    and ( upper(btrim(coalesce(pe.nombre,'')||' '||coalesce(pe.apellido,''))) = upper(btrim(t.usuario))
                          or upper(btrim(pe.nombre)) = upper(btrim(t.usuario)) )
                    and (
                      -- rol REAL emparejado. [584] ruteo por rol: admin/master solo por la app admin (MOS por
                      -- defecto); roles NO-admin (operador/vendedor) sin restricción → siguen por su app.
                      ( upper(coalesce(pe.rol,'')) = any(v_roles)
                        and ( v_admin_app = '*'
                              or upper(coalesce(pe.rol,'')) <> all(array['MASTER','ADMINISTRADOR','ADMIN'])
                              or btrim(coalesce(t.app_origen,'')) = v_admin_app ) )
                      or
                      -- [878] ASCENDIDO (acceso_mos) = ADMIN efectivo para audiencias admin: por MOS si tiene
                      -- token MOS activo; si no tiene ninguno, por la app donde esté (WH).
                      ( coalesce(pe.acceso_mos, false)
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
                                            upper(btrim(coalesce(pe.nombre,'')||' '||coalesce(pe.apellido,''))) ) ) ) )
                    )
            ))$q$;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $$;

-- prueba: la audiencia admin ahora incluye tokens MOS de los ascendidos (y NO sus tokens WH/ME)
with r as (select mos.push_tokens_para(jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN'))) j),
     toks as (select jsonb_array_elements_text(j->'tokens') tk from r)
select t.usuario, t.app_origen, count(*) n
  from toks join mos.push_tokens t on t.token = toks.tk
 where upper(btrim(t.usuario)) in ('JORGENIS','JORGENIS GONZALEZ','JESUS')
 group by 1,2 order by 1,2;
