-- 94_mos_lecturas_proveedores_jornadas.sql — [MIGRACIÓN MOS · FASE 2 · LECTURA-LISTA + HEARTBEAT-POR-ESCRITURA]
-- Para los 5 módulos NO-DINERO/operativos de MOS que ya tienen ESCRITURA directa (81 proveedores/pedidos/
-- pago-proveedor/proveedor-producto, 84 jornadas): se agregan las RPCs de LECTURA-LISTA que el front hoy lee
-- por GAS, dejándolos listos para un CUTOVER COHERENTE (lectura + escritura directas a la vez).
--
-- ⚠️ POR QUÉ LA LECTURA DEBE SER DIRECTA JUNTO CON LA ESCRITURA ──────────────────────────────────────────────
--   Si la escritura va directa a Supabase pero la lectura sigue por GAS (que lee la HOJA, una SOMBRA que la
--   RPC ya NO alimenta porque su sync se apaga en el cutover), el read-back devolvería datos STALE → el front
--   no vería lo recién escrito y podría RE-CREAR (duplicar). Lectura+escritura directas cierran ese hueco.
--
-- ⚠️ INERTE (idéntico al patrón de 75/76/81/83/84): estas RPCs de LECTURA existen y tienen grant, pero NADIE
--   las llama. El wiring de js/api.js (read-paths) y el flip (flags MOS_*_DIRECTO + apagar sync por tabla) son
--   tanda POSTERIOR. MOS sigue 100% por GAS. Este archivo NO toca flags, NO toca MOS_SYNC_OFF_TABLAS, NO cablea.
--
-- ── SHAPE (paridad con GAS) ─────────────────────────────────────────────────────────────────────────────────
--   Los getters de GAS devuelven `_sheetToObjects(HOJA)` = filas con headers en camelCase y tipos JS nativos,
--   envueltos en {ok:true, data:[...]}. El FRONT consume claves camelCase directo (p.idProveedor, p.montoJornal,
--   pp.precioReferencia, ...). Por eso estas RPCs NO devuelven snake_case crudo (como productos_master_rls, que
--   el front re-mapea), sino que MAPEAN snake→camel EXACTAMENTE según _MOS_SPECS (gas/MigracionMOS.gs) — la
--   misma tabla de mapeo que usa el sync. Resultado: { ok:true, data:[{camelCase...}], _count, _heartbeat,
--   _now, _ttl_min, _fresh }. El front lee `data` (compatible con el shape GAS {ok,data}); _fresh es la señal
--   de frescura de la SOMBRA (igual criterio que 76): si la sombra está congelada → el front cae a GAS.
--
-- ── TIPOS / DIVERGENCIAS HONESTAS ───────────────────────────────────────────────────────────────────────────
--   · IDs y textos: ya son `text` en las tablas → se pasan como vienen (el front hace String() defensivo).
--   · numeric (montoEstimado/monto/precioReferencia/minimoCompra/diasEntrega/montoJornal/unidadesPorBulto):
--     se emiten como NÚMERO JSON (paridad con _sheetToObjects, que devuelve Number). El front hace parseFloat()
--     defensivo igual.
--   · timestamptz (fecha/fechaCreacion/fechaEstimada/ultimaActualizacion): se emiten como ISO 8601 (jsonb
--     serializa timestamptz así). GAS devolvía un Date nativo; el front usa fmtDate()/String().substring(0,10),
--     ambos toleran ISO. ✅ compatible.
--   · pedidos_proveedor.items: en la HOJA GAS es un STRING JSON (JSON.stringify); en la sombra es jsonb. Esta
--     RPC emite `items` como el JSONB DIRECTO (array/objeto), NO como string. ⚠️ DIVERGENCIA DE TIPO CONOCIDA:
--     un consumidor que hiciera JSON.parse(p.items) fallaría. VERIFICADO: el único consumidor actual,
--     renderPedidos (js/app.js:15052), solo lee idPedido/fechaCreacion/montoEstimado/estado — NUNCA toca
--     `items`. Por eso es seguro HOY. Si en el flip se agrega un consumidor de items, debe tratarlo como array.
--   · proveedores_productos.activa: boolean en la tabla → emitido como boolean. getProveedorProductos de GAS
--     FILTRA activa truthy ('1'/'true'/true); esta RPC replica el filtro server-side (solo activa=true) salvo
--     que se pida includeInactivas. El front leía solo activas → paridad.
--   · proveedores: datos bancarios (numeroCuenta/cci) SÍ se incluyen — getProveedoresMaster los devuelve y el
--     panel admin de MOS los usa. A DIFERENCIA de mos.catalogo_wh_rls() (que los EXCLUYE porque sirve a WH/PWA
--     operativa que no los necesita), aquí el gate es app='MOS' (admin) → exponerlos es la paridad correcta.
--     El gate mos._claim_ok() impide que mosExpress/warehouseMos los lean.
--
-- ── GATE DE FRESCURA ────────────────────────────────────────────────────────────────────────────────────────
--   Las 5 tablas son SOMBRAS alimentadas por _syncMOSImpl (gas/MigracionMOS.gs) → latido MOS_SYNC_HEARTBEAT
--   (mismo latido que usa finanzas_rango, 76). En el cutover, la escritura directa MANTIENE ese latido vivo
--   vía mos._tocar_latido_sync() (ver sección HEARTBEAT abajo). _fresh = (heartbeat presente) AND (now()-hb<TTL).
--   TTL: MOS_SYNC_TTL_MIN (default 30, ya sembrado por 76). _fresh es informativo; la RPC SIEMPRE devuelve data.

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- HELPER de frescura común (lee MOS_SYNC_HEARTBEAT + MOS_SYNC_TTL_MIN). Devuelve jsonb con _heartbeat/_now/
-- _ttl_min/_fresh para concatenar al resultado. STABLE, sin efectos. Tolerante a parseo (sombra config en text).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos._frescura_sombra()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_hb    timestamptz;
  v_ttl   int;
  v_fresh boolean;
begin
  begin
    select (valor)::timestamptz into v_hb from mos.config where clave = 'MOS_SYNC_HEARTBEAT' limit 1;
  exception when others then v_hb := null;
  end;
  begin
    select (valor)::int into v_ttl from mos.config where clave = 'MOS_SYNC_TTL_MIN' limit 1;
  exception when others then v_ttl := null;
  end;
  v_ttl := coalesce(v_ttl, 30);
  if v_ttl < 15   then v_ttl := 15;   end if;
  if v_ttl > 1440 then v_ttl := 1440; end if;
  v_fresh := (v_hb is not null) and (now() - v_hb < make_interval(mins => v_ttl));
  return jsonb_build_object('_heartbeat', v_hb, '_now', now(), '_ttl_min', v_ttl, '_fresh', v_fresh);
end;
$fn$;
revoke all on function mos._frescura_sombra() from public;
grant execute on function mos._frescura_sombra() to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.proveedores_lista(p jsonb default '{}') — espeja getProveedoresMaster.
--   Filtros opcionales (paridad GAS): estado (String ==), q (substring nombre o ruc, case-insensitive).
--   Incluye datos bancarios (numeroCuenta/cci) — ver cabecera. Orden estable por id_proveedor.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.proveedores_lista(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_estado text := nullif(btrim(coalesce(p->>'estado','')), '');
  v_q      text := lower(nullif(btrim(coalesce(p->>'q','')), ''));
  v_data   jsonb;
  v_count  int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(row order by row->>'idProveedor'), '[]'::jsonb), count(*)
    into v_data, v_count
  from (
    select jsonb_build_object(
      'idProveedor',       t.id_proveedor,
      'nombre',            t.nombre,
      'ruc',               t.ruc,
      'imagen',            t.imagen,
      'telefono',          t.telefono,
      'banco',             t.banco,
      'numeroCuenta',      t.numero_cuenta,
      'cci',               t.cci,
      'email',             t.email,
      'diaPedido',         t.dia_pedido,
      'diaPago',           t.dia_pago,
      'diaEntrega',        t.dia_entrega,
      'formaPago',         t.forma_pago,
      'plazoCredito',      t.plazo_credito,
      'responsable',       t.responsable,
      'categoriaProducto', t.categoria_producto,
      'estado',            t.estado
    ) as row
    from mos.proveedores t
    where (v_estado is null or t.estado = v_estado)
      and (v_q is null
           or position(v_q in lower(coalesce(t.nombre,''))) > 0
           or position(v_q in lower(coalesce(t.ruc,'')))    > 0)
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.proveedores_lista(jsonb) from public;
grant execute on function mos.proveedores_lista(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.pedidos_proveedor_lista(p jsonb default '{}') — espeja getPedidosProveedor (router 'getPedidos').
--   Filtros opcionales (paridad GAS): idProveedor (==), estado (String ==). items emitido como jsonb directo
--   (ver DIVERGENCIA en cabecera; consumidor actual no lo lee). Orden estable por fecha_creacion desc, id_pedido.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.pedidos_proveedor_lista(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prov   text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_estado text := nullif(btrim(coalesce(p->>'estado','')), '');
  v_data   jsonb;
  v_count  int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(row order by ord_fecha desc nulls last, ord_id), '[]'::jsonb), count(*)
    into v_data, v_count
  from (
    select jsonb_build_object(
      'idPedido',      t.id_pedido,
      'idProveedor',   t.id_proveedor,
      'items',         coalesce(t.items, '[]'::jsonb),
      'montoEstimado', t.monto_estimado,
      'estado',        t.estado,
      'fechaCreacion', t.fecha_creacion,
      'fechaEstimada', t.fecha_estimada,
      'usuario',       t.usuario,
      'notas',         t.notas
    ) as row,
    t.fecha_creacion as ord_fecha, t.id_pedido as ord_id
    from mos.pedidos_proveedor t
    where (v_prov   is null or t.id_proveedor = v_prov)
      and (v_estado is null or t.estado = v_estado)
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.pedidos_proveedor_lista(jsonb) from public;
grant execute on function mos.pedidos_proveedor_lista(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.pagos_proveedor_lista(p jsonb default '{}') — espeja getPagosProveedor (router 'getPagos').
--   Filtros opcionales (paridad GAS): idProveedor (==), estado (String ==). ⚠️ NO expone local_id.
--   Orden estable por fecha desc, id_pago.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.pagos_proveedor_lista(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prov   text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_estado text := nullif(btrim(coalesce(p->>'estado','')), '');
  v_data   jsonb;
  v_count  int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(row order by ord_fecha desc nulls last, ord_id), '[]'::jsonb), count(*)
    into v_data, v_count
  from (
    select jsonb_build_object(
      'idPago',        t.id_pago,
      'idProveedor',   t.id_proveedor,
      'monto',         t.monto,
      'fecha',         t.fecha,
      'numeroFactura', t.numero_factura,
      'estado',        t.estado,
      'observacion',   t.observacion,
      'registradoPor', t.registrado_por
    ) as row,
    t.fecha as ord_fecha, t.id_pago as ord_id
    from mos.pagos_proveedor t
    where (v_prov   is null or t.id_proveedor = v_prov)
      and (v_estado is null or t.estado = v_estado)
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.pagos_proveedor_lista(jsonb) from public;
grant execute on function mos.pagos_proveedor_lista(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.proveedor_producto_lista(p jsonb default '{}') — espeja getProveedorProductos.
--   GAS EXIGE idProveedor y FILTRA activa truthy. Paridad: si idProveedor presente → solo de ese proveedor;
--   por defecto solo activa=true (paridad). includeInactivas=true → trae también inactivas (forward-looking,
--   no rompe paridad porque GAS nunca pedía inactivas). Si idProveedor ausente → error (paridad estricta GAS).
--   Orden estable por id_proveedor, descripcion, id_pp.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.proveedor_producto_lista(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prov text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_incl boolean := (coalesce(p->>'includeInactivas','') in ('true','1','t'));
  v_data jsonb;
  v_count int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- Paridad GAS: getProveedorProductos exige idProveedor (devuelve error si falta).
  if v_prov is null then return jsonb_build_object('ok', false, 'error', 'idProveedor requerido'); end if;

  select coalesce(jsonb_agg(row order by ord_desc, ord_id), '[]'::jsonb), count(*)
    into v_data, v_count
  from (
    select jsonb_build_object(
      'idPP',                t.id_pp,
      'idProveedor',         t.id_proveedor,
      'skuBase',             t.sku_base,
      'codigoBarra',         t.codigo_barra,
      'descripcion',         t.descripcion,
      'precioReferencia',    t.precio_referencia,
      'minimoCompra',        t.minimo_compra,
      'diasEntrega',         t.dias_entrega,
      'ultimaActualizacion', t.ultima_actualizacion,
      'activa',              t.activa,
      'notas',               t.notas,
      'unidadesPorBulto',    t.unidades_por_bulto
    ) as row,
    coalesce(t.descripcion,'') as ord_desc, t.id_pp as ord_id
    from mos.proveedores_productos t
    where t.id_proveedor = v_prov
      and (v_incl or t.activa = true)   -- paridad GAS: solo activas, salvo includeInactivas
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.proveedor_producto_lista(jsonb) from public;
grant execute on function mos.proveedor_producto_lista(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.jornadas_lista(p jsonb default '{}') — espeja getJornadas.
--   Filtro opcional (paridad GAS): fecha = String(r.fecha).substring(0,10) === params.fecha. La sombra guarda
--   timestamptz → el filtro compara la fecha en TZ America/Lima (espeja cómo se grabó / cómo el día se computa
--   en el ecosistema MOS). Forward-looking: desde/hasta (rango YYYY-MM-DD) si se quiere una ventana.
--   Orden estable por fecha desc, id_jornada.  Emite todas las filas (incluidas fuente='ELIMINADA' tombstone),
--   paridad con getJornadas (que NO filtra vetadas — el front decide).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.jornadas_lista(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_fecha text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_desde text := nullif(btrim(coalesce(p->>'desde','')), '');
  v_hasta text := nullif(btrim(coalesce(p->>'hasta','')), '');
  v_data  jsonb;
  v_count int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- Validación de formatos fecha (basura → error limpio, no filtro silencioso roto).
  begin
    if v_fecha is not null then perform v_fecha::date; end if;
    if v_desde is not null then perform v_desde::date; end if;
    if v_hasta is not null then perform v_hasta::date; end if;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'Fecha inválida (YYYY-MM-DD)');
  end;

  select coalesce(jsonb_agg(row order by ord_fecha desc nulls last, ord_id), '[]'::jsonb), count(*)
    into v_data, v_count
  from (
    select jsonb_build_object(
      'idJornada',     t.id_jornada,
      'fecha',         t.fecha,
      'idPersonal',    t.id_personal,
      'nombre',        t.nombre,
      'rol',           t.rol,
      'appOrigen',     t.app_origen,
      'zona',          t.zona,
      'montoJornal',   t.monto_jornal,
      'observacion',   t.observacion,
      'registradoPor', t.registrado_por,
      'fuente',        t.fuente
    ) as row,
    t.fecha as ord_fecha, t.id_jornada as ord_id
    from mos.jornadas t
    where (v_fecha is null
           or (t.fecha at time zone 'America/Lima')::date = v_fecha::date)
      and (v_desde is null
           or (t.fecha at time zone 'America/Lima')::date >= v_desde::date)
      and (v_hasta is null
           or (t.fecha at time zone 'America/Lima')::date <= v_hasta::date)
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.jornadas_lista(jsonb) from public;
grant execute on function mos.jornadas_lista(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- HEARTBEAT-POR-ESCRITURA — agregar `perform mos._tocar_latido_sync()` a las RPCs de ESCRITURA de estos
-- módulos (81 + 84). Razón: cuando el cutover apague el sync-desde-hoja de estas tablas (MOS_SYNC_OFF_TABLAS),
-- el latido MOS_SYNC_HEARTBEAT (frescura de finanzas + de estas listas) dejaría de estamparse por _syncMOSImpl.
-- Cada escritura directa exitosa lo mantiene vivo. BEST-EFFORT (la fn _tocar_latido_sync ya traga errores) →
-- NO altera idempotencia ni atomicidad de DINERO. Se llama SOLO en el camino de escritura REAL (no en dedup,
-- no en *_OFF, no en error) — coherente con 83 (que solo toca latido tras inserción/borrado confirmado).
--
-- ⚠️ Las definiciones de abajo son COPIAS FIELES de 81/84 con UNA sola línea añadida (`perform
--    mos._tocar_latido_sync();`) justo antes del `return` del camino de escritura exitosa. Todo lo demás
--    (gate, kill-switch, idempotencia local_id/PK, UPDATE atómico, redes unique_violation) es IDÉNTICO.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── 81a) crear_proveedor: latido tras INSERT confirmado (v_inserted=1) ──────────────────────────────────────
create or replace function mos.crear_proveedor(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local  text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id     text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_nombre text := nullif(btrim(coalesce(p->>'nombre','')), '');
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PROVEEDORES_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PROVEEDORES_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_nombre is null then return jsonb_build_object('ok',false,'error','El nombre es requerido'); end if;

  if v_local is not null then
    select id_proveedor into v_existe from mos.proveedores where local_id = v_local limit 1;
    if found then
      return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_existe));
    end if;
  end if;

  if v_id is not null and exists (select 1 from mos.proveedores where id_proveedor = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_id));
  end if;

  v_id := coalesce(v_id, 'PROV'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.proveedores (
    id_proveedor, nombre, ruc, imagen, telefono, banco, numero_cuenta, cci, email,
    dia_pedido, dia_pago, dia_entrega, forma_pago, plazo_credito, responsable, categoria_producto,
    estado, local_id
  ) values (
    v_id, v_nombre,
    nullif(btrim(coalesce(p->>'ruc','')),''),
    nullif(btrim(coalesce(p->>'imagen','')),''),
    nullif(btrim(coalesce(p->>'telefono','')),''),
    nullif(btrim(coalesce(p->>'banco','')),''),
    nullif(btrim(coalesce(p->>'numeroCuenta','')),''),
    nullif(btrim(coalesce(p->>'cci','')),''),
    nullif(btrim(coalesce(p->>'email','')),''),
    nullif(btrim(coalesce(p->>'diaPedido','')),''),
    nullif(btrim(coalesce(p->>'diaPago','')),''),
    nullif(btrim(coalesce(p->>'diaEntrega','')),''),
    coalesce(nullif(btrim(coalesce(p->>'formaPago','')),''),'CONTADO'),
    coalesce(nullif(btrim(coalesce(p->>'plazoCredito','')),''),'0'),
    nullif(btrim(coalesce(p->>'responsable','')),''),
    nullif(btrim(coalesce(p->>'categoriaProducto','')),''),
    '1',
    v_local
  )
  on conflict (id_proveedor) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    if v_local is not null then
      select id_proveedor into v_existe from mos.proveedores where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_id));
  end if;

  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA (best-effort, no rompe la tx)
  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idProveedor', v_id));
exception
  when unique_violation then
    if v_local is not null then
      select id_proveedor into v_existe from mos.proveedores where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_id));
end;
$fn$;
revoke all on function mos.crear_proveedor(jsonb) from public;
grant execute on function mos.crear_proveedor(jsonb) to service_role, authenticated;

-- ── 81b) actualizar_proveedor: latido tras UPDATE confirmado (v_n>0) ────────────────────────────────────────
create or replace function mos.actualizar_proveedor(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_n  int;
begin
  if coalesce((select valor from mos.config where clave='MOS_PROVEEDORES_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PROVEEDORES_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idProveedor'); end if;

  update mos.proveedores t set
    nombre             = case when p ? 'nombre'            then nullif(btrim(coalesce(p->>'nombre','')),'')             else t.nombre end,
    ruc                = case when p ? 'ruc'               then nullif(btrim(coalesce(p->>'ruc','')),'')                else t.ruc end,
    telefono           = case when p ? 'telefono'          then nullif(btrim(coalesce(p->>'telefono','')),'')           else t.telefono end,
    banco              = case when p ? 'banco'             then nullif(btrim(coalesce(p->>'banco','')),'')              else t.banco end,
    numero_cuenta      = case when p ? 'numeroCuenta'      then nullif(btrim(coalesce(p->>'numeroCuenta','')),'')       else t.numero_cuenta end,
    cci                = case when p ? 'cci'               then nullif(btrim(coalesce(p->>'cci','')),'')                else t.cci end,
    email              = case when p ? 'email'             then nullif(btrim(coalesce(p->>'email','')),'')              else t.email end,
    dia_pedido         = case when p ? 'diaPedido'         then nullif(btrim(coalesce(p->>'diaPedido','')),'')          else t.dia_pedido end,
    dia_pago           = case when p ? 'diaPago'           then nullif(btrim(coalesce(p->>'diaPago','')),'')            else t.dia_pago end,
    dia_entrega        = case when p ? 'diaEntrega'        then nullif(btrim(coalesce(p->>'diaEntrega','')),'')         else t.dia_entrega end,
    forma_pago         = case when p ? 'formaPago'         then nullif(btrim(coalesce(p->>'formaPago','')),'')          else t.forma_pago end,
    plazo_credito      = case when p ? 'plazoCredito'      then nullif(btrim(coalesce(p->>'plazoCredito','')),'')       else t.plazo_credito end,
    responsable        = case when p ? 'responsable'       then nullif(btrim(coalesce(p->>'responsable','')),'')        else t.responsable end,
    categoria_producto = case when p ? 'categoriaProducto' then nullif(btrim(coalesce(p->>'categoriaProducto','')),'')  else t.categoria_producto end,
    estado             = case when p ? 'estado'            then nullif(btrim(coalesce(p->>'estado','')),'')             else t.estado end
  where id_proveedor = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Proveedor no encontrado'); end if;
  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true);
end;
$fn$;
revoke all on function mos.actualizar_proveedor(jsonb) from public;
grant execute on function mos.actualizar_proveedor(jsonb) to service_role, authenticated;

-- ── 81c) crear_pedido_proveedor: latido tras INSERT confirmado ──────────────────────────────────────────────
create or replace function mos.crear_pedido_proveedor(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id    text := nullif(btrim(coalesce(p->>'idPedido','')), '');
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_items jsonb;
  v_monto numeric := mos._numn(p->>'montoEstimado');
  v_fest  timestamptz;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PEDIDOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PEDIDOS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_prov is null then return jsonb_build_object('ok',false,'error','Requiere idProveedor'); end if;

  if (p ? 'items') and jsonb_typeof(p->'items') = 'array' then
    v_items := p->'items';
  else
    v_items := '[]'::jsonb;
  end if;

  begin
    v_fest := nullif(btrim(coalesce(p->>'fechaEstimada','')),'')::timestamptz;
  exception when others then v_fest := null;
  end;

  if v_local is not null then
    select id_pedido into v_existe from mos.pedidos_proveedor where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_existe)); end if;
  end if;
  if v_id is not null and exists (select 1 from mos.pedidos_proveedor where id_pedido = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_id));
  end if;

  v_id := coalesce(v_id, 'PED'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.pedidos_proveedor (
    id_pedido, id_proveedor, items, monto_estimado, estado, fecha_creacion, fecha_estimada, usuario, notas, local_id
  ) values (
    v_id, v_prov, v_items, coalesce(v_monto,0), 'BORRADOR', now(), v_fest,
    nullif(btrim(coalesce(p->>'usuario','')),''),
    nullif(btrim(coalesce(p->>'notas','')),''),
    v_local
  )
  on conflict (id_pedido) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    if v_local is not null then
      select id_pedido into v_existe from mos.pedidos_proveedor where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_id));
  end if;

  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idPedido', v_id));
exception
  when unique_violation then
    if v_local is not null then
      select id_pedido into v_existe from mos.pedidos_proveedor where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_id));
end;
$fn$;
revoke all on function mos.crear_pedido_proveedor(jsonb) from public;
grant execute on function mos.crear_pedido_proveedor(jsonb) to service_role, authenticated;

-- ── 81d) actualizar_pedido_proveedor: latido tras UPDATE confirmado ─────────────────────────────────────────
create or replace function mos.actualizar_pedido_proveedor(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'idPedido','')), '');
  v_items jsonb;
  v_fest  timestamptz;
  v_fest_set boolean := false;
  v_n     int;
begin
  if coalesce((select valor from mos.config where clave='MOS_PEDIDOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PEDIDOS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idPedido'); end if;

  if (p ? 'items') and jsonb_typeof(p->'items') = 'array' then v_items := p->'items'; end if;

  if p ? 'fechaEstimada' then
    v_fest_set := true;
    begin v_fest := nullif(btrim(coalesce(p->>'fechaEstimada','')),'')::timestamptz;
    exception when others then v_fest := null; end;
  end if;

  update mos.pedidos_proveedor t set
    estado         = case when p ? 'estado'        then nullif(btrim(coalesce(p->>'estado','')),'')   else t.estado end,
    items          = case when v_items is not null  then v_items                                       else t.items end,
    monto_estimado = case when p ? 'montoEstimado'  then coalesce(mos._numn(p->>'montoEstimado'),0)    else t.monto_estimado end,
    notas          = case when p ? 'notas'          then nullif(btrim(coalesce(p->>'notas','')),'')    else t.notas end,
    fecha_estimada = case when v_fest_set           then v_fest                                        else t.fecha_estimada end
  where id_pedido = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Pedido no encontrado'); end if;
  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true);
end;
$fn$;
revoke all on function mos.actualizar_pedido_proveedor(jsonb) from public;
grant execute on function mos.actualizar_pedido_proveedor(jsonb) to service_role, authenticated;

-- ── 81e) registrar_pago_proveedor: latido tras INSERT confirmado (DINERO) ───────────────────────────────────
create or replace function mos.registrar_pago_proveedor(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id    text := nullif(btrim(coalesce(p->>'idPago','')), '');
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_monto numeric := mos._numn(p->>'monto');
  v_fecha timestamptz;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PAGOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PAGOS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_prov is null then return jsonb_build_object('ok',false,'error','Requiere idProveedor'); end if;
  if v_monto is null or v_monto <= 0 then return jsonb_build_object('ok',false,'error','Requiere monto válido (> 0)'); end if;

  if v_local is null then return jsonb_build_object('ok',false,'error','Requiere localId (idempotencia de pago)'); end if;

  select id_pago into v_existe from mos.pagos_proveedor where local_id = v_local limit 1;
  if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_existe)); end if;

  if v_id is not null and exists (select 1 from mos.pagos_proveedor where id_pago = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_id));
  end if;

  begin
    v_fecha := nullif(btrim(coalesce(p->>'fecha','')),'')::timestamptz;
  exception when others then v_fecha := null;
  end;
  v_fecha := coalesce(v_fecha, now());

  v_id := coalesce(v_id, 'PAG'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.pagos_proveedor (
    id_pago, id_proveedor, monto, fecha, numero_factura, estado, observacion, registrado_por, local_id
  ) values (
    v_id, v_prov, v_monto, v_fecha,
    nullif(btrim(coalesce(p->>'numeroFactura','')),''),
    coalesce(nullif(btrim(coalesce(p->>'estado','')),''),'PAGADO'),
    nullif(btrim(coalesce(p->>'observacion','')),''),
    nullif(btrim(coalesce(p->>'registradoPor','')),''),
    v_local
  )
  on conflict (local_id) where local_id is not null do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    select id_pago into v_existe from mos.pagos_proveedor where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_existe)); end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_id));
  end if;

  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA (best-effort; el pago ya está commiteado)
  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idPago', v_id));
exception
  when unique_violation then
    select id_pago into v_existe from mos.pagos_proveedor where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_existe)); end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_id));
end;
$fn$;
revoke all on function mos.registrar_pago_proveedor(jsonb) from public;
grant execute on function mos.registrar_pago_proveedor(jsonb) to service_role, authenticated;

-- ── 81f) upsert_proveedor_producto: latido tras UPDATE/INSERT confirmado ────────────────────────────────────
create or replace function mos.upsert_proveedor_producto(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_idpp  text := nullif(btrim(coalesce(p->>'idPP','')), '');
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_cod   text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_target text;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PROVPROD_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PROVPROD_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_prov is null then return jsonb_build_object('ok',false,'error','idProveedor requerido'); end if;

  if v_local is not null then
    select id_pp into v_existe from mos.proveedores_productos where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_existe, 'accion','existente')); end if;
  end if;

  if v_idpp is not null and exists (select 1 from mos.proveedores_productos where id_pp = v_idpp) then
    v_target := v_idpp;
  elsif v_sku is not null then
    select id_pp into v_target from mos.proveedores_productos
      where id_proveedor = v_prov and sku_base = v_sku limit 1;
  end if;

  if v_target is not null then
    update mos.proveedores_productos t set
      sku_base            = case when p ? 'skuBase'          then nullif(btrim(coalesce(p->>'skuBase','')),'')          else t.sku_base end,
      codigo_barra        = case when p ? 'codigoBarra'      then nullif(btrim(coalesce(p->>'codigoBarra','')),'')      else t.codigo_barra end,
      descripcion         = case when p ? 'descripcion'      then nullif(btrim(coalesce(p->>'descripcion','')),'')      else t.descripcion end,
      precio_referencia   = case when p ? 'precioReferencia' then coalesce(mos._numn(p->>'precioReferencia'),0)         else t.precio_referencia end,
      minimo_compra       = case when p ? 'minimoCompra'     then coalesce(mos._numn(p->>'minimoCompra'),0)             else t.minimo_compra end,
      dias_entrega        = case when p ? 'diasEntrega'      then coalesce(mos._numn(p->>'diasEntrega'),0)              else t.dias_entrega end,
      activa              = case when p ? 'activa'           then ((p->>'activa') not in ('false','0','f'))             else t.activa end,
      notas               = case when p ? 'notas'            then nullif(btrim(coalesce(p->>'notas','')),'')            else t.notas end,
      unidades_por_bulto  = case when p ? 'unidadesPorBulto' then coalesce(mos._numn(p->>'unidadesPorBulto'),1)         else t.unidades_por_bulto end,
      ultima_actualizacion = now()
    where id_pp = v_target;
    perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
    return jsonb_build_object('ok',true,'data', jsonb_build_object('idPP', v_target, 'accion','actualizado'));
  end if;

  if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;

  v_idpp := coalesce(v_idpp, 'PP'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.proveedores_productos (
    id_pp, id_proveedor, sku_base, codigo_barra, descripcion, precio_referencia, minimo_compra,
    dias_entrega, ultima_actualizacion, activa, notas, unidades_por_bulto, local_id
  ) values (
    v_idpp, v_prov, v_sku, v_cod,
    nullif(btrim(coalesce(p->>'descripcion','')),''),
    coalesce(mos._numn(p->>'precioReferencia'),0),
    coalesce(mos._numn(p->>'minimoCompra'),0),
    coalesce(mos._numn(p->>'diasEntrega'),0),
    now(),
    case when p ? 'activa' then ((p->>'activa') not in ('false','0','f')) else true end,
    nullif(btrim(coalesce(p->>'notas','')),''),
    coalesce(mos._numn(p->>'unidadesPorBulto'),1),
    v_local
  )
  on conflict (id_pp) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    if v_local is not null then
      select id_pp into v_existe from mos.proveedores_productos where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_existe, 'accion','existente')); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_idpp, 'accion','existente'));
  end if;

  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idPP', v_idpp, 'accion','creado'));
exception
  when unique_violation then
    if v_local is not null then
      select id_pp into v_existe from mos.proveedores_productos where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_existe, 'accion','existente')); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_idpp, 'accion','existente'));
end;
$fn$;
revoke all on function mos.upsert_proveedor_producto(jsonb) from public;
grant execute on function mos.upsert_proveedor_producto(jsonb) to service_role, authenticated;

-- ── 84a) registrar_jornada: latido tras INSERT confirmado (DINERO jornal) ───────────────────────────────────
create or replace function mos.registrar_jornada(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local  text    := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id     text    := nullif(btrim(coalesce(p->>'idJornada','')), '');
  v_nombre text    := nullif(btrim(coalesce(p->>'nombre','')), '');
  v_monto  numeric := mos._numn(p->>'montoJornal');
  v_fecha  timestamptz;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_JORNADAS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_JORNADAS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_nombre is null then return jsonb_build_object('ok',false,'error','Requiere nombre y montoJornal'); end if;
  if v_monto is null or v_monto <= 0 then return jsonb_build_object('ok',false,'error','Requiere nombre y montoJornal'); end if;

  if v_local is not null then
    select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
  end if;

  if v_id is not null and exists (select 1 from mos.jornadas where id_jornada = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_id));
  end if;

  begin
    v_fecha := nullif(btrim(coalesce(p->>'fecha','')),'')::timestamptz;
  exception when others then v_fecha := null;
  end;
  v_fecha := coalesce(v_fecha, now());

  v_id := coalesce(v_id, 'JOR'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.jornadas (
    id_jornada, fecha, id_personal, nombre, rol, app_origen, zona,
    monto_jornal, observacion, registrado_por, fuente, local_id
  ) values (
    v_id, v_fecha,
    coalesce(nullif(btrim(coalesce(p->>'idPersonal','')),''),''),
    v_nombre,
    coalesce(nullif(btrim(coalesce(p->>'rol','')),''),''),
    coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''),'MOS'),
    coalesce(nullif(btrim(coalesce(p->>'zona','')),''),''),
    v_monto,
    coalesce(nullif(btrim(coalesce(p->>'observacion','')),''),''),
    coalesce(nullif(btrim(coalesce(p->>'registradoPor','')),''),''),
    'MANUAL',
    v_local
  )
  on conflict (id_jornada) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    if v_local is not null then
      select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_id));
  end if;

  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idJornada', v_id));
exception
  when unique_violation then
    if v_local is not null then
      select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_id));
end;
$fn$;
revoke all on function mos.registrar_jornada(jsonb) from public;
grant execute on function mos.registrar_jornada(jsonb) to service_role, authenticated;

-- ── 84b) eliminar_jornada: latido tras UPDATE veto confirmado ───────────────────────────────────────────────
create or replace function mos.eliminar_jornada(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'idJornada','')), '');
  v_actor text := coalesce(
                    nullif(btrim(coalesce(p->>'actor','')),''),
                    nullif(btrim(coalesce(p->>'registradoPor','')),''),
                    'admin');
  v_now   timestamptz := clock_timestamp();
  v_iso   text;
  v_n     int;
begin
  if coalesce((select valor from mos.config where clave='MOS_JORNADAS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_JORNADAS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idJornada'); end if;

  v_iso := to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');

  update mos.jornadas
     set monto_jornal = 0,
         observacion  = 'VETO_TS:' || v_iso || ' · por ' || v_actor,
         fuente       = 'ELIMINADA'
   where id_jornada = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Jornada no encontrada'); end if;
  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true,'data', jsonb_build_object('vetoTs', v_iso, 'idJornada', v_id));
end;
$fn$;
revoke all on function mos.eliminar_jornada(jsonb) from public;
grant execute on function mos.eliminar_jornada(jsonb) to service_role, authenticated;

-- ── 84c) rehabilitar_jornada: latido tras UPDATE rehab confirmado ───────────────────────────────────────────
create or replace function mos.rehabilitar_jornada(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idJornada','')), '');
  v_actor  text := coalesce(
                     nullif(btrim(coalesce(p->>'actor','')),''),
                     nullif(btrim(coalesce(p->>'registradoPor','')),''),
                     'admin');
  v_now    timestamptz := clock_timestamp();
  v_iso    text;
  v_fuente text;
  v_nombre text;
  v_idpers text;
  v_monto  numeric := mos._numn(p->>'monto');
  v_montoDef numeric := mos._numn(p->>'montoDefault');
  v_final  numeric;
  v_n      int;
begin
  if coalesce((select valor from mos.config where clave='MOS_JORNADAS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_JORNADAS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idJornada'); end if;

  select upper(coalesce(fuente,'')), coalesce(nombre,''), coalesce(id_personal,'')
    into v_fuente, v_nombre, v_idpers
    from mos.jornadas
   where id_jornada = v_id
   for update;

  if not found then return jsonb_build_object('ok',false,'error','Jornada no encontrada'); end if;
  if v_fuente <> 'ELIMINADA' then return jsonb_build_object('ok',false,'error','La jornada no está vetada'); end if;

  v_final := case when v_monto is not null and v_monto > 0 then v_monto else null end;
  if v_final is null then
    select monto_base into v_final
      from mos.personal
     where (nullif(v_idpers,'') is not null and id_personal = v_idpers)
        or (lower(coalesce(nombre,'')) = lower(v_nombre))
     order by (nullif(v_idpers,'') is not null and id_personal = v_idpers) desc
     limit 1;
    if v_final is null or v_final <= 0 then v_final := null; end if;
  end if;
  if v_final is null then
    v_final := case when v_montoDef is not null and v_montoDef > 0 then v_montoDef else 0 end;
  end if;

  v_iso := to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');

  update mos.jornadas
     set monto_jornal = v_final,
         observacion  = 'REHAB_TS:' || v_iso || ' · por ' || v_actor,
         fuente       = 'MANUAL'
   where id_jornada = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Jornada no encontrada'); end if;
  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true,'data', jsonb_build_object('rehabTs', v_iso, 'idJornada', v_id, 'monto', v_final));
end;
$fn$;
revoke all on function mos.rehabilitar_jornada(jsonb) from public;
grant execute on function mos.rehabilitar_jornada(jsonb) to service_role, authenticated;
