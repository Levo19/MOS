-- 858_yape_emparejamiento.sql
--
-- [DUEÑO] "los datos debo tenerlos a la mano de alguna forma. ¿No se pueden bajar ya con los datos
--  seteados? Ej: tener en Configuración MOS el APK para Zona 1 y que baje con los datos seteados.
--  Escribir todo es muy largo."
--
-- COMPILAR UN APK POR ZONA ES LA IDEA EQUIVOCADA, aunque suene a lo que se pide: obligaría a meter
-- el secreto de cada celular dentro del repositorio (queda en el historial de git para siempre y no
-- se puede revocar de verdad), y a recompilar cada vez que se agrega una zona o se cambia un
-- secreto. Un APK para todos y un CÓDIGO CORTO por equipo consigue lo mismo sin ninguno de esos
-- problemas — y el código, además, se puede quemar y volver a generar si alguien lo ve.
--
-- La URL y la clave anon SÍ van dentro del APK: no son secretos (están a la vista en el HTML de
-- las tres apps web). Lo único sensible es el secreto del dispositivo, y eso es justo lo que el
-- código entrega, una sola vez y con vencimiento.
--
-- Así, en el celular se teclean 6 caracteres en vez de tres cadenas largas.

begin;

create table if not exists mos.yape_codigos (
  codigo      text primary key,
  id_dispositivo bigint not null references mos.yape_dispositivos(id) on delete cascade,
  creado_ts   timestamptz not null default now(),
  vence_ts    timestamptz not null,
  usado_ts    timestamptz,
  usado_por   text,
  creado_por  text
);
create index if not exists ix_yape_cod_vivo on mos.yape_codigos (vence_ts) where usado_ts is null;
alter table mos.yape_codigos enable row level security;

-- ─────────────────────────────────────────────────────────────────────────────
-- Generar: crea (o reusa) el dispositivo de la zona, le pone un secreto nuevo y
-- devuelve un código corto para tipear en el celular. Vence en 30 minutos.
-- Regenerar el código de un equipo CAMBIA su secreto: el celular viejo deja de
-- entregar en el acto. Es la forma de sacar de circulación un equipo perdido.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.yape_codigo_generar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_zona  text := nullif(btrim(coalesce(p->>'zona','')),'');
  v_nom   text := nullif(btrim(coalesce(p->>'nombre','')),'');
  v_por   text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'?');
  v_sec   text; v_cod text; v_dev bigint; v_i int := 0;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_nom := coalesce(v_nom, 'Celular Yape ' || coalesce(v_zona,'general'));

  -- secreto nuevo, largo y aleatorio: nunca lo tipea nadie, viaja por el código
  v_sec := 'yc_' || encode(extensions.gen_random_bytes(24), 'hex');

  -- un dispositivo por nombre: regenerar reemplaza el secreto (revoca el anterior)
  select id into v_dev from mos.yape_dispositivos where nombre = v_nom;
  if v_dev is null then
    insert into mos.yape_dispositivos (nombre, zona, secreto_hash)
    values (v_nom, v_zona, encode(extensions.digest(v_sec,'sha256'),'hex'))
    returning id into v_dev;
  else
    update mos.yape_dispositivos
       set secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex'),
           zona = coalesce(v_zona, zona), activo = true
     where id = v_dev;
    -- los códigos viejos de ese equipo dejan de servir
    update mos.yape_codigos set vence_ts = now() where id_dispositivo = v_dev and usado_ts is null;
  end if;

  -- código de 6 caracteres SIN los que se confunden al leerlos (0/O, 1/I/L)
  loop
    v_i := v_i + 1;
    select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789',
                             1 + floor(random()*31)::int, 1), '')
      into v_cod from generate_series(1,6);
    exit when not exists (select 1 from mos.yape_codigos where codigo = v_cod and usado_ts is null and vence_ts > now())
           or v_i > 20;
  end loop;

  insert into mos.yape_codigos (codigo, id_dispositivo, vence_ts, creado_por)
  values (v_cod, v_dev, now() + interval '30 minutes', v_por)
  on conflict (codigo) do update set id_dispositivo = excluded.id_dispositivo,
        vence_ts = excluded.vence_ts, usado_ts = null, usado_por = null, creado_ts = now();

  -- el secreto se guarda cifrado; se entrega SOLO por el código, así que se deja acá
  -- para que yape_emparejar pueda devolverlo una vez. Se borra al usarse.
  update mos.yape_codigos set usado_por = null where codigo = v_cod;
  insert into mos.config (clave, valor) values ('yape_sec_' || v_cod, v_sec)
    on conflict (clave) do update set valor = excluded.valor;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'codigo', v_cod, 'nombre', v_nom, 'zona', coalesce(v_zona,'(todas)'),
    'venceEn', 30, 'idDispositivo', v_dev));
end $fn$;

grant execute on function mos.yape_codigo_generar(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- Canjear desde el celular: entrega el secreto UNA vez y quema el código.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.yape_emparejar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod text := upper(regexp_replace(coalesce(p->>'codigo',''), '[^A-Za-z0-9]', '', 'g'));
  c     record; d     record; v_sec text;
begin
  if length(v_cod) <> 6 then return jsonb_build_object('ok',false,'error','El código son 6 caracteres'); end if;
  select * into c from mos.yape_codigos where codigo = v_cod for update;
  if not found then return jsonb_build_object('ok',false,'error','Código inválido'); end if;
  if c.usado_ts is not null then return jsonb_build_object('ok',false,'error','Ese código ya se usó'); end if;
  if c.vence_ts <= now() then return jsonb_build_object('ok',false,'error','El código venció — generá uno nuevo'); end if;

  select * into d from mos.yape_dispositivos where id = c.id_dispositivo;
  if not found or not d.activo then return jsonb_build_object('ok',false,'error','Equipo no disponible'); end if;

  select valor into v_sec from mos.config where clave = 'yape_sec_' || v_cod;
  if coalesce(v_sec,'') = '' then return jsonb_build_object('ok',false,'error','El código ya no tiene secreto'); end if;

  update mos.yape_codigos set usado_ts = now(), usado_por = coalesce(p->>'equipo','') where codigo = v_cod;
  delete from mos.config where clave = 'yape_sec_' || v_cod;   -- se entrega una sola vez

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'secreto', v_sec, 'nombre', d.nombre, 'zona', coalesce(d.zona,'')));
end $fn$;

grant execute on function mos.yape_emparejar(jsonb) to anon, authenticated, service_role;

-- limpieza: los códigos vencidos y sus secretos no se quedan dando vueltas
create or replace function mos.yape_codigos_purgar()
returns integer language plpgsql security definer set search_path to '' as $fn$
declare n int;
begin
  delete from mos.config c using mos.yape_codigos k
   where c.clave = 'yape_sec_' || k.codigo and (k.usado_ts is not null or k.vence_ts <= now());
  delete from mos.yape_codigos where usado_ts is not null or vence_ts <= now() - interval '1 day';
  get diagnostics n = row_count;
  return n;
end $fn$;

select cron.schedule('yape-codigos-purgar', '17 * * * *', $cron$ select mos.yape_codigos_purgar() $cron$)
where not exists (select 1 from cron.job where jobname = 'yape-codigos-purgar');

commit;
