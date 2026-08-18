-- 863: el latido ahora trae la VERSIÓN instalada, y se late cada 10 minutos.
-- Sin la versión no hay forma de saber si un celular quedó atrás con una app vieja — que es
-- justo lo que pasa cuando alguien no actualiza un equipo y ese equipo deja de parsear bien.
alter table mos.yape_dispositivos add column if not exists version_code int;
alter table mos.yape_dispositivos add column if not exists version_name text;

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
         version_code  = coalesce(nullif(p->>'versionCode','')::int, version_code),
         version_name  = coalesce(nullif(btrim(coalesce(p->>'versionName','')),''), version_name),
         aviso_caido_ts = null
   where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex')
   returning id into v_id;
  if v_id is null then return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_AUTORIZADO'); end if;
  return jsonb_build_object('ok',true);
end $fn$;

-- el panel muestra la version y, si hay equipos con distinta, se nota de una
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='mos' and p.proname='yape_dispositivos_estado';
  v_new := replace(v_def,
    $old$      'permisoOk', d.permiso_ok,$old$,
    $old$      'permisoOk', d.permiso_ok,
      'version', coalesce(d.version_name,''), 'versionCode', d.version_code,
      'atrasado', (d.version_code is not null and d.version_code <
                   (select max(x.version_code) from mos.yape_dispositivos x where x.activo)),$old$);
  if v_new = v_def then raise exception '863: no se encontró permisoOk'; end if;
  execute v_new;
end $mig$;

-- 30 min sin latir ya es caida (antes 45; ahora late cada 10, tres perdidos siguen siendo la regla)
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='mos' and p.proname='cron_yape_vigilar';
  v_new := replace(v_def, $old$interval '45 minutes'$old$, $old$interval '30 minutes'$old$);
  if v_new = v_def then raise exception '863: no se encontró el umbral'; end if;
  execute v_new;
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='mos' and p.proname='yape_dispositivos_estado';
  v_new := replace(v_def, $old$interval '45 minutes'$old$, $old$interval '30 minutes'$old$);
  execute v_new;
end $mig$;
