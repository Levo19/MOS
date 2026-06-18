-- 156_mos_wh_proveedores_crudo.sql — [MIGRACIÓN MOS · LECTURA PROVEEDORES CRUDA · Almacen.gs:884]
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- OBJETIVO: dar a MOS GAS (Almacen.gs:884) la MISMA fila cruda que hoy produce leer la HOJA `PROVEEDORES` del
--   spreadsheet de WH, pero desde Supabase → el dashboard de almacén de MOS queda 100% Supabase (sin tocar
--   la Hoja de WH, que puede estar stale).
--
-- ── DÓNDE VIVEN LOS PROVEEDORES EN SUPABASE (verificado 2026-06-18) ──────────────────────────────────────────
--   NO existe una sombra `wh.proveedores`. La FUENTE canónica de proveedores del ecosistema es `mos.proveedores`
--   (= la hoja PROVEEDORES_MASTER de MOS; 102 filas). Se verificó que los 48 idProveedor referenciados por
--   wh.preingresos + wh.guias están TODOS en mos.proveedores (faltan_en_master = 0). Por lo tanto leer
--   mos.proveedores cubre el 100% de lo que el read de la hoja WH PROVEEDORES aportaba en Almacen.gs:884
--   (que solo usa idProveedor + nombre para enriquecer el voucher de operaciones). El read de la hoja WH era un
--   fallback histórico para IDs que no estaban en master; hoy ese set es VACÍO.
--
-- ── PARIDAD DE SHAPE ─────────────────────────────────────────────────────────────────────────────────────────
--   _sheetToObjects(PROVEEDORES) emite filas con keys = headers camelCase de esa hoja. Almacen.gs:884 SOLO lee
--   pr.idProveedor y pr.nombre. Emitimos esas dos (load-bearing) + el resto de campos útiles del maestro
--   (camelCase) por fidelidad, sin coalesce-a-'' en numéricos/texto (TAL CUAL; el GAS hace String(x||'')). Orden
--   estable por id_proveedor (el GAS itera con forEach y mapea por id → el orden no altera el resultado).
--
-- ── GATE + ENVOLTORIO (idéntico a las mos.wh_*_crudo de 154) ────────────────────────────────────────────────
--   mos._claim_ok() · { ok:true, data:[...] } (el GAS desempaqueta .data) · security definer · search_path='' ·
--   grant execute service_role + authenticated. Solo-LECTURA, no muta nada. Idempotente.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function mos.wh_proveedores_crudo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idProveedor',      pr.id_proveedor,
           'nombre',           pr.nombre,                 -- load-bearing (Almacen.gs:886)
           'ruc',              pr.ruc,
           'telefono',         pr.telefono,
           'banco',            pr.banco,
           'numeroCuenta',     pr.numero_cuenta,
           'cci',              pr.cci,
           'email',            pr.email,
           'diaPedido',        pr.dia_pedido,
           'diaPago',          pr.dia_pago,
           'diaEntrega',       pr.dia_entrega,
           'formaPago',        pr.forma_pago,
           'plazoCredito',     pr.plazo_credito,
           'responsable',      pr.responsable,
           'categoriaProducto',pr.categoria_producto,
           'estado',           pr.estado
         ) order by pr.id_proveedor), '[]'::jsonb)
    into v_data
  from mos.proveedores pr;
  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;
revoke all on function mos.wh_proveedores_crudo() from public;
grant execute on function mos.wh_proveedores_crudo() to service_role, authenticated;
