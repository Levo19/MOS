-- 862_yape_latido.sql — QUE NO SE MUERA EN SILENCIO
--
-- El agujero que quedaba: si el celular se apaga, se queda sin datos o Android mata la app, deja
-- de capturar Yapes y NADIE se entera. Los tickets simplemente dejan de verificarse y el admin lo
-- descubre al cerrar caja, cuando ya no puede hacer nada.
--
-- Un Yape capturado también es señal de vida, pero no alcanza: un día sin pagos por Yape se ve
-- exactamente igual que un celular muerto. Por eso el equipo late cada 15 minutos aunque no pase
-- nada, y acá se guarda ese latido junto con su estado (si perdió el permiso de notificaciones,
-- cuántas capturas tiene esperando).
--
-- El aviso al dueño sale UNA vez por equipo caído y solo dentro del horario de trabajo: nadie
-- necesita un push a las 3 de la mañana avisando que el celular del mostrador está apagado.

begin;

alter table mos.yape_dispositivos add column if not exists ultimo_latido timestamptz;
alter table mos.yape_dispositivos add column if not exists permiso_ok    boolean;
alter table mos.yape_dispositivos add column if not exists pendientes    integer;
alter table mos.yape_dispositivos add column if not exists modelo        text;
alter table mos.yape_dispositivos add column if not exists aviso_caido_ts timestamptz;

create or replace function mos.yape_latido(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_sec text := coalesce(p->>'secreto',''); v_id bigint;
begin
  if v_sec = '' then return jsonb_build_object('ok',false,'error','sin secreto'); end if;
  update mos.yape_dispositivos
     set ultimo_latido = now(),
         ultima_señal  = greatest(coalesce(ultima_señal, now()), now()),
         permiso_ok    = coalesce((p->>'permiso')::boolean, permiso_ok),
         pendientes    = coalesce(nullif(p->>'pendientes','')::int, pendientes),
         modelo        = coalesce(nullif(btrim(coalesce(p->>'equipo','')),''), modelo),
         aviso_caido_ts = null           -- volvió: el próximo corte vuelve a avisar
   where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex')
   returning id into v_id;
  if v_id is null then return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_AUTORIZADO'); end if;
  return jsonb_build_object('ok',true);
end $fn$;

grant execute on function mos.yape_latido(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- El vigilante. Corre cada 20 min y avisa por los equipos que dejaron de latir.
-- Se considera caído a los 45 min sin señal (tres latidos perdidos): un latido
-- suelto se pierde por mala señal todo el tiempo y no significa nada.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.cron_yape_vigilar()
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare d record; v_n int := 0; v_hora int;
begin
  v_hora := extract(hour from (now() at time zone 'America/Lima'))::int;
  -- fuera del horario de trabajo no se avisa: el celular apagado de noche es lo normal
  if v_hora < 7 or v_hora >= 22 then return jsonb_build_object('ok',true,'fueraDeHorario',true); end if;

  for d in
    select * from mos.yape_dispositivos
     where activo
       and ultimo_latido is not null                    -- nunca latió = nunca se instaló
       and ultimo_latido < now() - interval '45 minutes'
       and aviso_caido_ts is null
  loop
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
        'titulo', '📴 Un celular dejó de capturar Yapes',
        'cuerpo', coalesce(d.nombre,'Equipo') || coalesce(' · ' || d.zona, '') ||
                  ' lleva ' || round(extract(epoch from (now() - d.ultimo_latido))/60)::int ||
                  ' min sin dar señal. Los pagos por Yape no se están verificando.',
        'data', jsonb_build_object('tipo','yape_equipo_caido','equipo',d.nombre)));
      update mos.yape_dispositivos set aviso_caido_ts = now() where id = d.id;
      v_n := v_n + 1;
    exception when others then null;   -- avisar nunca puede romper el cron
    end;
  end loop;
  return jsonb_build_object('ok',true,'avisados',v_n);
end $fn$;

select cron.schedule('yape-vigilar', '*/20 * * * *', $cron$ select mos.cron_yape_vigilar() $cron$)
where not exists (select 1 from cron.job where jobname = 'yape-vigilar');

-- ─────────────────────────────────────────────────────────────────────────────
-- Estado de los celulares, para la pestaña de Config.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.yape_dispositivos_estado(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'nombre', d.nombre, 'zona', coalesce(d.zona,''), 'modelo', coalesce(d.modelo,''),
      'activo', d.activo, 'capturas', d.n_capturas, 'pendientes', coalesce(d.pendientes,0),
      'permisoOk', d.permiso_ok,
      'ultimoLatido', to_char(d.ultimo_latido at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
      'minSinLatir', case when d.ultimo_latido is null then null
                          else round(extract(epoch from (now() - d.ultimo_latido))/60)::int end,
      'estado', case when d.ultimo_latido is null then 'NUNCA'
                     when d.ultimo_latido > now() - interval '45 minutes' then 'VIVO'
                     else 'CAIDO' end
    ) order by d.nombre), '[]'::jsonb) into v_out
    from mos.yape_dispositivos d;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('equipos', v_out));
end $fn$;

grant execute on function mos.yape_dispositivos_estado(jsonb) to anon, authenticated, service_role;

commit;
