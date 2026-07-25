-- ════════════════════════════════════════════════════════════════════
-- 547 — MosGo Fase 0: schema ruta.* + canal mayoreo en catálogo + RPCs
-- POS mayorista de preventa en ruta (solo admins, app 'mosGo').
-- Diseño: artifact 2ded160c · decisiones cerradas 22-jul-2026.
-- Ciclo Fase 0 (sin pickup WH todavía — llega en Fase 1):
--   CONFIRMADO → ENTREGADO → COBRADO/PARCIAL → RENDIDO → VERIFICADO · ANULADO
-- Comisión: % sobre venta COBRADA (ruta.config comision_pct), se congela en el pedido.
-- ════════════════════════════════════════════════════════════════════

create schema if not exists ruta;

-- ── catálogo: canal mayorista ──
alter table mos.productos add column if not exists canal_mayoreo boolean not null default false;
alter table mos.productos add column if not exists tramos_mayoreo jsonb;

-- ── tablas ──
create table if not exists ruta.clientes_ext (
  documento         text primary key,
  nombre            text not null default '',
  tipo_negocio      text not null default '',
  direccion_entrega text not null default '',
  referencia        text not null default '',
  telefono_wsp      text not null default '',
  dia_visita        text not null default '',
  notas             text not null default '',
  creado_por        text not null default '',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create sequence if not exists ruta.seq_pedido;
create sequence if not exists ruta.seq_rendicion;

create table if not exists ruta.pedidos (
  id_pedido         text primary key,
  local_id          text unique,
  documento_cliente text not null default '',
  nombre_cliente    text not null default '',
  vendedor          text not null,
  id_vendedor       bigint,
  estado            text not null default 'CONFIRMADO',
  items             jsonb not null default '[]'::jsonb,
  total             numeric(12,2) not null default 0,
  ahorro_total      numeric(12,2) not null default 0,
  fecha_entrega     date,
  nota              text not null default '',
  id_pickup         text, id_guia text, id_venta text, id_rendicion text,
  comision_pct      numeric(6,3),
  comision_monto    numeric(12,2),
  ts_entregado      timestamptz,
  ts_cobrado        timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint ruta_pedidos_estado_chk check (estado in
    ('CONFIRMADO','EN_PREPARACION','DESPACHADO','ENTREGADO','PARCIAL','COBRADO','RENDIDO','VERIFICADO','ANULADO'))
);
create index if not exists ruta_pedidos_estado_idx on ruta.pedidos (estado);
create index if not exists ruta_pedidos_vendedor_idx on ruta.pedidos (vendedor);
create index if not exists ruta_pedidos_created_idx on ruta.pedidos (created_at desc);

create table if not exists ruta.cobros (
  id_cobro       bigint generated always as identity primary key,
  local_id       text unique,
  id_pedido      text not null references ruta.pedidos(id_pedido),
  metodo         text not null check (metodo in ('EFECTIVO','YAPE','PLIN','TRANSF')),
  monto          numeric(12,2) not null check (monto > 0),
  foto_url       text not null default '',
  registrado_por text not null default '',
  created_at     timestamptz not null default now()
);
create index if not exists ruta_cobros_pedido_idx on ruta.cobros (id_pedido);

create table if not exists ruta.rendiciones (
  id_rendicion   text primary key,
  local_id       text unique,
  vendedor       text not null,
  tickets        jsonb not null default '[]'::jsonb,
  sum_virtual    numeric(12,2) not null default 0,
  sum_efectivo   numeric(12,2) not null default 0,
  desglose       jsonb not null default '{}'::jsonb,
  estado         text not null default 'ENVIADA' check (estado in ('ENVIADA','VERIFICADA')),
  verificado_por text not null default '',
  ts_verificada  timestamptz,
  created_at     timestamptz not null default now()
);

create table if not exists ruta.producto_rel (
  sku      text not null,
  sku_rel  text not null,
  tipo     text not null default 'COMPLEMENTO' check (tipo in ('SUSTITUTO','COMPLEMENTO')),
  peso     int  not null default 1,
  primary key (sku, sku_rel, tipo)
);

create table if not exists ruta.config (k text primary key, v jsonb not null);
insert into ruta.config (k, v) values ('comision_pct', '3'::jsonb) on conflict (k) do nothing;

-- ════════════════════════════════════════════════════════════════════
-- RPCs (en schema mos = ya expuesto por REST anon; convención p jsonb)
-- ════════════════════════════════════════════════════════════════════

-- ── boot: catálogo mayoreo + clientes + config ──
create or replace function mos.ruta_boot(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_prods jsonb; v_clis jsonb; v_pct numeric;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'codigo_barra', pr.codigo_barra, 'descripcion', pr.descripcion,
    'unidad', coalesce(pr.unidad,'NIU'), 'precio_venta', pr.precio_venta,
    'tramos', coalesce(pr.tramos_mayoreo,'[]'::jsonb),
    'stock', coalesce(s.cantidad_disponible,0)
  ) order by pr.descripcion), '[]'::jsonb) into v_prods
  from mos.productos pr
  left join wh.stock s on s.cod_producto = pr.codigo_barra
  where pr.estado = true and pr.canal_mayoreo = true;

  select coalesce(jsonb_agg(jsonb_build_object(
    'documento', cf.documento, 'nombre', cf.nombre, 'tipo_doc', cf.tipo_doc,
    'direccion', coalesce(cf.direccion,''),
    'tipo_negocio', coalesce(ce.tipo_negocio,''), 'direccion_entrega', coalesce(ce.direccion_entrega,''),
    'telefono_wsp', coalesce(ce.telefono_wsp,''), 'dia_visita', coalesce(ce.dia_visita,''),
    'notas', coalesce(ce.notas,'')
  ) order by cf.nombre), '[]'::jsonb) into v_clis
  from me.clientes_frecuentes cf
  left join ruta.clientes_ext ce on ce.documento = cf.documento;

  select (v)::text::numeric into v_pct from ruta.config where k = 'comision_pct';
  return jsonb_build_object('ok', true, 'productos', v_prods, 'clientes', v_clis,
    'comision_pct', coalesce(v_pct, 3));
end; $$;

-- ── clientes: upsert extensión de ruta (y alta en frecuentes si no existe) ──
create or replace function mos.ruta_cliente_guardar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_doc text := btrim(coalesce(p->>'documento',''));
begin
  if v_doc = '' then return jsonb_build_object('ok', false, 'error', 'documento requerido'); end if;
  insert into me.clientes_frecuentes (documento, nombre, tipo_doc, direccion)
  values (v_doc, coalesce(p->>'nombre',''), coalesce(p->>'tipo_doc', case when length(v_doc)=11 then 'RUC' else 'DNI' end),
          coalesce(p->>'direccion',''))
  on conflict (documento) do update set
    nombre = case when coalesce(excluded.nombre,'') <> '' then excluded.nombre else me.clientes_frecuentes.nombre end,
    direccion = case when coalesce(excluded.direccion,'') <> '' then excluded.direccion else me.clientes_frecuentes.direccion end;
  insert into ruta.clientes_ext (documento, nombre, tipo_negocio, direccion_entrega, referencia, telefono_wsp, dia_visita, notas, creado_por)
  values (v_doc, coalesce(p->>'nombre',''), coalesce(p->>'tipo_negocio',''), coalesce(p->>'direccion_entrega',''),
          coalesce(p->>'referencia',''), coalesce(p->>'telefono_wsp',''), coalesce(p->>'dia_visita',''),
          coalesce(p->>'notas',''), coalesce(p->>'actor',''))
  on conflict (documento) do update set
    nombre = excluded.nombre, tipo_negocio = excluded.tipo_negocio,
    direccion_entrega = excluded.direccion_entrega, referencia = excluded.referencia,
    telefono_wsp = excluded.telefono_wsp, dia_visita = excluded.dia_visita,
    notas = excluded.notas, updated_at = now();
  return jsonb_build_object('ok', true, 'documento', v_doc);
end; $$;

-- ── crear pedido (idempotente por local_id; backend RECALCULA todo el dinero) ──
create or replace function mos.ruta_pedido_crear(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_local text := btrim(coalesce(p->>'local_id',''));
  v_vend  text := btrim(coalesce(p->>'vendedor',''));
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_it jsonb; v_total numeric := 0; v_ahorro numeric := 0;
  v_cant numeric; v_pu numeric; v_sub numeric; v_unit numeric;
  v_clean jsonb := '[]'::jsonb; v_id text; v_ex ruta.pedidos%rowtype;
begin
  if v_local = '' or v_vend = '' then return jsonb_build_object('ok', false, 'error', 'local_id y vendedor requeridos'); end if;
  if jsonb_array_length(v_items) = 0 then return jsonb_build_object('ok', false, 'error', 'pedido vacío'); end if;

  select * into v_ex from ruta.pedidos where local_id = v_local;
  if found then
    return jsonb_build_object('ok', true, 'id_pedido', v_ex.id_pedido, 'estado', v_ex.estado,
      'total', v_ex.total, 'dedup', true);
  end if;

  for v_it in select * from jsonb_array_elements(v_items) loop
    v_cant := coalesce((v_it->>'cant')::numeric, 0);
    v_pu   := coalesce((v_it->>'precio_unit')::numeric, 0);
    if v_cant <= 0 or v_pu <= 0 then return jsonb_build_object('ok', false, 'error', 'item inválido: ' || coalesce(v_it->>'codigo_barra','?')); end if;
    v_sub := round(v_cant * v_pu, 2);
    select precio_venta into v_unit from mos.productos where codigo_barra = v_it->>'codigo_barra';
    v_total  := round(v_total + v_sub, 2);
    v_ahorro := round(v_ahorro + greatest(0, round(v_cant * coalesce(v_unit, v_pu), 2) - v_sub), 2);
    v_clean := v_clean || jsonb_build_object(
      'codigo_barra', v_it->>'codigo_barra', 'descripcion', coalesce(v_it->>'descripcion',''),
      'cant', v_cant, 'precio_unit', v_pu, 'subtotal', v_sub,
      'tramo', coalesce(v_it->>'tramo',''));
  end loop;

  v_id := 'R-' || lpad(nextval('ruta.seq_pedido')::text, 4, '0');
  insert into ruta.pedidos (id_pedido, local_id, documento_cliente, nombre_cliente, vendedor, id_vendedor,
    items, total, ahorro_total, fecha_entrega, nota)
  values (v_id, v_local, coalesce(p->>'documento_cliente',''), coalesce(p->>'nombre_cliente',''),
    v_vend, nullif(p->>'id_vendedor','')::bigint, v_clean, v_total, v_ahorro,
    nullif(p->>'fecha_entrega','')::date, coalesce(p->>'nota',''))
  on conflict (local_id) do nothing;
  return jsonb_build_object('ok', true, 'id_pedido', v_id, 'estado', 'CONFIRMADO', 'total', v_total, 'ahorro', v_ahorro);
end; $$;

-- ── listar pedidos (todos los vendedores ven todo) ──
create or replace function mos.ruta_pedidos_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v jsonb;
begin
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) into v from (
    select to_jsonb(pd) || jsonb_build_object(
      'pagado', coalesce((select round(sum(c.monto),2) from ruta.cobros c where c.id_pedido = pd.id_pedido), 0),
      'cobros', coalesce((select jsonb_agg(jsonb_build_object('metodo', c.metodo, 'monto', c.monto, 'ts', c.created_at) order by c.id_cobro)
                          from ruta.cobros c where c.id_pedido = pd.id_pedido), '[]'::jsonb)
    ) x
    from ruta.pedidos pd order by pd.created_at desc limit 300
  ) q;
  return jsonb_build_object('ok', true, 'pedidos', v);
end; $$;

-- ── marcar entregado ──
create or replace function mos.ruta_pedido_entregar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_id text := coalesce(p->>'id_pedido',''); v_est text;
begin
  select estado into v_est from ruta.pedidos where id_pedido = v_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'pedido no existe'); end if;
  if v_est in ('ENTREGADO','PARCIAL','COBRADO','RENDIDO','VERIFICADO') then
    return jsonb_build_object('ok', true, 'estado', v_est, 'dedup', true);
  end if;
  if v_est = 'ANULADO' then return jsonb_build_object('ok', false, 'error', 'pedido anulado'); end if;
  update ruta.pedidos set estado = 'ENTREGADO', ts_entregado = now(), updated_at = now() where id_pedido = v_id;
  return jsonb_build_object('ok', true, 'estado', 'ENTREGADO');
end; $$;

-- ── anular (solo antes de entregar) ──
create or replace function mos.ruta_pedido_anular(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_id text := coalesce(p->>'id_pedido',''); v_est text;
begin
  select estado into v_est from ruta.pedidos where id_pedido = v_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'pedido no existe'); end if;
  if v_est = 'ANULADO' then return jsonb_build_object('ok', true, 'estado', 'ANULADO', 'dedup', true); end if;
  if v_est not in ('CONFIRMADO','EN_PREPARACION') then
    return jsonb_build_object('ok', false, 'error', 'solo se anula antes de entregar (está ' || v_est || ')');
  end if;
  update ruta.pedidos set estado = 'ANULADO', updated_at = now() where id_pedido = v_id;
  return jsonb_build_object('ok', true, 'estado', 'ANULADO');
end; $$;

-- ── registrar cobro (parcial ok; al completar → COBRADO + comisión congelada) ──
create or replace function mos.ruta_cobro_registrar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_local text := btrim(coalesce(p->>'local_id',''));
  v_id text := coalesce(p->>'id_pedido',''); v_met text := coalesce(p->>'metodo','');
  v_monto numeric := round(coalesce((p->>'monto')::numeric, 0), 2);
  v_ped ruta.pedidos%rowtype; v_pagado numeric; v_pct numeric;
begin
  if v_local = '' then return jsonb_build_object('ok', false, 'error', 'local_id requerido'); end if;
  if exists (select 1 from ruta.cobros where local_id = v_local) then
    select coalesce(round(sum(monto),2),0) into v_pagado from ruta.cobros where id_pedido = v_id;
    select estado into v_ped.estado from ruta.pedidos where id_pedido = v_id;
    return jsonb_build_object('ok', true, 'dedup', true, 'estado', v_ped.estado, 'pagado', v_pagado);
  end if;
  select * into v_ped from ruta.pedidos where id_pedido = v_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'pedido no existe'); end if;
  if v_ped.estado in ('COBRADO','RENDIDO','VERIFICADO') then return jsonb_build_object('ok', false, 'error', 'ya está cobrado'); end if;
  if v_ped.estado = 'ANULADO' then return jsonb_build_object('ok', false, 'error', 'pedido anulado'); end if;
  if v_monto <= 0 then return jsonb_build_object('ok', false, 'error', 'monto inválido'); end if;

  select coalesce(round(sum(monto),2),0) into v_pagado from ruta.cobros where id_pedido = v_id;
  if round(v_pagado + v_monto, 2) > v_ped.total then
    return jsonb_build_object('ok', false, 'error', 'excede el total: pagado ' || v_pagado || ' + ' || v_monto || ' > ' || v_ped.total);
  end if;

  insert into ruta.cobros (local_id, id_pedido, metodo, monto, foto_url, registrado_por)
  values (v_local, v_id, v_met, v_monto, coalesce(p->>'foto_url',''), coalesce(p->>'actor',''));
  v_pagado := round(v_pagado + v_monto, 2);

  if v_pagado >= v_ped.total then
    select (v)::text::numeric into v_pct from ruta.config where k = 'comision_pct';
    v_pct := coalesce(v_pct, 3);
    update ruta.pedidos set estado = 'COBRADO', ts_cobrado = now(), ts_entregado = coalesce(ts_entregado, now()),
      comision_pct = v_pct, comision_monto = round(total * v_pct / 100, 2), updated_at = now()
    where id_pedido = v_id;
    return jsonb_build_object('ok', true, 'estado', 'COBRADO', 'pagado', v_pagado,
      'comision', round(v_ped.total * v_pct / 100, 2));
  else
    update ruta.pedidos set estado = 'PARCIAL', ts_entregado = coalesce(ts_entregado, now()), updated_at = now() where id_pedido = v_id;
    return jsonb_build_object('ok', true, 'estado', 'PARCIAL', 'pagado', v_pagado, 'falta', round(v_ped.total - v_pagado, 2));
  end if;
end; $$;

-- ── rendir a contaduría (agrupa COBRADOs del vendedor) ──
create or replace function mos.ruta_rendir(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_local text := btrim(coalesce(p->>'local_id',''));
  v_vend text := btrim(coalesce(p->>'vendedor',''));
  v_ids jsonb := coalesce(p->'ids','[]'::jsonb);
  v_id text; v_rid text; v_virt numeric := 0; v_efvo numeric := 0; v_ex ruta.rendiciones%rowtype;
begin
  if v_local = '' or v_vend = '' or jsonb_array_length(v_ids) = 0 then
    return jsonb_build_object('ok', false, 'error', 'faltan datos');
  end if;
  select * into v_ex from ruta.rendiciones where local_id = v_local;
  if found then return jsonb_build_object('ok', true, 'id_rendicion', v_ex.id_rendicion, 'dedup', true); end if;

  for v_id in select jsonb_array_elements_text(v_ids) loop
    perform 1 from ruta.pedidos where id_pedido = v_id and estado = 'COBRADO' and vendedor = v_vend for update;
    if not found then return jsonb_build_object('ok', false, 'error', v_id || ' no está COBRADO o no es tuyo'); end if;
  end loop;

  select coalesce(round(sum(case when c.metodo = 'EFECTIVO' then 0 else c.monto end),2),0),
         coalesce(round(sum(case when c.metodo = 'EFECTIVO' then c.monto else 0 end),2),0)
    into v_virt, v_efvo
  from ruta.cobros c where c.id_pedido in (select jsonb_array_elements_text(v_ids));

  v_rid := 'RD-' || lpad(nextval('ruta.seq_rendicion')::text, 3, '0');
  insert into ruta.rendiciones (id_rendicion, local_id, vendedor, tickets, sum_virtual, sum_efectivo)
  values (v_rid, v_local, v_vend, v_ids, v_virt, v_efvo);
  update ruta.pedidos set estado = 'RENDIDO', id_rendicion = v_rid, updated_at = now()
  where id_pedido in (select jsonb_array_elements_text(v_ids));
  return jsonb_build_object('ok', true, 'id_rendicion', v_rid, 'sum_virtual', v_virt, 'sum_efectivo', v_efvo,
    'total', round(v_virt + v_efvo, 2));
end; $$;

-- ── la jefa verifica (requiere clave admin) ──
create or replace function mos.ruta_rendicion_verificar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_rid text := coalesce(p->>'id_rendicion',''); v_val jsonb;
begin
  v_val := mos.verificar_clave_admin(coalesce(p->>'clave',''), 'RUTA_VERIFICAR_RENDICION', v_rid, 'mosGo',
    coalesce(p->>'device',''), '', null, null);
  if coalesce((v_val->>'autorizado')::boolean, false) = false then
    return jsonb_build_object('ok', false, 'error', coalesce(v_val->>'error','clave no autorizada'));
  end if;
  update ruta.rendiciones set estado = 'VERIFICADA', verificado_por = coalesce(v_val->>'nombre',''), ts_verificada = now()
  where id_rendicion = v_rid and estado = 'ENVIADA';
  update ruta.pedidos set estado = 'VERIFICADO', updated_at = now() where id_rendicion = v_rid and estado = 'RENDIDO';
  return jsonb_build_object('ok', true, 'id_rendicion', v_rid, 'verificado_por', coalesce(v_val->>'nombre',''));
end; $$;

-- ── rendiciones listar ──
create or replace function mos.ruta_rendiciones_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v
  from (select * from ruta.rendiciones order by created_at desc limit 100) r;
  return jsonb_build_object('ok', true, 'rendiciones', v);
end; $$;

-- ── grants (REST anon, mismo patrón que el resto del ecosistema) ──
do $$ declare fn text;
begin
  foreach fn in array array['ruta_boot','ruta_cliente_guardar','ruta_pedido_crear','ruta_pedidos_listar',
    'ruta_pedido_entregar','ruta_pedido_anular','ruta_cobro_registrar','ruta_rendir',
    'ruta_rendicion_verificar','ruta_rendiciones_listar'] loop
    execute format('grant execute on function mos.%I(jsonb) to anon, authenticated, service_role', fn);
  end loop;
end $$;

-- ── seed: los 6 productos del mockup habilitados para mayoreo con tramos EJEMPLO ──
-- (el dueño los ajusta desde MOS; tramo = precio UNITARIO para ese "desde")
update mos.productos set canal_mayoreo = true, tramos_mayoreo = '[{"desde":1,"precio":9.00},{"desde":6,"precio":8.55,"etiqueta":"6 un −5%"},{"desde":12,"precio":8.28,"etiqueta":"caja ×12 −8%"}]'::jsonb where codigo_barra = '7750243068048' and tramos_mayoreo is null;
update mos.productos set canal_mayoreo = true, tramos_mayoreo = '[{"desde":1,"precio":0.40},{"desde":42,"precio":0.30,"etiqueta":"pack ×42"},{"desde":84,"precio":0.29,"etiqueta":"pack ×84"}]'::jsonb where codigo_barra = '7753121004558' and tramos_mayoreo is null;
update mos.productos set canal_mayoreo = true, tramos_mayoreo = '[{"desde":1,"precio":0.40},{"desde":60,"precio":0.33,"etiqueta":"pack ×60"}]'::jsonb where codigo_barra = '00594' and tramos_mayoreo is null;
update mos.productos set canal_mayoreo = true, tramos_mayoreo = '[{"desde":1,"precio":3.70},{"desde":25,"precio":3.52,"etiqueta":"25 kg −5%"},{"desde":50,"precio":3.40,"etiqueta":"saco 50kg −8%"}]'::jsonb where codigo_barra = 'WHCAABCA' and tramos_mayoreo is null;
update mos.productos set canal_mayoreo = true, tramos_mayoreo = '[{"desde":1,"precio":1.70},{"desde":25,"precio":1.60,"etiqueta":"pack ×25"}]'::jsonb where codigo_barra = '7755019000123' and tramos_mayoreo is null;
update mos.productos set canal_mayoreo = true, tramos_mayoreo = '[{"desde":1,"precio":5.50},{"desde":12,"precio":5.23,"etiqueta":"12 latas −5%"},{"desde":24,"precio":5.06,"etiqueta":"caja ×24 −8%"}]'::jsonb where codigo_barra = '7751158011969' and tramos_mayoreo is null;
