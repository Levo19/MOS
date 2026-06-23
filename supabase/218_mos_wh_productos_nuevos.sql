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

  -- ORDEN idéntico al GAS: (1) filtrar huérfanos PRIMERO, (2) dedupe DESPUÉS por más reciente.
  -- (Si se dedupea antes, una fila reciente huérfana podría tapar una vieja con línea activa.)
  with cand as (
    select pnx.* from wh.producto_nuevo pnx
    where upper(coalesce(pnx.estado,'')) = v_estado
      and ( v_estado <> 'PENDIENTE'
            or coalesce(pnx.id_guia,'') = ''
            or exists (select 1 from wh.guia_detalle d
                       where d.id_guia = pnx.id_guia
                         and upper(d.cod_producto) = upper(pnx.codigo_barra)
                         and upper(coalesce(d.observacion,'')) = 'PN_PENDIENTE') )
  ),
  ranked as (
    select c.*, row_number() over (partition by c.id_guia, upper(c.codigo_barra)
                                   order by c.fecha_registro desc nulls last) rn
    from cand c
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'idProductoNuevo', id_producto_nuevo, 'idGuia', id_guia, 'marca', marca, 'descripcion', descripcion,
    'codigoBarra', codigo_barra, 'idCategoria', id_categoria, 'unidad', unidad, 'cantidad', cantidad,
    'fechaVencimiento', fecha_vencimiento, 'foto', foto, 'estado', estado, 'usuario', usuario,
    'fechaRegistro', fecha_registro, 'fechaCreacion', fecha_registro,
    'aprobadoPor', aprobado_por, 'fechaAprobacion', fecha_aprobacion, 'observacion', observacion,
    'guia', (select jsonb_build_object('idGuia', g.id_guia, 'tipo', g.tipo, 'estado', g.estado, 'fecha', g.fecha)
             from wh.guias g where g.id_guia = ranked.id_guia)
  ) order by fecha_registro desc nulls last), '[]'::jsonb)
  into v_data
  from ranked where rn = 1;

  return jsonb_build_object('ok',true,'data', v_data);
end;
$fn$;

revoke all on function mos.wh_productos_nuevos(jsonb) from public;
grant execute on function mos.wh_productos_nuevos(jsonb) to authenticated;
