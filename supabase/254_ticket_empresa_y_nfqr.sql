-- ════════════════════════════════════════════════════════════════════════════
-- 254 · REPARACIÓN #9 (fundación) — datos de EMPRESA + me.ventas.nf_qr
-- ════════════════════════════════════════════════════════════════════════════
-- Para el ticket centralizado (Edge ticket-comprobante): (1) datos fiscales de la empresa en fac.config
-- (RUC/razón social/domicilio/tel/email) — obligatorios en boleta/factura, hoy no estaban en ningún lado.
-- (2) me.ventas.nf_qr: el QR SUNAT que devuelve NubeFact (cadena_para_codigo_qr) se persiste por venta →
-- la REIMPRESIÓN de un CPE puede reconstruir el QR (hoy se perdía: solo vivía en fac.comprobantes/sesión).
-- Aditivo e inerte: nada lo lee aún hasta desplegar el Edge + cablear ME/MOS.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) Datos de empresa en fac.config (fila única id=1) ─────────────────────────────────────────────────────
alter table fac.config add column if not exists empresa_ruc          text;
alter table fac.config add column if not exists empresa_razon_social text;
alter table fac.config add column if not exists empresa_direccion     text;
alter table fac.config add column if not exists empresa_telefono      text;
alter table fac.config add column if not exists empresa_email         text;

update fac.config set
  empresa_ruc          = '20610714057',
  empresa_razon_social = 'INVERSIONES MOS EIRL',
  empresa_direccion    = 'CAL. RAUL PORRAS BARRENECHEA CDRA 3 NRO 67 - MERCADO N 2 EDUARDO CHAVEZ RISCO 66-67 - PISCO - PISCO - ICA',
  empresa_telefono     = '967791670',
  empresa_email        = 'caseritotonys@gmail.com',
  actualizado_at       = now()
where id = 1;

-- espejo en mos.config (la clave EMPRESA_RUC ya existía vacía; útil para lecturas cross-app simples).
update mos.config set valor = '20610714057' where clave = 'EMPRESA_RUC';
insert into mos.config (clave, valor, descripcion) values
  ('EMPRESA_RAZON_SOCIAL','INVERSIONES MOS EIRL','Razón social legal para tickets/CPE'),
  ('EMPRESA_DIRECCION','CAL. RAUL PORRAS BARRENECHEA CDRA 3 NRO 67 - MERCADO N 2 EDUARDO CHAVEZ RISCO 66-67 - PISCO - PISCO - ICA','Domicilio fiscal para tickets/CPE')
on conflict (clave) do update set valor = excluded.valor;

-- ── 2) Persistir el QR SUNAT por venta ──────────────────────────────────────────────────────────────────────
alter table me.ventas add column if not exists nf_qr text;

-- RPC de lectura del comprobante para imprimir: cabecera + líneas + datos fiscales (QR/hash/IGV desde fac.* si
-- existe, con me.ventas como base). Lo consume el Edge ticket-comprobante (service_role). Devuelve TODO lo que
-- el ticket necesita en 1 llamada, con la EMPRESA embebida. (El Edge igual puede leer tablas directo; esta RPC
-- centraliza el "qué imprimir" en SQL para que ME/MOS/Edge vean exactamente lo mismo.)
create or replace function fac.ticket_comprobante(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'idVenta','')), '');
  v_v    me.ventas%rowtype;
  v_cfg  fac.config%rowtype;
  v_cpe  fac.comprobantes%rowtype;
  v_items jsonb;
  v_qr   text;
  v_hash text;
  v_grav numeric;
  v_igv  numeric;
begin
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;
  select * into v_v from me.ventas where id_venta = v_id limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'venta no encontrada'); end if;
  select * into v_cfg from fac.config where id = 1 limit 1;

  -- CPE persistido (fac.comprobantes) = fuente fiel del QR/hash/IGV. Linkea por serie-numero (= correlativo
  -- "B001-00000042") porque NO hay id_venta. Best-effort: si no matchea, caemos a me.ventas.
  begin
    select * into v_cpe from fac.comprobantes
     where (serie || '-' || numero) = v_v.correlativo
        or ref_externa = v_id
     order by creado_at desc nulls last limit 1;
  exception when others then v_cpe := null; end;

  v_qr   := coalesce(nullif(v_cpe.nf_qr,''),   nullif(v_v.nf_qr,''),   v_v.correlativo);
  v_hash := coalesce(nullif(v_cpe.nf_hash,''),  nullif(v_v.nf_hash,''), '');
  v_grav := v_cpe.total_gravada;
  v_igv  := v_cpe.total_igv;
  -- fallback IGV si no hay CPE: derivar del total (asumiendo 18% gravado) para boleta/factura.
  if v_igv is null and v_v.tipo_doc in ('BOLETA','FACTURA') then
    v_grav := round(v_v.total / 1.18, 2);
    v_igv  := round(v_v.total - v_grav, 2);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
            'linea', d.linea, 'nombre', d.nombre, 'cantidad', d.cantidad,
            'precio', d.precio, 'subtotal', d.subtotal, 'unidadMedida', d.unidad_medida
          ) order by d.linea), '[]'::jsonb)
    into v_items from me.ventas_detalle d where d.id_venta = v_id;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'empresa', jsonb_build_object(
        'ruc', v_cfg.empresa_ruc, 'razonSocial', v_cfg.empresa_razon_social,
        'direccion', v_cfg.empresa_direccion, 'telefono', v_cfg.empresa_telefono, 'email', v_cfg.empresa_email),
    'idVenta', v_v.id_venta, 'tipoDoc', v_v.tipo_doc, 'correlativo', v_v.correlativo,
    'fecha', v_v.fecha, 'vendedor', v_v.vendedor, 'zonaId', v_v.zona_id,
    'clienteDoc', v_v.cliente_doc, 'clienteNombre', v_v.cliente_nombre, 'tipoDocCliente', v_v.tipo_doc_cliente,
    'total', v_v.total, 'formaPago', v_v.forma_pago, 'obs', v_v.obs,
    'nfEstado', v_v.nf_estado, 'nfHash', v_hash, 'nfQr', v_qr,
    'totalGravada', v_grav, 'totalIgv', v_igv,
    'items', v_items
  ));
end;
$fn$;
revoke all on function fac.ticket_comprobante(jsonb) from public, anon;
grant execute on function fac.ticket_comprobante(jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
