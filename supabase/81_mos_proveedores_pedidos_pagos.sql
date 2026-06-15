-- 81_mos_proveedores_pedidos_pagos.sql — [MIGRACIÓN MOS · FASE 2 · LOTE PROVEEDORES/PEDIDOS/PAGOS]
-- RPCs de ESCRITURA directa para proveedores maestros, pedidos de compra, PAGOS (dinero) y proveedor-producto.
-- Espeja gas/Proveedores.gs (crearProveedorMaster/actualizarProveedorMaster/registrarPago/crearPedidoProveedor/
--   agregarProductoProveedor/actualizarProductoProveedor/upsertProductoProveedor) — router gas/Code.gs cases
--   crearProveedor/actualizarProveedor/registrarPago/crearPedido/agregarProductoProveedor/...
--
-- ⚠️ NACE INERTE (triple, IDÉNTICO al patrón de 78): (1) kill-switch server-side por flag mos.config —
--    UNO POR OPERACIÓN (MOS_PROVEEDORES_DIRECTO / MOS_PEDIDOS_DIRECTO / MOS_PAGOS_DIRECTO / MOS_PROVPROD_DIRECTO),
--    todos default '0'; (2) nadie cablea js/api.js todavía → ninguna PWA llama estas RPCs; (3) MOS sigue 100%
--    por GAS. Las RPCs existen y tienen grant, pero el flag OFF las hace devolver *_OFF (el front caerá a GAS).
--
-- ── POR QUÉ ARREGLA BUGS DE GAS ──────────────────────────────────────────────────────────────────────────
--   Los originales de GAS hacen appendRow CRUDO sin lock ni dedup → doble-tap / reintento de cola offline =
--   fila duplicada. En proveedores/pedidos es molesto; en PAGOS (DINERO) es INACEPTABLE: un pago jamás se
--   puede duplicar. Acá la idempotencia por `local_id` (índice único parcial del cimiento 80 +
--   insert ... on conflict (local_id) do nothing) hace que un reintento del MISMO gesto no inserte un 2do pago.
--   actualizarProveedorMaster en GAS hace read(getValues)→modify→write celda a celda; acá es un UPDATE atómico
--   sobre la PK (lock de fila implícito) → sin lost-update.
--
-- ── DINERO (mos.registrar_pago_proveedor) ───────────────────────────────────────────────────────────────
--   Idempotencia ESTRICTA por local_id: la PWA DEBE mandar un local_id estable por gesto (lo genera el cliente
--   y lo reusa en cada reintento). on conflict (local_id) do nothing → el 2do intento NO inserta; devolvemos
--   el id_pago YA persistido (dedup:true). Sin local_id la RPC RECHAZA (no se permite un pago sin red de
--   idempotencia — contrato más estricto que catálogo, porque es dinero).
--   ⚠️ PARIDAD HONESTA: registrarPago de GAS es un LEDGER PLANO — NO toca saldo/estado de ningún pedido
--   (pagos_proveedor no tiene id_pedido ni FK; el "por pagar" se DERIVA en getHistoricoProveedor como
--   totalGastado(guías WH) − totalPagado, en lectura). Por eso esta RPC NO hace UPDATE de saldo: no hay
--   saldo materializado que actualizar. Si en el futuro se materializa un saldo por pedido, el delta atómico
--   (UPDATE ... set saldo = saldo - delta, NUNCA read-modify-write) iría AQUÍ. Hoy: no aplica.
--
-- ── IDS ──────────────────────────────────────────────────────────────────────────────────────────────────
--   _generateId(prefix) de GAS = prefix + Date.getTime() (epoch ms). Acá: prefix + (epoch*1000 de
--   clock_timestamp())::bigint. La idempotencia REAL es por local_id (no por el id de negocio); el id de
--   negocio se puede mandar desde el front (lo obtiene de la 1ra respuesta) y se respeta on conflict (PK).

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- 0) CIMIENTO (idempotente): asegura columna local_id + índice único parcial en las 4 tablas.
--    (Equivale a 80_mos_proveedores_local_id.sql; se re-aplica acá por seguridad — todo `if not exists`.)
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
alter table mos.proveedores            add column if not exists local_id text;
alter table mos.pedidos_proveedor      add column if not exists local_id text;
alter table mos.pagos_proveedor        add column if not exists local_id text;
alter table mos.proveedores_productos  add column if not exists local_id text;

create unique index if not exists ux_mos_proveedores_localid on mos.proveedores (local_id) where local_id is not null;
create unique index if not exists ux_mos_pedidosprov_localid on mos.pedidos_proveedor (local_id) where local_id is not null;
create unique index if not exists ux_mos_pagosprov_localid   on mos.pagos_proveedor (local_id) where local_id is not null;
create unique index if not exists ux_mos_provprod_localid    on mos.proveedores_productos (local_id) where local_id is not null;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) KILL-SWITCHES (uno por operación, default '0' → INERTE). Sembrado idempotente.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
insert into mos.config (clave, valor, descripcion) values
  ('MOS_PROVEEDORES_DIRECTO','0','MOS Fase 2: escritura directa de PROVEEDORES maestros a Supabase. OFF → front cae a GAS.'),
  ('MOS_PEDIDOS_DIRECTO',    '0','MOS Fase 2: escritura directa de PEDIDOS a proveedor a Supabase. OFF → front cae a GAS.'),
  ('MOS_PAGOS_DIRECTO',      '0','MOS Fase 2: escritura directa de PAGOS a proveedor (DINERO) a Supabase. OFF → front cae a GAS.'),
  ('MOS_PROVPROD_DIRECTO',   '0','MOS Fase 2: escritura directa de PROVEEDOR-PRODUCTO (catálogo cotizaciones) a Supabase. OFF → front cae a GAS.')
on conflict (clave) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.crear_proveedor(p jsonb) — espeja crearProveedorMaster
--   Idempotente por local_id (gesto de cliente) y por PK id_proveedor (si el front reenvía el id).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
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

  -- IDEMPOTENCIA por local_id (gesto): si ya existe → dedup, devolver el id persistido.
  if v_local is not null then
    select id_proveedor into v_existe from mos.proveedores where local_id = v_local limit 1;
    if found then
      return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_existe));
    end if;
  end if;

  -- IDEMPOTENCIA por PK (reintento que reenvía el id de negocio).
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
    nullif(btrim(coalesce(p->>'numeroCuenta','')),''),     -- datos bancarios por nombre
    nullif(btrim(coalesce(p->>'cci','')),''),
    nullif(btrim(coalesce(p->>'email','')),''),
    nullif(btrim(coalesce(p->>'diaPedido','')),''),
    nullif(btrim(coalesce(p->>'diaPago','')),''),
    nullif(btrim(coalesce(p->>'diaEntrega','')),''),
    coalesce(nullif(btrim(coalesce(p->>'formaPago','')),''),'CONTADO'),
    coalesce(nullif(btrim(coalesce(p->>'plazoCredito','')),''),'0'),   -- plazo_credito es text en la tabla
    nullif(btrim(coalesce(p->>'responsable','')),''),
    nullif(btrim(coalesce(p->>'categoriaProducto','')),''),
    '1',                                                   -- estado por defecto '1' (paridad GAS)
    v_local
  )
  on conflict (id_proveedor) do nothing;
  get diagnostics v_inserted = row_count;

  -- carrera: si el id colisionó (otra tx) o el local_id chocó en paralelo → dedup, devolver lo persistido.
  if v_inserted = 0 then
    if v_local is not null then
      select id_proveedor into v_existe from mos.proveedores where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_id));
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idProveedor', v_id));
exception
  -- red de seguridad: si dos tx con el MISMO local_id corren a la par, una choca el índice único parcial.
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

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.actualizar_proveedor(p jsonb) — espeja actualizarProveedorMaster (patch parcial, UPDATE atómico)
--   GAS: solo escribe los campos PRESENTES en params (params[c] !== undefined). Acá: case when p ? 'clave'.
--   Datos bancarios (numero_cuenta/cci) por nombre. NO normaliza nombre a no-vaciable: GAS deja vaciar
--   cualquier campo presente (setValue con string vacío) → respetamos esa semántica (vaciable si la clave viene).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
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

  -- UPDATE ATÓMICO por PK (lock de fila implícito → sin lost-update). Cada campo: si la clave viene presente,
  -- se aplica (aunque sea vacío → NULL), si no, se conserva. Espeja "campos.forEach if params[c]!==undefined".
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
  return jsonb_build_object('ok',true);
end;
$fn$;
revoke all on function mos.actualizar_proveedor(jsonb) from public;
grant execute on function mos.actualizar_proveedor(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.crear_pedido_proveedor(p jsonb) — espeja crearPedidoProveedor
--   estado nace 'BORRADOR' (paridad GAS). items = jsonb. Idempotente por local_id + PK.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
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

  -- items: aceptar jsonb array directo o no-presente → '[]' (paridad params.items || [])
  if (p ? 'items') and jsonb_typeof(p->'items') = 'array' then
    v_items := p->'items';
  else
    v_items := '[]'::jsonb;
  end if;

  -- fechaEstimada opcional (texto fecha → timestamptz; basura → NULL sin reventar)
  begin
    v_fest := nullif(btrim(coalesce(p->>'fechaEstimada','')),'')::timestamptz;
  exception when others then v_fest := null;
  end;

  -- IDEMPOTENCIA por local_id (gesto)
  if v_local is not null then
    select id_pedido into v_existe from mos.pedidos_proveedor where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_existe)); end if;
  end if;
  -- IDEMPOTENCIA por PK
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

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.actualizar_pedido_proveedor(p jsonb) — gestión de estado/items del pedido.
--   ⚠️ NO existe equivalente en gas/Proveedores.gs (GAS solo crea pedidos en BORRADOR). Esta RPC es
--      FORWARD-LOOKING para que la PWA pueda mover estado (BORRADOR→ENVIADO→RECIBIDO…) y editar items/monto/
--      notas/fechaEstimada. Patch parcial, UPDATE atómico por PK. Sin saldo (los pedidos no materializan saldo).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
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
  return jsonb_build_object('ok',true);
end;
$fn$;
revoke all on function mos.actualizar_pedido_proveedor(jsonb) from public;
grant execute on function mos.actualizar_pedido_proveedor(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.registrar_pago_proveedor(p jsonb) — espeja registrarPago.  ⚠️ DINERO ⚠️
--   Idempotencia ESTRICTA por local_id: SIN local_id → RECHAZA (no se permite un pago sin red de idempotencia).
--   on conflict (local_id) do nothing → el reintento/doble-tap del MISMO gesto NO inserta un 2do pago;
--   devolvemos el id_pago YA persistido (dedup:true). NO toca saldo (ledger plano — ver cabecera del archivo).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
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

  -- Validaciones (paridad GAS: requiere idProveedor y monto) + DINERO: monto > 0.
  if v_prov is null then return jsonb_build_object('ok',false,'error','Requiere idProveedor'); end if;
  if v_monto is null or v_monto <= 0 then return jsonb_build_object('ok',false,'error','Requiere monto válido (> 0)'); end if;

  -- DINERO: local_id OBLIGATORIO. Sin él no hay red de idempotencia → se rechaza para no arriesgar duplicar pago.
  if v_local is null then return jsonb_build_object('ok',false,'error','Requiere localId (idempotencia de pago)'); end if;

  -- IDEMPOTENCIA ESTRICTA por local_id: si ya se registró este gesto → devolver el mismo pago (NO duplicar).
  select id_pago into v_existe from mos.pagos_proveedor where local_id = v_local limit 1;
  if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_existe)); end if;

  -- IDEMPOTENCIA por PK (reintento que reenvía idPago)
  if v_id is not null and exists (select 1 from mos.pagos_proveedor where id_pago = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_id));
  end if;

  -- fecha: texto (yyyy-MM-dd o ISO) → timestamptz; ausente → now() (paridad GAS hoy).
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
  on conflict (local_id) where local_id is not null do nothing;   -- DINERO: dedup duro por gesto (índice único PARCIAL → predicado obligatorio para inferirlo)
  get diagnostics v_inserted = row_count;

  -- carrera: el conflicto pudo ser por local_id (otra tx ganó) o por id_pago. Devolver SIEMPRE el pago real.
  if v_inserted = 0 then
    select id_pago into v_existe from mos.pagos_proveedor where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_existe)); end if;
    -- conflicto por PK (id_pago) sin local_id coincidente: devolver el id (ya está persistido)
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_id));
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idPago', v_id));
exception
  -- red de seguridad ANTI-DOBLE-PAGO: dos tx con el MISMO local_id en paralelo → la perdedora choca el índice
  -- único parcial; en vez de propagar el error (que abortaría su tx), devolvemos el pago ya persistido.
  when unique_violation then
    select id_pago into v_existe from mos.pagos_proveedor where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_existe)); end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_id));
end;
$fn$;
revoke all on function mos.registrar_pago_proveedor(jsonb) from public;
grant execute on function mos.registrar_pago_proveedor(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.upsert_proveedor_producto(p jsonb) — espeja agregarProductoProveedor + actualizarProductoProveedor +
--   upsertProductoProveedor (catálogo de cotizaciones). Una sola RPC con upsert:
--     · si viene idPP existente → UPDATE atómico (patch parcial, paridad actualizarProductoProveedor)
--     · si no, pero existe (idProveedor + skuBase) → UPDATE (paridad upsertProductoProveedor por sku)
--     · si no existe nada → INSERT (paridad agregarProductoProveedor). Idempotente por local_id.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
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
  v_cod   text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');   -- texto SIEMPRE
  v_target text;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PROVPROD_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PROVPROD_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_prov is null then return jsonb_build_object('ok',false,'error','idProveedor requerido'); end if;

  -- IDEMPOTENCIA por local_id (gesto de creación): ya existe → dedup.
  if v_local is not null then
    select id_pp into v_existe from mos.proveedores_productos where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPP', v_existe, 'accion','existente')); end if;
  end if;

  -- Resolver el target del upsert: idPP explícito → por (prov+sku) → ninguno (insert).
  if v_idpp is not null and exists (select 1 from mos.proveedores_productos where id_pp = v_idpp) then
    v_target := v_idpp;
  elsif v_sku is not null then
    select id_pp into v_target from mos.proveedores_productos
      where id_proveedor = v_prov and sku_base = v_sku limit 1;
  end if;

  -- ── UPDATE (patch parcial, paridad actualizarProductoProveedor) ──────────────────────────────────────
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
    return jsonb_build_object('ok',true,'data', jsonb_build_object('idPP', v_target, 'accion','actualizado'));
  end if;

  -- ── INSERT (paridad agregarProductoProveedor) ────────────────────────────────────────────────────────
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
    case when p ? 'activa' then ((p->>'activa') not in ('false','0','f')) else true end,   -- default true
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
