-- 807_dispositivo_fijado.sql — [DUEÑO] "quiero un botón en Infraestructura que lo FIJE, así la
-- regla de inactividad no aplica para ese dispositivo. Mi jefa no maneja claves, no requiere eso,
-- y con ella no tengo pérdida ni alteración. Sé que existe la solicitud remota y funciona, pero a
-- veces lo quiere rápido y yo estoy sin celular. Solo aplica a usuarios MOS, pero la condición es
-- que el dispositivo debe tener un nombre puesto y yo debo poner mi clave master. Y debe ser
-- retroactivo: el ícono cambia de forma y se puede QUITAR el fijado, y vuelve la regla general."
--
-- LA REGLA QUE SE EXIME (medida en `mos.cron_dispositivos_inactivos`, cron cada hora):
--   (1) ACTIVO + más de 2 días sin conectar        → SUSPENDIDO
--   (2) SUSPENDIDO + más de 7 días sin conectar    → CANCELADO_AUTO (archivado)
--   (3) PENDIENTE_APROBACION sin sesión + 1 hora   → CANCELADO_AUTO
-- El fijado exime de (1) y (2). NO toca (3): esa cancela SOLICITUDES que nunca entraron, y un
-- equipo fijado ya está aprobado, así que nunca cae por ahí.
--
-- LO QUE **NO** HACE, a propósito: fijar no da permisos, no salta el bloqueo manual, no revive un
-- equipo cancelado ni evita el `forzar_logout`. Solo dice "a este no lo suspendas por no usarlo".
-- Un equipo robado o perdido se sigue bloqueando a mano igual que siempre.
--
-- CONDICIONES (las tres que puso el dueño, verificadas en el servidor, no en el navegador):
--   · el dispositivo debe ser de MOS (app 'MOS' o vacío, que es como se guarda el panel);
--   · debe tener NOMBRE PROPIO — se rechaza el autogenerado ("PC a1b2c3", "Móvil 4d5e6f"…),
--     que es justamente el patrón que pone `mos._tg_dispositivo_autolabel`;
--   · exige CLAVE MASTER: la acción `DISPOSITIVO_FIJAR` se siembra en nivel 3, y `rol_nivel`
--     solo da 3 a MASTER. La clave se valida server-side con bcrypt + lockout + auditoría.

alter table mos.dispositivos add column if not exists fijado_ts     timestamptz;
alter table mos.dispositivos add column if not exists fijado_por    text;
alter table mos.dispositivos add column if not exists fijado_motivo text;

comment on column mos.dispositivos.fijado_ts is
  '[807] Si no es null, el equipo está FIJADO: la suspensión por inactividad (+2d) y el archivado (+7d) no lo tocan. Solo lo pone/quita un MASTER con su clave.';

-- La acción, en nivel MASTER (rol_nivel: MASTER=3, ADMIN=2, resto=1)
insert into mos.permisos_accion (accion, tier, nivel_minimo, label, app)
values ('DISPOSITIVO_FIJAR', 3, 3, 'Fijar / soltar dispositivo (master)', 'MOS')
on conflict (accion) do update
   set tier = excluded.tier, nivel_minimo = excluded.nivel_minimo,
       label = excluded.label, app = excluded.app;


create or replace function mos.dispositivo_fijar(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_id     text    := nullif(btrim(coalesce(p->>'idDispositivo','')),'');
  v_fijar  boolean := coalesce((p->>'fijar')::boolean, true);
  v_clave  text    := nullif(btrim(coalesce(p->>'clave','')),'');
  v_usr    text    := coalesce(nullif(btrim(p->>'usuario'),''),'');
  v_motivo text    := left(coalesce(nullif(btrim(p->>'motivo'),''),''), 200);
  v_d      record;
  v_err    jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idDispositivo'); end if;

  select * into v_d from mos.dispositivos where id_dispositivo = v_id limit 1;
  if v_d.id_dispositivo is null then
    return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_ENCONTRADO');
  end if;

  -- (a) solo equipos de MOS
  if upper(coalesce(v_d.app,'')) not in ('MOS','') then
    return jsonb_build_object('ok',false,'error',
      'Solo se pueden fijar equipos de MOS (este es de ' || coalesce(nullif(v_d.app,''),'?') || ')');
  end if;

  -- (b) al FIJAR exige nombre propio: el autogenerado no cuenta (es el que pone el trigger)
  if v_fijar then
    if coalesce(nullif(btrim(v_d.nombre_equipo),''),'') = ''
       or v_d.nombre_equipo ~* '^(Mobile|Equipo|Móvil|Movil|Tablet|PC|Mac|iPhone|iPad) [0-9a-fA-F]{6}$' then
      return jsonb_build_object('ok',false,'error','SIN_NOMBRE',
        'mensaje','Ponle primero un nombre al equipo (el automático no sirve: hay que saber de quién es).');
    end if;
  end if;

  -- (c) clave MASTER, verificada en el servidor
  v_err := mos.reverificar_clave_admin(v_clave, 'DISPOSITIVO_FIJAR', v_id, 'MOS');
  if v_err is not null then return v_err; end if;

  update mos.dispositivos
     set fijado_ts     = case when v_fijar then now() else null end,
         fijado_por    = case when v_fijar then nullif(v_usr,'') else null end,
         fijado_motivo = case when v_fijar then nullif(v_motivo,'') else null end
   where id_dispositivo = v_id;

  -- auditoría: quién fijó/soltó qué equipo y cuándo
  begin
    insert into mos.auditoria_admin(id_accion, fecha, accion, ref_documento, nombre_autoriza,
                                    rol_autoriza, nivel_autoriza, app_origen, tier, device_id, detalle)
    values ('AUD-' || replace(gen_random_uuid()::text,'-',''), now(),
            case when v_fijar then 'DISPOSITIVO_FIJAR' else 'DISPOSITIVO_SOLTAR' end,
            v_id, nullif(v_usr,''), 'MASTER', 3, 'MOS', 3, v_id,
            case when v_fijar then 'Fijado (exento de suspensión por inactividad)'
                 else 'Soltado (vuelve a la regla general de inactividad)' end
            || ' · equipo: ' || coalesce(nullif(btrim(v_d.nombre_equipo),''), v_id)
            || case when v_motivo <> '' then ' · motivo: ' || v_motivo else '' end);
  exception when others then null; end;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idDispositivo', v_id, 'fijado', v_fijar,
    'nombre', coalesce(nullif(btrim(v_d.nombre_equipo),''), v_id)));
end;
$function$;

grant execute on function mos.dispositivo_fijar(jsonb) to anon, authenticated, service_role;


-- ── El cron deja de tocar a los fijados ──
create or replace function mos._mig807_patch(p_old text, p_new text, p_veces int)
returns void language plpgsql as $$
declare v_def text; v_new text; v_oid oid; v_n int;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'cron_dispositivos_inactivos' order by p.oid limit 1;
  if v_oid is null then raise exception '[807] mos.cron_dispositivos_inactivos no existe'; end if;
  v_def := pg_get_functiondef(v_oid);
  v_n := (length(v_def) - length(replace(v_def, p_old, ''))) / nullif(length(p_old), 0);
  if v_n <> p_veces then
    raise exception '[807] se esperaban % ocurrencias y hay %', p_veces, v_n;
  end if;
  v_new := replace(v_def, p_old, p_new);
  execute v_new;
end $$;

-- (1) suspensión por +2 días
select mos._mig807_patch(
  '      where upper(coalesce(estado,'''')) = ''ACTIVO''
        and ultima_conexion is not null
        and ultima_conexion < now() - interval ''2 days''',
  '      where upper(coalesce(estado,'''')) = ''ACTIVO''
        and fijado_ts is null   -- [807] los equipos FIJADOS no se suspenden por inactividad
        and ultima_conexion is not null
        and ultima_conexion < now() - interval ''2 days''', 1);

-- (2) archivado por +7 días
select mos._mig807_patch(
  '    where upper(coalesce(estado,'''')) = ''SUSPENDIDO''
      and ultima_conexion is not null
      and ultima_conexion < now() - interval ''7 days'';',
  '    where upper(coalesce(estado,'''')) = ''SUSPENDIDO''
      and fijado_ts is null   -- [807] un fijado tampoco se archiva
      and ultima_conexion is not null
      and ultima_conexion < now() - interval ''7 days'';', 1);

-- (3) el aviso al master tampoco debe nombrar a los fijados: su inactividad es esperada
select mos._mig807_patch(
  '   where upper(coalesce(estado,''''))=''ACTIVO'' and upper(coalesce(app,'''')) in (''MOS'','''')
     and ultima_conexion is not null',
  '   where upper(coalesce(estado,''''))=''ACTIVO'' and upper(coalesce(app,'''')) in (''MOS'','''')
     and fijado_ts is null   -- [807] no se avisa por un equipo que el master fijó a propósito
     and ultima_conexion is not null', 1);

drop function mos._mig807_patch(text,text,int);


-- ── El panel necesita saber quién está fijado ──
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'listar_dispositivos' order by p.oid limit 1;
  if position($anc$'ID_Dispositivo',            d.id_dispositivo,$anc$ in v_def) = 0 then
    raise exception '[807] no se encontró el ancla en listar_dispositivos';
  end if;
  v_new := replace(v_def,
    $anc$'ID_Dispositivo',            d.id_dispositivo,$anc$,
    $anc2$'ID_Dispositivo',            d.id_dispositivo,
      'Fijado',                    (d.fijado_ts is not null),
      'Fijado_Por',                coalesce(d.fijado_por,''),
      'Fijado_Ts',                 mos._iso_z(d.fijado_ts),
      'Fijado_Motivo',             coalesce(d.fijado_motivo,''),$anc2$);
  execute v_new;
end $$;
