-- 127_riz_tablas.sql — [RIZ · CAPA 1 · TABLAS [A]-[E]]
-- Módulo de Reposición Inteligente por Zona (RIZ). Diseño: DISENO_modulo_reposicion_zona.md (Parte 1.4).
--
-- ⚠️ INERTE: crear estas tablas NO cambia el comportamiento de producción. Nadie las llena/lee todavía (las
--    RPCs de 128/129 las escriben/leen, pero esas no están cableadas a frontend/cron). MOS opera 100% por GAS.
--    Idempotente (create table if not exists / add column if not exists / create index if not exists).
--
-- ── PATRÓN RLS ──────────────────────────────────────────────────────────────────────────────────────────────
--   Igual que el resto de tablas me.* (02_schema_me.sql:320-336): RLS HABILITADO sin políticas. service_role
--   bypassa RLS (GAS/cron). Las RPCs de RIZ son `security definer` (corren como owner) → escriben/leen estas
--   tablas sin política. anon/authenticated NO tienen grant a las tablas → doble bloqueo (RLS + sin grant).
--   El acceso del frontend será SIEMPRE vía las RPCs definer, nunca tabla directa.
--
-- ── UNIDADES ────────────────────────────────────────────────────────────────────────────────────────────────
--   Todas las cantidades aquí son UNIDADES BASE (ver fundación 126). numeric SIN precisión fija (lección WH:
--   cero overflow). zona_id / sku_base son `text` (consistente con mos.zonas.id_zona y mos.productos.sku_base).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- [A] me.zona_esperado — el "espacio deseado" calculado. 1 fila por (zona_id, sku_base). Materializado por
--     mos/me recompute (RPC me.zona_esperado_recompute, archivo 128) o el cron (Capa 3).
--     esperada = ceil(pico_ultima_semana × (1 + colchon_pct)). tendencia/pico_proyectado = etiqueta informativa.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists me.zona_esperado (
  zona_id          text not null,
  sku_base         text not null,
  esperado         numeric,                 -- unidades base objetivo (ceil)
  pico_ultima      numeric,                 -- pico de la última semana cerrada (la base del cálculo)
  pico_proyectado  numeric,                 -- informativo: pico que la tendencia insinúa (NO usado en esperado)
  tendencia        text,                    -- CRECIENTE / DECRECIENTE / ESTABLE / NULA
  bcg              text,                    -- ESTRELLA / VACA / INTERROGANTE / PERRO
  picos            jsonb,                   -- serie de N picos [p1..pN] (informativa, para el card sin recomputar)
  colchon_pct      numeric,                 -- colchón aplicado (de la zona)
  volumen_4sem     numeric,                 -- suma de unidades base de la ventana (eje X de la BCG)
  fuente           text default 'auto',     -- 'auto' (recompute) | 'manual' (override admin)
  actualizado_ts   timestamptz default now(),
  primary key (zona_id, sku_base)
);
create index if not exists ix_riz_esperado_zona      on me.zona_esperado (zona_id);
create index if not exists ix_riz_esperado_tendencia on me.zona_esperado (zona_id, tendencia);

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- [B] me.zona_ticket_dia — la cola del proceso manual diario (~10 productos/día). Idempotente por
--     (zona_id, fecha, lote_dia). items = jsonb[] con A..E por producto. La materialización + corte en lotes lo
--     hará el cron (Capa 3); la RPC me.zona_ticket_dia (129) arma/lee el lote.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists me.zona_ticket_dia (
  zona_id     text not null,
  fecha       date not null,
  lote_dia    int  not null default 1,      -- 1..N lotes del día (si hay >10 productos)
  items       jsonb,                          -- [{skuBase, nombre, stockZona, esperada, faltan, tendencia, picos[], stockAlmacen}]
  estado      text default 'PENDIENTE',       -- PENDIENTE | IMPRESO | REVISADO
  impreso_ts  timestamptz,
  creado_ts   timestamptz default now(),
  primary key (zona_id, fecha, lote_dia)
);
create index if not exists ix_riz_ticket_zona_fecha on me.zona_ticket_dia (zona_id, fecha);

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- [C] me.zona_compra_externa — la lista de compras del lunes (lo que almacén NO cubrió y SÍ se vende).
--     Idempotente por (zona_id, semana, sku_base). costo opcional (lo registra la guía de ingreso ME, no RIZ).
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists me.zona_compra_externa (
  zona_id      text not null,
  semana       text not null,               -- etiqueta ISO 'IYYY-Www' (la semana objetivo)
  sku_base     text not null,
  descripcion  text,
  cantidad     numeric,                      -- unidades base a conseguir por fuera (brecha − stockAlmacen)
  estado       text default 'PENDIENTE',     -- PENDIENTE | COMPRADO | DESCARTADO
  costo        numeric,                      -- opcional (enlaza a guía de ingreso ME; RIZ no lo construye)
  creado_ts    timestamptz default now(),
  resuelto_ts  timestamptz,
  primary key (zona_id, semana, sku_base)
);
create index if not exists ix_riz_compra_zona_sem on me.zona_compra_externa (zona_id, semana);
create index if not exists ix_riz_compra_estado    on me.zona_compra_externa (zona_id, estado);

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- [D] me.zona_ajuste_log — auditoría de ajustes de stock hechos desde el card (inventario/dinero → trazable).
--     id bigserial; cada ajuste agrega una fila. La RPC me.zona_ajustar_stock (129) inserta aquí.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists me.zona_ajuste_log (
  id             bigserial primary key,
  zona_id        text not null,
  sku_base       text,
  cod_barras     text,                        -- el código concreto sobre el que se escribió me.stock_zonas
  stock_antes    numeric,
  stock_despues  numeric,
  delta          numeric,
  usuario        text,
  local_id       text,                        -- idempotencia del gesto (dual-write frontend reenvía el mismo)
  ts             timestamptz default now()
);
create index if not exists ix_riz_ajuste_zona on me.zona_ajuste_log (zona_id, sku_base);
create unique index if not exists ux_riz_ajuste_localid on me.zona_ajuste_log (local_id) where local_id is not null;

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- [E] me.zona_lotes — "libro de lotes" de la zona (perecibles, FIFO). Cada ingreso desde almacén crea una fila
--     heredando id_lote + fecha_vencimiento de wh.guia_detalle. Venta en zona consume FIFO (vto más próximo
--     primero) descontando cant_restante. Alimenta la alerta de vencimiento del card + su historial de ingresos.
--     PK compuesta (zona_id, sku_base, id_lote): un lote por zona/sku (si el mismo lote re-ingresa, se acumula).
--     ⚠️ La PROPAGACIÓN desde wh.cerrar_guia (despacho WH→zona) es trabajo de una capa posterior (ver NOTA al
--        final + entregable). Esta tabla queda lista; nadie la llena aún.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists me.zona_lotes (
  zona_id           text not null,
  sku_base          text not null,
  id_lote           text not null,
  cod_barras        text,                     -- código concreto del ingreso (para cuadrar con me.stock_zonas)
  fecha_vencimiento timestamptz,
  cant_ingresada    numeric,
  cant_restante     numeric,
  fecha_ingreso     timestamptz default now(),
  id_guia_origen    text,
  estado            text default 'ACTIVO',    -- ACTIVO | AGOTADO
  primary key (zona_id, sku_base, id_lote)
);
create index if not exists ix_riz_lotes_zona_sku on me.zona_lotes (zona_id, sku_base);
create index if not exists ix_riz_lotes_vto      on me.zona_lotes (zona_id, sku_base, fecha_vencimiento);

-- ── RLS: habilitar (idempotente; ya habilitado = no-op). Sin políticas → anon/authenticated bloqueado por tabla;
--    service_role bypassa; RPCs definer escriben/leen como owner. ──────────────────────────────────────────────
alter table me.zona_esperado       enable row level security;
alter table me.zona_ticket_dia     enable row level security;
alter table me.zona_compra_externa enable row level security;
alter table me.zona_ajuste_log     enable row level security;
alter table me.zona_lotes          enable row level security;

-- ── Grants: SOLO service_role (igual que el resto de tablas me.*; el acceso real es vía RPC definer). ──────────
grant all on me.zona_esperado, me.zona_ticket_dia, me.zona_compra_externa, me.zona_ajuste_log, me.zona_lotes to service_role;
grant usage, select on sequence me.zona_ajuste_log_id_seq to service_role;
