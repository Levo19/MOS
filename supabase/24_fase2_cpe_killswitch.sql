-- 24_fase2_cpe_killswitch.sql — [Lote2-B · fixes C1+C2+A2 de la revisión 2026-06-12]
-- La capa CPE estaba VIVA del lado server aunque el flag ME_CPE_DIRECTO='0' (el flag solo lo leía el
-- frontend). Cualquier dispositivo con token ME podía:
--   · crear_cpe_directo  → insertar boletas/facturas falsas en me.ventas (la reconciliación las espejaba
--                          a VENTAS_CABECERA = filas fiscales falsas en la fuente de verdad);
--   · set_cpe_nf         → marcar nf_estado='EMITIDO' en CUALQUIER venta (incl. una NV), pisar hash/enlace,
--                          o degradar un EMITIDO (fraude contable / venta que "parece" facturada ante SUNAT).
-- Este SQL:
--   C1: kill-switch SERVER-SIDE — ambas RPC leen mos.config.ME_CPE_DIRECTO y rechazan si <> '1'.
--   A2: set_cpe_nf con máquina de estados — solo BOLETA/FACTURA, whitelist de estados, prohíbe degradar
--       un EMITIDO, no toca NV.
-- Helper interno _cpe_directo_on() centraliza la lectura del flag (un solo punto de verdad).

-- Helper: ¿está el CPE-directo encendido en mos.config? (default OFF si la clave no existe).
create or replace function me._cpe_directo_on()
returns boolean language sql stable security definer set search_path = '' as $fn$
  select coalesce((select valor from mos.config where clave = 'ME_CPE_DIRECTO' limit 1), '0') = '1';
$fn$;

-- ── crear_cpe_directo: kill-switch al inicio (después del claim, antes de tocar nada) ──
create or replace function me.crear_cpe_directo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app     text := me.jwt_app();
  v_sub     text := me.jwt_sub();
  v_ref     text := nullif(btrim(coalesce(p->>'ref_local','')), '');
  v_serie   text := nullif(btrim(coalesce(p->>'serie','')), '');
  v_tipo    text := upper(coalesce(p->>'tipo_doc',''));
  v_caja    text := coalesce(p->>'id_caja','');
  v_caja_ok boolean;
  v_zona    text;
  v_total   numeric := coalesce((p->>'total')::numeric, 0);
  v_suma    numeric;
  v_nit     int;
  v_ex      me.ventas%rowtype;
  v_num     bigint; v_corr text; v_id text; v_item jsonb; v_linea int := 0; v_ins int;
begin
  if v_app  <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  -- [Lote2-B · C1] KILL-SWITCH server-side: si el flag no está en '1', NO se emite CPE desde acá.
  if not me._cpe_directo_on() then return jsonb_build_object('status','error','error','CPE_DIRECTO_DESACTIVADO'); end if;
  if v_ref  is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  if v_serie is null then return jsonb_build_object('status','error','error','SERIE_REQUERIDA'); end if;
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('status','error','error','SOLO_CPE_DIRECTO'); end if;

  -- idempotencia: si ya existe por ref_local (reintento) → devolver la MISMA (con su estado NF actual)
  select * into v_ex from me.ventas where ref_local = v_ref limit 1;
  if found then
    return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo,
                              'nf_estado',coalesce(v_ex.nf_estado,''),'nf_hash',coalesce(v_ex.nf_hash,''),'nf_enlace',coalesce(v_ex.nf_enlace,''));
  end if;

  -- [paridad con SQL 23] total = Σ(items.subtotal) (tolerancia 0.01) — base imponible no manipulable
  select coalesce(sum((it->>'subtotal')::numeric), 0), count(*) into v_suma, v_nit
    from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it;
  if v_nit > 0 and abs(v_total - v_suma) > 0.01 then
    return jsonb_build_object('status','error','error','TOTAL_NO_CUADRA','detalle','total='||v_total||' suma_items='||v_suma);
  end if;

  -- caja ABIERTA + zona de la caja (parity con crear_venta_directa endurecida)
  select (estado = 'ABIERTA'), zona_id into v_caja_ok, v_zona from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA'); end if;

  -- correlativo atómico de la serie B/F (idempotente por ref_local)
  v_num  := me.siguiente_correlativo(v_serie, v_ref);
  v_corr := v_serie || '-' || lpad(v_num::text, 6, '0');
  v_id   := 'V-' || (floor(extract(epoch from clock_timestamp()) * 1000))::bigint::text
                 || '-' || substr(md5(random()::text || clock_timestamp()::text || v_ref), 1, 8);

  -- [paridad con SQL 23] dispositivo_id del claim sub; zona_id de la caja
  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
                         tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio,
                         ref_local, obs, tipo_doc_cliente, nf_estado, zona_id)
  values (v_id, now(), p->>'vendedor', p->>'estacion', coalesce(p->>'cliente_doc',''), coalesce(p->>'cliente_nombre',''),
          v_total, v_tipo,
          coalesce(p->>'forma_pago','EFECTIVO'), v_corr, v_caja,
          coalesce(nullif(v_sub,''), p->>'dispositivo_id', ''), 'COMPLETADO', v_ref, coalesce(p->>'obs',''),
          coalesce((p->>'tipo_doc_cliente')::int, 0), 'PENDIENTE', coalesce(v_zona,''))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;
  get diagnostics v_ins = row_count;

  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_ref limit 1;
    if found then return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo,
                              'nf_estado',coalesce(v_ex.nf_estado,''),'nf_hash',coalesce(v_ex.nf_hash,''),'nf_enlace',coalesce(v_ex.nf_enlace,'')); end if;
    return jsonb_build_object('status','error','error','INSERT_INCONSISTENTE');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_linea := v_linea + 1;
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
                                   cod_barras, valor_unitario, tipo_igv, unidad_medida)
    values (v_id, v_linea, v_item->>'sku', v_item->>'nombre', coalesce((v_item->>'cantidad')::numeric,0),
            coalesce((v_item->>'precio')::numeric,0), coalesce((v_item->>'subtotal')::numeric,0),
            coalesce(v_item->>'cod_barras',''), coalesce((v_item->>'valor_unitario')::numeric,0),
            coalesce((v_item->>'tipo_igv')::int,1), coalesce(v_item->>'unidad_medida','NIU'))
    on conflict (id_venta, linea) do nothing;
  end loop;

  return jsonb_build_object('status','success','dedup',false,'id_venta',v_id,'correlativo',v_corr,'numero',v_num,'nf_estado','PENDIENTE');
end;
$fn$;

-- ── set_cpe_nf: kill-switch + máquina de estados (A2) ──
-- Antes: pisaba nf_* de CUALQUIER venta sin validar dueño/tipo/estado. Ahora:
--   · requiere flag ON (kill-switch);
--   · solo ventas BOLETA/FACTURA (jamás una NV);
--   · whitelist de nf_estado (PENDIENTE/EMITIDO/RECHAZADO/BAJA);
--   · prohíbe degradar un EMITIDO (una vez aceptado por SUNAT no se "des-emite" por esta vía).
create or replace function me.set_cpe_nf(p_ref_local text, p_nf jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app  text := me.jwt_app();
  v_ref  text := nullif(btrim(coalesce(p_ref_local,'')),'');
  v_new  text := upper(coalesce(p_nf->>'nf_estado',''));
  v_cur  me.ventas%rowtype;
  v_n    int;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not me._cpe_directo_on() then return jsonb_build_object('status','error','error','CPE_DIRECTO_DESACTIVADO'); end if;
  if v_ref is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  -- whitelist de estados (vacío = no cambia el estado, solo hash/enlace)
  if v_new <> '' and v_new not in ('PENDIENTE','EMITIDO','RECHAZADO','BAJA') then
    return jsonb_build_object('status','error','error','NF_ESTADO_INVALIDO');
  end if;

  select * into v_cur from me.ventas where ref_local = v_ref limit 1;
  if not found then return jsonb_build_object('status','success','actualizadas',0); end if;
  -- nunca tocar una NV (solo comprobantes electrónicos)
  if v_cur.tipo_doc not in ('BOLETA','FACTURA') then
    return jsonb_build_object('status','error','error','NO_ES_CPE');
  end if;
  -- no degradar un EMITIDO (idempotente: re-set EMITIDO sí permitido)
  if coalesce(v_cur.nf_estado,'') = 'EMITIDO' and v_new <> '' and v_new <> 'EMITIDO' and v_new <> 'BAJA' then
    return jsonb_build_object('status','error','error','EMITIDO_NO_DEGRADABLE');
  end if;

  update me.ventas
     set nf_estado = case when v_new <> '' then v_new else nf_estado end,
         nf_hash   = coalesce(p_nf->>'nf_hash',   nf_hash),
         nf_enlace = coalesce(p_nf->>'nf_enlace', nf_enlace)
   where ref_local = v_ref;
  get diagnostics v_n = row_count;
  return jsonb_build_object('status','success','actualizadas', v_n);
end;
$fn$;

revoke all on function me._cpe_directo_on() from public;
revoke all on function me.crear_cpe_directo(jsonb) from public;
revoke all on function me.set_cpe_nf(text, jsonb) from public;
grant execute on function me.crear_cpe_directo(jsonb) to authenticated;
grant execute on function me.set_cpe_nf(text, jsonb) to authenticated;
-- _cpe_directo_on es interno (lo llaman las otras dos, que son security definer) → sin grant a authenticated.
