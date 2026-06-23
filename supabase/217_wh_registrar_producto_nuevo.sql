-- 217_wh_registrar_producto_nuevo.sql — Emisión de Producto Nuevo (PN) 100% Supabase (sin GAS/Drive/Hoja).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- WH (nivel inferior) solo EMITE el PN a wh.producto_nuevo; MOS aprueba/edita/anula. Réplica fiel de
-- gas/Productos.gs registrarProductoNuevo: upsert por (codigo_barra, id_guia, PENDIENTE); genera código
-- NLEV00001+ si no viene código; estado PENDIENTE. La foto llega como URL (el frontend la sube a Supabase
-- Storage, no a Drive). La línea de guía la crea el frontend aparte (agregarDetalleGuia directo). Gate
-- WH_REGISTRAR_PN_DIRECTO + wh._claim_ok. advisory lock serializa la generación del código NLEV.
-- ⚠️ Para 100% Supabase falta migrar el LECTOR de PN de MOS (getProductosNuevosWarehouse lee la Hoja WH) →
--    a wh.producto_nuevo. Esta RPC es el lado WH; el flag NO se prende hasta que MOS lea de Supabase.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

-- Secuencia dedicada para el código interno NLEV (producto sin barcode). Atómica (nextval, sin lock),
-- arranca en 100000 → sobre cualquier NLEV existente (5-díg max ~17803; los 13-díg timestamp no colisionan).
-- Evita parsear el histórico sucio (formatos mixtos) que rompía el max+parseInt.
create sequence if not exists wh.seq_nlev start 100000;

create or replace function wh.registrar_producto_nuevo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_cb    text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_guia  text := nullif(btrim(coalesce(p->>'idGuia','')), '');
  v_cant  numeric := wh._num(p->>'cantidad');   -- tolerante (coma decimal/vacío/basura → 0), paridad flota
  -- fecha defensiva: solo castea si arranca con formato ISO (YYYY-MM-DD); sino null (no aborta la tx)
  v_venc  timestamptz := case when nullif(btrim(coalesce(p->>'fechaVencimiento','')),'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
                              then (p->>'fechaVencimiento')::timestamptz else null end;
  v_exist text; v_id text;
begin
  if coalesce((select valor from mos.config where clave='WH_REGISTRAR_PN_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REGISTRAR_PN_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- código NLEV único si el producto no tiene barcode (secuencia atómica, sin parsear histórico)
  if v_cb is null then
    v_cb := 'NLEV' || nextval('wh.seq_nlev')::text;
  end if;

  -- UPSERT por (codigo_barra, id_guia, PENDIENTE) — idéntico al GAS (REPLACE, no duplica)
  if v_guia is not null then
    select id_producto_nuevo into v_exist from wh.producto_nuevo
      where id_guia = v_guia and upper(codigo_barra) = upper(v_cb) and upper(coalesce(estado,'')) = 'PENDIENTE'
      limit 1;
  end if;

  if v_exist is not null then
    update wh.producto_nuevo set
      marca             = coalesce(nullif(btrim(coalesce(p->>'marca','')),''), marca),
      descripcion       = coalesce(nullif(btrim(coalesce(p->>'descripcion','')),''), descripcion),
      id_categoria      = coalesce(nullif(btrim(coalesce(p->>'idCategoria','')),''), id_categoria),
      unidad            = coalesce(nullif(btrim(coalesce(p->>'unidad','')),''), unidad),
      cantidad          = case when v_cant > 0 then v_cant else cantidad end,
      fecha_vencimiento = coalesce(v_venc, fecha_vencimiento),
      foto              = coalesce(nullif(btrim(coalesce(p->>'foto','')),''), foto),
      usuario           = coalesce(nullif(btrim(coalesce(p->>'usuario','')),''), usuario),
      fecha_registro    = now()
    where id_producto_nuevo = v_exist;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('idProductoNuevo',v_exist,'codigoBarra',v_cb,'idempotente',true));
  end if;

  v_id := 'PN' || (extract(epoch from clock_timestamp())*1000)::bigint::text;
  insert into wh.producto_nuevo (id_producto_nuevo, id_guia, marca, descripcion, codigo_barra, id_categoria,
    unidad, cantidad, fecha_vencimiento, foto, estado, usuario, fecha_registro, aprobado_por, fecha_aprobacion, observacion)
  values (v_id, coalesce(v_guia,''), coalesce(p->>'marca',''), coalesce(p->>'descripcion',''), v_cb,
    coalesce(p->>'idCategoria',''), coalesce(p->>'unidad',''), v_cant, v_venc,
    coalesce(p->>'foto',''), 'PENDIENTE', coalesce(p->>'usuario',''), now(), '', null, '');
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idProductoNuevo',v_id,'codigoBarra',v_cb,'idempotente',false));
end;
$fn$;

insert into mos.config (clave, valor, descripcion) values
  ('WH_REGISTRAR_PN_DIRECTO','0','WH: emitir producto nuevo directo a wh.producto_nuevo (no GAS/Hoja). Prender SOLO cuando MOS lea PN de Supabase.')
on conflict (clave) do nothing;

revoke all on function wh.registrar_producto_nuevo(jsonb) from public;
grant execute on function wh.registrar_producto_nuevo(jsonb) to authenticated;
