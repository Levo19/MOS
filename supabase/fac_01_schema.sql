-- ════════════════════════════════════════════════════════════════════════════
-- fac_01_schema.sql · Facturación electrónica CPE CENTRALIZADA (100% Supabase)
-- ════════════════════════════════════════════════════════════════════════════
-- Capa compartida ME + MOS (misma empresa InversionMos, mismo RUC, mismas series).
-- Emisión a NubeFact DENTRO de Postgres (extensión http) — sin Edge ni GAS.
-- Síncrona y atómica: o commitea con el CPE, o rollback (no deja PENDIENTE huérfana).
-- Todo INERTE hasta prender mos.config.FAC_CPE_DIRECTO='1' Y fac.config.activo=true.
-- ════════════════════════════════════════════════════════════════════════════

create extension if not exists http with schema extensions;
create schema if not exists fac;

-- ── Config (1 fila, secretos NubeFact) — RLS DENEGADA: nadie lee directo, solo RPCs ──
create table if not exists fac.config (
  id              int primary key default 1,
  nubefact_ruta   text default '',     -- URL que entrega NubeFact (se pega al llegar el key)
  nubefact_token  text default '',
  -- Plantilla del header de auth (el formato exacto se valida con el token demo). {token} = el token.
  -- Default = formato documentado por NubeFact. Si demo exige otro, se cambia acá SIN tocar código.
  auth_header     text default 'Token token="{token}"',
  lookup_url_dni  text default '',      -- API RUC/DNI (apis.net.pe/decolecta), GET Bearer
  lookup_url_ruc  text default '',
  lookup_token    text default '',
  modo            text default 'demo',  -- demo | produccion
  activo          boolean default false,-- false = STUB ; true = emite real a NubeFact
  serie_boleta    text default 'B001',
  serie_factura   text default 'F001',
  actualizado_at  timestamptz default now(),
  check (id = 1)
);
insert into fac.config(id) values (1) on conflict (id) do nothing;
alter table fac.config enable row level security;  -- sin policies → solo security definer

-- ── Series + correlativo (compartido entre apps) ──
create table if not exists fac.series (
  serie       text primary key,
  tipo        int  not null,            -- 1=factura · 2=boleta
  correlativo bigint not null default 0,-- último número CONSUMIDO
  activa      boolean default true
);
-- Idempotencia del correlativo (clave = local_id de la operación → mismo número en reintento)
create table if not exists fac.correlativos_emitidos (
  idem_key   text primary key,
  serie      text   not null,
  numero     bigint not null,
  emitido_at timestamptz default now()
);

-- ── Comprobantes (registro canónico, app-agnóstico) ──
create table if not exists fac.comprobantes (
  id                text primary key,
  app               text,                 -- mosExpress | MOS (quién emitió)
  origen            text,                 -- POS | MANUAL
  tipo              int not null,         -- 1=factura · 2=boleta
  serie             text not null,
  numero            bigint not null,
  moneda            text default 'PEN',
  cliente_tipo_doc  text,                 -- 0 varios · 1 DNI · 6 RUC · 4 CE · 7 Pasaporte
  cliente_doc       text,
  cliente_nombre    text,
  cliente_direccion text,
  cliente_email     text,
  total_gravada     numeric(12,2) default 0,
  total_exonerada   numeric(12,2) default 0,
  total_inafecta    numeric(12,2) default 0,
  total_ivap        numeric(12,2) default 0,   -- base IVAP (arroz pilado 4%)
  total_imp_ivap    numeric(12,2) default 0,   -- impuesto IVAP 4%
  total_igv         numeric(12,2) default 0,
  total             numeric(12,2) default 0,
  items             jsonb default '[]',
  estado            text default 'PENDIENTE',  -- PENDIENTE|EMITIDO|RECHAZADO|BAJA|STUB
  nf_hash           text,
  nf_enlace_pdf     text,
  nf_enlace_xml     text,
  nf_qr             text,
  sunat_descripcion text,
  errores           text,
  local_id          text,                 -- idempotencia (cliente)
  ref_externa       text,                 -- p.ej. me.ventas.id_venta
  creado_por        text,
  creado_at         timestamptz default now(),
  anulado_at        timestamptz,
  anulado_motivo    text,
  unique (serie, numero)
);
-- columnas IVAP (idempotente para tablas ya creadas)
alter table fac.comprobantes add column if not exists total_ivap     numeric(12,2) default 0;
alter table fac.comprobantes add column if not exists total_imp_ivap numeric(12,2) default 0;
create unique index if not exists ux_fac_localid on fac.comprobantes(local_id) where local_id is not null and local_id <> '';
create index if not exists ix_fac_estado on fac.comprobantes(estado);
create index if not exists ix_fac_fecha  on fac.comprobantes((creado_at at time zone 'America/Lima'));

-- ── Helpers ──
-- claim app del JWT (mismo patrón que me.jwt_app)
create or replace function fac._app() returns text language sql stable as $$
  select coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb) ->> 'app', '');
$$;
-- ¿app autorizada? ME o MOS (misma empresa)
create or replace function fac._app_ok() returns boolean language sql stable as $$
  select fac._app() in ('mosExpress', 'MOS');
$$;
-- kill-switch central (default OFF si la clave no existe)
create or replace function fac._on() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select valor from mos.config where clave = 'FAC_CPE_DIRECTO' limit 1), '0') = '1';
$$;

-- ── Correlativo atómico, idempotente, concurrencia-safe (PEEK: NO avanza acá) ──
-- Devuelve el SIGUIENTE número sin consumirlo. El consumo (avance) lo hace emitir_cpe
-- solo cuando NubeFact responde (o en STUB). Idempotente por idem_key.
create or replace function fac._peek_correlativo(p_serie text, p_idem_key text)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_num bigint;
begin
  -- si ya se emitió con esta clave → MISMO número (idempotente)
  if p_idem_key is not null and p_idem_key <> '' then
    select numero into v_num from fac.correlativos_emitidos where idem_key = p_idem_key;
    if found then return v_num; end if;
  end if;
  return (select correlativo + 1 from fac.series where serie = p_serie);
end;
$fn$;

-- ── Flags central ──
insert into mos.config (clave, valor, descripcion) values
  ('FAC_CPE_DIRECTO','0','Facturación CPE centralizada (fac.*) 100% Supabase — ME + MOS. OFF hasta validar token NubeFact.')
on conflict (clave) do nothing;

-- ── Seed de series (NUEVAS y limpias; crear iguales en NubeFact arrancando en 1) ──
insert into fac.series (serie, tipo, correlativo) values ('B001', 2, 0), ('F001', 1, 0)
on conflict (serie) do nothing;

revoke all on function fac._on() from public;
revoke all on function fac._peek_correlativo(text, text) from public;
