-- 788 · Etiqueta de plataforma correcta por dispositivo (14-ago-2026).
-- Bug: device-auth.js:1336 ponía SIEMPRE 'Mobile '+id al activar sin nombre escrito,
-- sin mirar el user-agent → PCs, tablets e iPhones aparecían como "Mobile" y el dueño
-- no podía distinguir PC de celular en el panel de monitoreo. 64 equipos afectados.
begin;

-- Helper: deriva un nombre legible desde el user-agent. Preserva 6 hex del id para
-- que sigan siendo distinguibles entre sí (mismo formato que el default viejo).
-- Orden CRÍTICO: iPhone/iPad e Android ANTES que Mac/Linux (sus UA contienen esos tokens).
create or replace function mos._label_plataforma(p_ua text, p_id text)
returns text
language sql
immutable
as $function$
  select case
    when p_ua ~* 'iPhone'                             then 'iPhone '
    when p_ua ~* 'iPad'                               then 'iPad '
    when p_ua ~* 'Android' and p_ua ~* 'Mobile'       then 'Móvil '
    when p_ua ~* 'Android'                            then 'Tablet '
    when p_ua ~* 'Windows NT'                         then 'PC '
    when p_ua ~* 'Macintosh|Mac OS X'                 then 'Mac '
    when p_ua ~* 'X11|Linux'                          then 'PC '
    else 'Equipo '
  end || substring(coalesce(p_id,''), 1, 6);
$function$;

-- (1) Backfill de los 64 mal etiquetados. Los sin-UA quedan 'Equipo '+id (honesto:
--     plataforma desconocida) hasta que reconecten con UA y el self-heal (2) los corrija.
update mos.dispositivos
   set nombre_equipo = mos._label_plataforma(user_agent, id_dispositivo)
 where nombre_equipo ~* '^Mobile [0-9a-fA-F]{6}$';   -- SOLO el default viejo (no toca nombres personalizados)

-- (2) Self-heal en el registro: si el nombre guardado es un default genérico
--     (Mobile/Equipo/Móvil/Tablet/PC/Mac/iPhone/iPad + 6 hex) Y llega un UA fresco,
--     lo regenera. Así un equipo sin-UA se corrige solo al reconectar. Un nombre
--     PERSONALIZADO (que no calza el patrón default) JAMÁS se toca.
create or replace function mos._tg_dispositivo_autolabel()
returns trigger
language plpgsql
as $function$
begin
  if coalesce(new.user_agent,'') <> ''
     and (new.nombre_equipo is null
          or new.nombre_equipo ~* '^(Mobile|Equipo|Móvil|Tablet|PC|Mac|iPhone|iPad) [0-9a-fA-F]{6}$') then
    new.nombre_equipo := mos._label_plataforma(new.user_agent, new.id_dispositivo);
  end if;
  return new;
end;
$function$;

drop trigger if exists tg_dispositivo_autolabel on mos.dispositivos;
create trigger tg_dispositivo_autolabel
  before insert or update of user_agent, nombre_equipo on mos.dispositivos
  for each row execute function mos._tg_dispositivo_autolabel();

commit;
