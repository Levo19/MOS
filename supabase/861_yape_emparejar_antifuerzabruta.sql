-- 861_yape_emparejar_antifuerzabruta.sql
--
-- [DUEÑO] "¿existe algún riesgo?"
--
-- Sí había uno, y este archivo lo cierra. `mos.yape_emparejar` es la ÚNICA puerta que entrega un
-- secreto de dispositivo, y hasta ahora aceptaba intentos ilimitados. Con la clave anon —que es
-- pública, está en el HTML de las tres apps web— cualquiera podía probar códigos de 6 caracteres
-- sin límite. El alfabeto tiene 31 símbolos (sin los que se confunden al leer), así que hay
-- 31^6 ≈ 887 millones de combinaciones y una ventana de 30 minutos: adivinar es impracticable a
-- mano, pero "impracticable" no es lo mismo que "imposible", y esto entrega la llave de un equipo
-- que puede marcar tickets como verificados.
--
-- LA DEFENSA, pensada para que un ataque haga RUIDO en vez de daño:
--   · 40 intentos fallidos en 10 minutos → se MATAN todos los códigos activos y el emparejamiento
--     queda cerrado 15 minutos.
--   · Lo peor que logra un atacante es impedir que se empareje un celular durante un rato — algo
--     que se arregla generando otro código, y que se ve. Nunca obtiene el secreto.
--   · Cada intento fallido queda registrado con su hora, así se puede mirar si alguien probó.

begin;

create table if not exists mos.yape_intentos (
  id       bigserial primary key,
  ts       timestamptz not null default now(),
  codigo   text,          -- el que se intentó (para ver el patrón, no sirve de nada por sí solo)
  ok       boolean not null,
  equipo   text
);
create index if not exists ix_yape_intentos_ts on mos.yape_intentos (ts desc);
alter table mos.yape_intentos enable row level security;

create or replace function mos.yape_emparejar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod   text := upper(regexp_replace(coalesce(p->>'codigo',''), '[^A-Za-z0-9]', '', 'g'));
  v_eq    text := left(coalesce(p->>'equipo',''), 60);
  c       record; d record; v_sec text; v_fallos int;
begin
  -- ── cerrojo anti fuerza bruta ──────────────────────────────────────────────
  select count(*) into v_fallos from mos.yape_intentos
   where not ok and ts > now() - interval '10 minutes';
  if v_fallos >= 40 then
    -- alguien está probando: se queman TODOS los códigos vivos. Que haya que generar otro es
    -- una molestia de diez segundos; entregar un secreto por adivinanza no tiene arreglo.
    update mos.yape_codigos set vence_ts = now() where usado_ts is null and vence_ts > now();
    insert into mos.yape_intentos (codigo, ok, equipo) values (v_cod, false, v_eq);
    return jsonb_build_object('ok',false,'error',
      'Emparejamiento bloqueado por intentos fallidos. Esperá 15 minutos y generá un código nuevo.');
  end if;

  if length(v_cod) <> 6 then
    insert into mos.yape_intentos (codigo, ok, equipo) values (v_cod, false, v_eq);
    return jsonb_build_object('ok',false,'error','El código son 6 caracteres');
  end if;

  select * into c from mos.yape_codigos where codigo = v_cod for update;
  if not found or c.usado_ts is not null or c.vence_ts <= now() then
    insert into mos.yape_intentos (codigo, ok, equipo) values (v_cod, false, v_eq);
    -- mismo mensaje para las tres causas: decir "existe pero venció" le confirmaría a un
    -- atacante que acertó el código, que es justo lo caro de adivinar.
    return jsonb_build_object('ok',false,'error','Código inválido o vencido — generá uno nuevo');
  end if;

  select * into d from mos.yape_dispositivos where id = c.id_dispositivo;
  if not found or not d.activo then
    insert into mos.yape_intentos (codigo, ok, equipo) values (v_cod, false, v_eq);
    return jsonb_build_object('ok',false,'error','Equipo no disponible');
  end if;

  select valor into v_sec from mos.config where clave = 'yape_sec_' || v_cod;
  if coalesce(v_sec,'') = '' then
    insert into mos.yape_intentos (codigo, ok, equipo) values (v_cod, false, v_eq);
    return jsonb_build_object('ok',false,'error','Código inválido o vencido — generá uno nuevo');
  end if;

  update mos.yape_codigos set usado_ts = now(), usado_por = v_eq where codigo = v_cod;
  delete from mos.config where clave = 'yape_sec_' || v_cod;   -- se entrega una sola vez
  insert into mos.yape_intentos (codigo, ok, equipo) values (v_cod, true, v_eq);

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'secreto', v_sec, 'nombre', d.nombre, 'zona', coalesce(d.zona,'')));
end $fn$;

grant execute on function mos.yape_emparejar(jsonb) to anon, authenticated, service_role;

-- que la tabla de intentos no crezca para siempre
create or replace function mos.yape_intentos_purgar()
returns integer language sql security definer set search_path to '' as $fn$
  with d as (delete from mos.yape_intentos where ts < now() - interval '30 days' returning 1)
  select count(*)::int from d;
$fn$;

select cron.schedule('yape-intentos-purgar', '23 4 * * *', $cron$ select mos.yape_intentos_purgar() $cron$)
where not exists (select 1 from cron.job where jobname = 'yape-intentos-purgar');

commit;
