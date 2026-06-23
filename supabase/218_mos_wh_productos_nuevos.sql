-- 218_mos_wh_productos_nuevos.sql — MOS lee los Producto Nuevo (PN) desde Supabase (no la Hoja WH).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- Cierra el lado MOS del flujo PN 100% Supabase. Hoy MOS lee PN con getProductosNuevosWarehouse →
-- _abrirWhSheet('PRODUCTO_NUEVO') (GAS/Hoja). Esta RPC (schema mos, cross-app, security definer — puede
-- leer wh.* aunque wh._claim_ok no acepte MOS) replica fiel ese shape: filtra por estado (default
-- PENDIENTE), descarta PNs huérfanos (cuya línea PN_PENDIENTE en wh.guia_detalle ya no existe), dedupe por
-- (id_guia, codigo_barra) quedándose con el más reciente. AUTO-GATE: si WH_REGISTRAR_PN_DIRECTO<>'1'
-- devuelve PN_DIRECTO_OFF → el front MOS cae a GAS. Así UN solo flag prende escritura-WH + lectura-MOS atómico.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function mos.wh_productos_nuevos(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_estado text := upper(coalesce(nullif(btrim(coalesce(p->>'estado','')),''),'PENDIENTE')); v_data jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- auto-gate: mientras WH no escriba directo, MOS debe leer de GAS (la Hoja es la verdad) → señal OFF
  if coalesce((select valor from mos.config where clave='WH_REGISTRAR_PN_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','PN_DIRECTO_OFF'); end if;

  with pn as (
    select pnx.*, row_number() over (partition by pnx.id_guia, upper(pnx.codigo_barra)
                                     order by pnx.fecha_registro desc nulls last) rn
    from wh.producto_nuevo pnx
    where upper(coalesce(pnx.estado,'')) = v_estado
  ),
  activas as (
    select distinct id_guia, upper(cod_producto) cb
    from wh.guia_detalle where upper(coalesce(observacion,'')) = 'PN_PENDIENTE'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'idProductoNuevo', id_producto_nuevo, 'idGuia', id_guia, 'marca', marca, 'descripcion', descripcion,
    'codigoBarra', codigo_barra, 'idCategoria', id_categoria, 'unidad', unidad, 'cantidad', cantidad,
    'fechaVencimiento', fecha_vencimiento, 'foto', foto, 'estado', estado, 'usuario', usuario,
    'fechaRegistro', fecha_registro, 'aprobadoPor', aprobado_por, 'fechaAprobacion', fecha_aprobacion,
    'observacion', observacion
  ) order by fecha_registro desc nulls last), '[]'::jsonb)
  into v_data
  from pn
  where rn = 1
    and ( v_estado <> 'PENDIENTE'
          or coalesce(id_guia,'') = ''
          or exists (select 1 from activas a where a.id_guia = pn.id_guia and a.cb = upper(pn.codigo_barra)) );

  return jsonb_build_object('ok',true,'data', v_data);
end;
$fn$;

revoke all on function mos.wh_productos_nuevos(jsonb) from public;
grant execute on function mos.wh_productos_nuevos(jsonb) to authenticated;
