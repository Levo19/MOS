-- 407 · Portal cliente WH → 100% Supabase (reemplaza ClientePortal.gs + hojas Clientes/PedidosCliente*).
-- Incremento 1: esquema + siembra (2 clientes reales del Sheet) + RPCs que NO necesitan IA
-- (info/registrar/listar/estado/inbox/confirmar). El recibir-pedido con IA va en una Edge aparte (incremento 2).
-- INERTE hasta el rewire del frontend: el portal GAS sigue operando hasta entonces.

-- ── Tablas ──────────────────────────────────────────────────────────────────
create table if not exists wh.clientes_portal (
  token         text primary key,
  nombre        text not null default '',
  telefono      text not null default '',
  tipo          text not null default 'minorista',
  premium       boolean not null default false,
  fecha_alta    timestamptz not null default now(),
  ultimo_pedido timestamptz
);
create table if not exists wh.pedidos_cliente (
  id_pedido       text primary key,
  token           text not null default 'ANON',
  ts              timestamptz not null default now(),
  estado          text not null default 'PREVIEW',   -- PREVIEW|CONFIRMADO|EN_DESPACHO|LISTO|EN_CAMINO|ENTREGADO
  id_lista_sombra text not null default '',
  total_estimado  numeric not null default 0,
  notas           text not null default ''
);
create index if not exists ix_pedcli_ts on wh.pedidos_cliente (ts desc);
create index if not exists ix_pedcli_token on wh.pedidos_cliente (token);
create table if not exists wh.pedidos_cliente_items (
  id_pedido text not null,
  idx       int  not null,
  nombre    text not null default '',
  cantidad  numeric not null default 0,
  unidad    text not null default 'unidad',
  precio_est numeric not null default 0,
  duda      text not null default '',
  primary key (id_pedido, idx)
);
create table if not exists wh.pedidos_cliente_adj (
  id_pedido text not null,
  idx       int  not null default 0,
  tipo      text not null default '',
  nombre_archivo text not null default '',
  url       text not null default '',
  ts        timestamptz not null default now(),
  primary key (id_pedido, idx)
);
alter table wh.clientes_portal        enable row level security;
alter table wh.pedidos_cliente         enable row level security;
alter table wh.pedidos_cliente_items   enable row level security;
alter table wh.pedidos_cliente_adj     enable row level security;

-- ── Siembra: los 2 clientes que había en la hoja Clientes (uno es de prueba, se conserva idéntico). ──
insert into wh.clientes_portal (token, nombre, telefono, tipo, premium, fecha_alta) values
  ('TESTSMOK126', 'Test Smoke', '',            'minorista', false, '2026-05-22 20:32:40-05'),
  ('JUANDIEG279', 'JuanDiego',  '51914639308', 'minorista', false, '2026-05-22 20:50:18-05')
on conflict (token) do nothing;

-- Helper de gate admin (reusa la validación global de clave que ya usa el ecosistema).
create or replace function wh._portal_admin_ok(p jsonb)
returns boolean language plpgsql stable security definer set search_path='' as $fn$
declare v_clave text := btrim(coalesce(p->>'claveAdmin', p->>'clave', ''));
begin
  if v_clave = '' then return false; end if;
  begin
    return coalesce((mos.verificar_clave_admin_p(jsonb_build_object('clave', v_clave, 'accion', 'portal_cliente'))->>'autorizado')::boolean, false);
  exception when others then return false; end;
end; $fn$;

-- ── 1) cliente_info(token) — público (anon). Nombre bonito por token; no expone teléfono de otros. ──
create or replace function wh.cliente_info(p jsonb)
returns jsonb language sql stable security definer set search_path='' as $fn$
  select case
    when nullif(btrim(upper(coalesce(p->>'token',''))),'') is null
      then jsonb_build_object('ok',true,'data',jsonb_build_object('token','','nombre','Cliente','existe',false))
    else coalesce((
      select jsonb_build_object('ok',true,'data',jsonb_build_object(
        'token', c.token, 'nombre', c.nombre, 'tipo', c.tipo, 'premium', c.premium, 'existe', true))
      from wh.clientes_portal c where c.token = btrim(upper(p->>'token'))
    ), jsonb_build_object('ok',true,'data',jsonb_build_object('token',btrim(upper(p->>'token')),'nombre','Cliente','existe',false)))
  end;
$fn$;

-- ── 2) cliente_registrar — alta/edición. Auto-alta silenciosa (anon) O edición admin (con clave). ──
create or replace function wh.cliente_registrar(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_token text := nullif(btrim(upper(coalesce(p->>'token',''))),'');
  v_nombre text := btrim(coalesce(p->>'nombre',''));
  v_edicion boolean := coalesce((p->>'edicion')::boolean, false);
begin
  -- La edición de datos (nombre/teléfono/tipo/premium) desde el modal admin exige clave; la auto-alta no.
  if v_edicion and not wh._portal_admin_ok(p) then return jsonb_build_object('ok',false,'error','clave admin requerida'); end if;
  if v_token is null then
    -- generar token desde el nombre (slug + 3 dígitos), como el GAS
    v_token := regexp_replace(upper(translate(coalesce(v_nombre,'CLI'),'ÁÉÍÓÚÜÑáéíóúüñ','AEIOUUNAEIOUUN')),'[^A-Z0-9]','','g');
    v_token := left(nullif(v_token,''), 8);
    if v_token is null or v_token='' then v_token := 'CLI'; end if;
    v_token := v_token || lpad(((floor(random()*900)+100))::int::text,3,'0');
  end if;
  insert into wh.clientes_portal (token, nombre, telefono, tipo, premium)
  values (v_token, coalesce(nullif(v_nombre,''), v_token),
          btrim(coalesce(p->>'telefono','')), coalesce(nullif(btrim(p->>'tipo'),''),'minorista'),
          coalesce((p->>'premium')::boolean,false))
  on conflict (token) do update set
    nombre   = case when v_edicion then excluded.nombre else wh.clientes_portal.nombre end,
    telefono = case when v_edicion then excluded.telefono else wh.clientes_portal.telefono end,
    tipo     = case when v_edicion then excluded.tipo else wh.clientes_portal.tipo end,
    premium  = case when v_edicion then excluded.premium else wh.clientes_portal.premium end;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('token',v_token,'nombre',coalesce(nullif(v_nombre,''),v_token)));
end; $fn$;

-- ── 3) cliente_listar — SOLO admin (PII: nombre+teléfono). ──
create or replace function wh.cliente_listar(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
begin
  if not wh._portal_admin_ok(p) then return jsonb_build_object('ok',false,'error','clave admin requerida'); end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'total', (select count(*) from wh.clientes_portal),
    'clientes', coalesce((select jsonb_agg(jsonb_build_object(
      'token',c.token,'nombre',c.nombre,'telefono',c.telefono,'tipo',c.tipo,
      'premium',c.premium,'fechaAlta',c.fecha_alta,'ultimoPedido',c.ultimo_pedido) order by c.fecha_alta desc)
      from wh.clientes_portal c), '[]'::jsonb)));
end; $fn$;

-- ── 4) cliente_estado_pedido — timeline con IDOR guard (token del request == dueño del pedido). ──
create or replace function wh.cliente_estado_pedido(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idPedido','')),'');
  v_tokreq text := coalesce(nullif(btrim(upper(coalesce(p->>'token',''))),''),'ANON');
  v_estado text; v_tok text; v_pasos jsonb; v_idx int; v_timeline text[] := array['Recibido','Cotizando','Despachando','Listo','En camino'];
  v_map jsonb := '{"PREVIEW":0,"CONFIRMADO":1,"EN_DESPACHO":2,"LISTO":3,"EN_CAMINO":4,"ENTREGADO":5}'::jsonb;
  i int;
begin
  if v_id is null then return jsonb_build_object('ok',false,'error','PEDIDO_NO_ENCONTRADO'); end if;
  select estado, token into v_estado, v_tok from wh.pedidos_cliente where id_pedido = v_id;
  if v_estado is null or coalesce(upper(v_tok),'ANON') <> v_tokreq then
    return jsonb_build_object('ok',false,'error','PEDIDO_NO_ENCONTRADO');
  end if;
  v_idx := coalesce((v_map->>v_estado)::int, 0);
  v_pasos := '[]'::jsonb;
  for i in 1..array_length(v_timeline,1) loop
    v_pasos := v_pasos || jsonb_build_object('paso', v_timeline[i], 'done', (i-1) < v_idx, 'now', (i-1) = v_idx);
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPedido',v_id,'estado',v_estado,'timeline',v_pasos));
end; $fn$;

-- ── 5) cliente_inbox_polling — WH consulta pedidos CONFIRMADOS nuevos (desde ts). ──
create or replace function wh.cliente_inbox_polling(p jsonb)
returns jsonb language sql stable security definer set search_path='' as $fn$
  select jsonb_build_object('ok',true,'data',jsonb_build_object(
    'ahora', (extract(epoch from now())*1000)::bigint,
    'nuevos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'idPedido', pc.id_pedido, 'cliente', coalesce(c.nombre, pc.token), 'token', pc.token,
        'items', (select count(*) from wh.pedidos_cliente_items i where i.id_pedido = pc.id_pedido),
        'idListaSombra', pc.id_lista_sombra,
        'ts', (extract(epoch from pc.ts)*1000)::bigint) order by pc.ts desc)
      from wh.pedidos_cliente pc left join wh.clientes_portal c on c.token = pc.token
      where pc.estado <> 'PREVIEW'
        and (extract(epoch from pc.ts)*1000)::bigint > coalesce((p->>'desde')::bigint, 0)
      limit 20), '[]'::jsonb)));
$fn$;

-- ── 6) cliente_confirmar_pedido — crea la lista sombra real (wh.crear_lista_sombra) + marca CONFIRMADO. ──
create or replace function wh.cliente_confirmar_pedido(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idPedido','')),'');
  v_tokreq text := coalesce(nullif(btrim(upper(coalesce(p->>'token',''))),''),'ANON');
  v_tok text; v_nombre text; v_items jsonb := coalesce(p->'items','[]'::jsonb); v_ls text := '';
  v_lsres jsonb;
begin
  if v_id is null then return jsonb_build_object('ok',false,'error','ID_FALTANTE'); end if;
  select token into v_tok from wh.pedidos_cliente where id_pedido = v_id;
  if v_tok is null or coalesce(upper(v_tok),'ANON') <> v_tokreq then
    return jsonb_build_object('ok',false,'error','PEDIDO_NO_ENCONTRADO');
  end if;
  select nombre into v_nombre from wh.clientes_portal where token = v_tok;
  v_nombre := coalesce(v_nombre, v_tok);
  -- [elevación de claim transaction-local] El portal es público (anon, sin claim app). wh.crear_lista_sombra gatea
  --   con wh._claim_ok() (exige warehouseMos). Elevamos el claim SOLO dentro de esta tx para que la creación de la
  --   lista sombra (operación legítima del almacén) autorice, sin ampliar el gate de la función core. Mismo patrón
  --   que el corte-GAS (anular/registrar-guia ME). Se revierte al terminar la transacción.
  perform set_config('request.jwt.claims', '{"app":"warehouseMos"}', true);
  -- Crear lista sombra (compartida) reusando la RPC existente. Tolerante: si falla, igual confirmamos.
  begin
    v_lsres := wh.crear_lista_sombra(jsonb_build_object(
      'usuario', 'Cliente: ' || v_nombre,
      'idLista', 'LSCLI' || substr(v_id, 3),
      'items', v_items,
      'compartir', true,
      'nota', 'Pedido portal cliente — ' || v_nombre || ' (' || v_tok || ') · #' || v_id));
    v_ls := coalesce(v_lsres->'data'->>'idLista', v_lsres->>'idLista', '');
  exception when others then v_ls := ''; end;
  update wh.pedidos_cliente set estado='CONFIRMADO', id_lista_sombra=v_ls where id_pedido = v_id;
  update wh.clientes_portal set ultimo_pedido = now() where token = v_tok;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPedido',v_id,'idListaSombra',v_ls,'eta',25));
end; $fn$;

grant execute on function wh._portal_admin_ok(jsonb)          to authenticated, service_role, anon;
grant execute on function wh.cliente_info(jsonb)              to authenticated, service_role, anon;
grant execute on function wh.cliente_registrar(jsonb)         to authenticated, service_role, anon;
grant execute on function wh.cliente_listar(jsonb)            to authenticated, service_role, anon;
grant execute on function wh.cliente_estado_pedido(jsonb)     to authenticated, service_role, anon;
grant execute on function wh.cliente_inbox_polling(jsonb)     to authenticated, service_role, anon;
grant execute on function wh.cliente_confirmar_pedido(jsonb)  to authenticated, service_role, anon;
