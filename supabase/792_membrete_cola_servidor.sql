-- 792_membrete_cola_servidor.sql — [COLA DE MEMBRETES · por usuario+zona, en el servidor]
-- BUG REPORTADO POR EL DUEÑO (2026-08-15): "veo en mi lista un producto que yo no agregué".
-- CAUSA RAÍZ: la cola vivía SOLO en localStorage con la clave `mos_membrete_cola_<tipo>`
-- (membrete-modal.js) — es decir, por DISPOSITIVO y sin identidad: lo que encolaba un
-- cajero quedaba para el siguiente turno/usuario del mismo equipo (producto fantasma), y
-- el amo y el esclavo nunca compartían cola (cada uno la suya, invisible entre sí).
-- SOLUCIÓN: la cola pasa al servidor keyeada por (tipo, zona, usuario) → el operador ve
-- SOLO lo suyo, y lo agregado desde el amo aparece en el esclavo (y viceversa) en vivo.
-- localStorage queda como caché/offline en el front, ya no como fuente de verdad.

create table if not exists mos.membrete_cola (
  id           bigint generated always as identity primary key,
  tipo         text not null,                       -- MEMBRETE_ME (góndola) | MEMBRETE_WH (andamio)
  zona         text not null default '',
  usuario      text not null default '',
  codigo_barra text not null default '',
  id_producto  text,
  descripcion  text,
  payload      jsonb not null default '{}'::jsonb,  -- el item tal cual lo arma el front
  device       text,
  creado       timestamptz not null default now()
);
-- Un mismo producto no se duplica en la cola de un mismo dueño (re-agregar = refresca).
create unique index if not exists ux_membrete_cola_item
  on mos.membrete_cola (tipo, zona, usuario, codigo_barra);
create index if not exists ix_membrete_cola_owner
  on mos.membrete_cola (tipo, zona, usuario, creado);

alter table mos.membrete_cola enable row level security;   -- solo por RPC (security definer)

-- Realtime: el front se suscribe a los cambios de su cola (amo ↔ esclavo en vivo).
alter table mos.membrete_cola replica identity full;
do $$
begin
  begin
    alter publication supabase_realtime add table mos.membrete_cola;
  exception when duplicate_object then null;
           when undefined_object  then null;   -- sin publication → el front cae a polling
  end;
end $$;

-- ── helpers de identidad (normalizan para que amo/esclavo caigan en la MISMA cola) ──
create or replace function mos._mc_norm(t text) returns text
language sql immutable as $$ select upper(btrim(coalesce(t,''))) $$;

-- ── listar (limpia lazy lo que quedó >7 días: cola olvidada no debe reaparecer) ──
create or replace function mos.membrete_cola_listar(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_tipo text := coalesce(nullif(btrim(p->>'tipo'),''), 'MEMBRETE_ME');
  v_zona text := mos._mc_norm(p->>'zona');
  v_usr  text := mos._mc_norm(p->>'usuario');
  v_items jsonb;
begin
  delete from mos.membrete_cola where creado < now() - interval '7 days';
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'codigoBarra', codigo_barra, 'idProducto', id_producto,
           'descripcion', descripcion, 'payload', payload,
           'creado', to_char(creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')
         ) order by creado), '[]'::jsonb)
    into v_items
    from mos.membrete_cola
   where tipo = v_tipo and zona = v_zona and usuario = v_usr;
  return jsonb_build_object('ok', true, 'tipo', v_tipo, 'zona', v_zona, 'usuario', v_usr,
                            'items', v_items, 'total', jsonb_array_length(v_items));
end;
$$;

-- ── agregar (idempotente por producto; re-agregar solo refresca el payload) ──
create or replace function mos.membrete_cola_agregar(p jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_tipo text := coalesce(nullif(btrim(p->>'tipo'),''), 'MEMBRETE_ME');
  v_zona text := mos._mc_norm(p->>'zona');
  v_usr  text := mos._mc_norm(p->>'usuario');
  v_cb   text := btrim(coalesce(p->>'codigoBarra',''));
  v_id   bigint;
  v_new  boolean;
begin
  if v_usr = '' then return jsonb_build_object('ok', false, 'error', 'Requiere usuario'); end if;
  if v_cb  = '' then return jsonb_build_object('ok', false, 'error', 'Requiere codigoBarra'); end if;

  insert into mos.membrete_cola (tipo, zona, usuario, codigo_barra, id_producto, descripcion, payload, device)
  values (v_tipo, v_zona, v_usr, v_cb, nullif(btrim(coalesce(p->>'idProducto','')),''),
          nullif(btrim(coalesce(p->>'descripcion','')),''),
          coalesce(p->'payload', '{}'::jsonb), nullif(btrim(coalesce(p->>'device','')),''))
  on conflict (tipo, zona, usuario, codigo_barra) do update
     set payload = excluded.payload,
         descripcion = coalesce(excluded.descripcion, mos.membrete_cola.descripcion)
  returning id, (xmax = 0) into v_id, v_new;

  return jsonb_build_object('ok', true, 'id', v_id, 'nuevo', coalesce(v_new,false),
    'total', (select count(*) from mos.membrete_cola where tipo=v_tipo and zona=v_zona and usuario=v_usr));
end;
$$;

-- ── quitar (por id o por código) ──
create or replace function mos.membrete_cola_quitar(p jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_tipo text := coalesce(nullif(btrim(p->>'tipo'),''), 'MEMBRETE_ME');
  v_zona text := mos._mc_norm(p->>'zona');
  v_usr  text := mos._mc_norm(p->>'usuario');
  v_id   bigint := nullif(btrim(coalesce(p->>'id','')),'')::bigint;
  v_cb   text := btrim(coalesce(p->>'codigoBarra',''));
  v_n    int;
begin
  delete from mos.membrete_cola
   where tipo = v_tipo and zona = v_zona and usuario = v_usr
     and ((v_id is not null and id = v_id) or (v_id is null and v_cb <> '' and codigo_barra = v_cb));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0, 'quitados', v_n,
    'total', (select count(*) from mos.membrete_cola where tipo=v_tipo and zona=v_zona and usuario=v_usr));
end;
$$;

-- ── vaciar (lo usa el front al mandar la cola a imprimir) ──
create or replace function mos.membrete_cola_vaciar(p jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_tipo text := coalesce(nullif(btrim(p->>'tipo'),''), 'MEMBRETE_ME');
  v_zona text := mos._mc_norm(p->>'zona');
  v_usr  text := mos._mc_norm(p->>'usuario');
  v_n    int;
begin
  delete from mos.membrete_cola where tipo = v_tipo and zona = v_zona and usuario = v_usr;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'quitados', v_n, 'total', 0);
end;
$$;

grant execute on function mos.membrete_cola_listar(jsonb)  to anon, authenticated, service_role;
grant execute on function mos.membrete_cola_agregar(jsonb) to anon, authenticated, service_role;
grant execute on function mos.membrete_cola_quitar(jsonb)  to anon, authenticated, service_role;
grant execute on function mos.membrete_cola_vaciar(jsonb)  to anon, authenticated, service_role;
grant select on mos.membrete_cola to anon, authenticated, service_role;   -- realtime lee la tabla
