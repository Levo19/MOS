-- 78_mos_crear_actualizar_producto.sql — [MIGRACIÓN MOS · FASE 2 · LOTE CATÁLOGO] Escritura directa del CATÁLOGO MAESTRO.
-- Espeja crearProductoMaster / actualizarProductoMaster / publicarPrecio + _propagarPrecioVentaAPresentaciones (gas/Productos.gs).
--
-- ⚠️ NACE INERTE (triple): (1) flag mos.config.MOS_CATALOGO_DIRECTO default '0' (kill-switch server-side);
--    (2) nadie cablea js/api.js todavía (otra tanda) → ninguna PWA llama estas RPCs; (3) MOS sigue 100% por GAS.
--    Las RPCs existen, tienen grant, pero el flag OFF las hace devolver *_OFF (el front, cuando se cable, caerá a GAS).
--
-- ── POR QUÉ ARREGLA UN BUG DE GAS ────────────────────────────────────────────────────────────────────────
--   crearProductoMaster en GAS NO toma _conLock → dos creaciones concurrentes pueden leer el MISMO max de
--   _siguienteSecuenciaProducto y generar el MISMO IDPRO (lost-update / colisión de id). Acá la id sale de una
--   SECUENCIA Postgres (nextval = atómico, sin read-modify-write) → imposible colisión bajo concurrencia.
--   actualizarProductoMaster en GAS hace read (getValues) → modify → write celda a celda; acá es un UPDATE
--   atómico sobre la PK (lock de fila implícito) → sin lost-update.
--
-- ── MODELO CANÓNICO (memoria architecture_mos_canonicos · NO se reinventa) ───────────────────────────────
--   tipo se DERIVA, no es verdad-de-usuario. La COLUMNA mos.productos.tipo_producto la calculó el backfill
--   (gas/MigracionCatalogo.gs post()): base presente → DERIVADO; factor>0 y factor<>1 → PRESENTACION; resto → CANONICO.
--   Se replica EXACTO acá para que la sombra quede consistente (GAS no escribe la columna porque la Sheet no la
--   tiene; pero la sombra Supabase SÍ la tiene y la lectura/agrupación FIFO la usa → hay que mantenerla viva).
--   factor_conversion en CREATE replica crearProductoMaster: presentación → parseFloat(factor)||1; derivado → null
--   (usa factor_conversion_base); base → 1. NOTA: el enum mos.producto_tipo NO tiene 'EQUIVALENTE' (los equivalentes
--   viven en mos.equivalencias, no en productos) → ver 79_mos_equivalencias.sql.
--
-- ── IDEMPOTENCIA ─────────────────────────────────────────────────────────────────────────────────────────
--   crear: por PK id_producto con insert ... on conflict (id_producto) do nothing (NO if-exists). El front debe
--   mandar el MISMO id_producto/sku_base en un reintento (los obtiene de la 1ra respuesta) → doble-tap no duplica.
--   Si NO viene id, la RPC lo genera de la secuencia (1er intento). Para que un reintento sin id no cree un 2do
--   producto, el front DEBE persistir el id devuelto y reenviarlo (contrato documentado abajo). Adicional: dedup
--   defensivo por codigo_barra (paridad con la validación de duplicado de GAS).
--
--   actualizar/publicar_precio: naturalmente idempotentes (UPDATE atómico al mismo valor = no-op; re-aplicar el
--   mismo precio no cambia nada). El guard _camposNoVaciables impide que un patch parcial borre campos críticos.

insert into mos.config (clave, valor, descripcion) values
  ('MOS_CATALOGO_DIRECTO','0','MOS Fase 2: escritura directa del catálogo (crear/actualizar/publicar precio/equivalencias) a Supabase. Validar antes de prender. OFF → front cae a GAS.')
on conflict (clave) do nothing;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- Helpers locales del catálogo MOS
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────

-- Coerción numérica tolerante (como parseFloat de GAS): coma decimal, null, basura → no revienta la tx.
-- Devuelve NULL para entrada vacía/null (≠ wh._num que da 0) porque el catálogo distingue "" (no tocar) de 0.
create or replace function mos._numn(t text) returns numeric language sql immutable as $fn$
  select case
    when t is null then null
    when btrim(t) = '' then null
    when btrim(replace(t, ',', '.')) ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(replace(t, ',', '.'))::numeric
    else null end;
$fn$;

-- Secuencia atómica de ids de producto (reemplaza _siguienteSecuenciaProducto SIN lost-update).
-- Se siembra una vez al MAX(IDPRO####### , LEV#######) ya presente en la tabla; nextval es atómico.
do $seed$
declare v_max bigint;
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where c.relname='seq_producto' and n.nspname='mos' and c.relkind='S') then
    select coalesce(max(n),0) into v_max from (
      select (substring(id_producto from '^IDPRO([0-9]+)$'))::bigint n from mos.productos
        where id_producto ~ '^IDPRO[0-9]+$'
      union all
      select (substring(sku_base from '^LEV([0-9]+)$'))::bigint n from mos.productos
        where sku_base ~ '^LEV[0-9]+$'
    ) s;
    execute format('create sequence mos.seq_producto start with %s', v_max + 1);
  end if;
end $seed$;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.crear_producto(p jsonb) — espeja crearProductoMaster
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.crear_producto(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_desc    text := nullif(btrim(coalesce(p->>'descripcion','')), '');
  v_pv      numeric := mos._numn(p->>'precioVenta');
  v_id      text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_sku     text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_cod     text := btrim(coalesce(p->>'codigoBarra',''));     -- texto SIEMPRE
  v_seq     bigint;
  v_pad     text;
  -- SUNAT/IGV defaults (paridad GAS)
  v_tipoigv text := coalesce(nullif(btrim(coalesce(p->>'Tipo_IGV','')),''),'1');
  v_igvpct  numeric;
  v_codtrib text;
  v_codsun  text;
  v_unidad  text;
  v_unidadm text;
  -- factor / tipo derivados
  v_cpb     text := btrim(coalesce(p->>'codigoProductoBase',''));   -- texto SIEMPRE
  v_es_deriv boolean;
  v_es_pres  boolean;
  v_factor  numeric;
  v_fbase   numeric := mos._numn(p->>'factorConversionBase');
  v_tipo    mos.producto_tipo;
  v_modo    text := upper(coalesce(p->>'modoVenta',''));
  v_margen  numeric := mos._numn(p->>'margenPct');
  v_tope    numeric := mos._numn(p->>'precioTope');
  v_dup     record;
  v_inserted int;
  v_sku_in  text;   -- skuBase provisto por el caller (antes de auto-generar) — para derivar es_presentacion como GAS
  v_id_in   text;   -- idProducto provisto por el caller (antes de auto-generar)
begin
  -- 1) kill-switch + gate de claim
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- 2) validaciones obligatorias (paridad GAS)
  if v_desc is null then return jsonb_build_object('ok',false,'error','La descripción es requerida'); end if;
  if v_pv is null or v_pv <= 0 then
    return jsonb_build_object('ok',false,'error','El precio de venta es requerido y debe ser mayor a 0');
  end if;

  -- 3) IDEMPOTENCIA por PK: si el id ya vino y ya existe → dedup (reintento/doble-tap), NO re-crear.
  if v_id is not null and exists (select 1 from mos.productos where id_producto = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,
      'data', jsonb_build_object('idProducto', v_id, 'skuBase', coalesce(v_sku, (select sku_base from mos.productos where id_producto=v_id))));
  end if;

  -- 4) dedup defensivo por codigoBarra (paridad con la validación de duplicado de GAS)
  if v_cod <> '' then
    select id_producto, descripcion into v_dup from mos.productos
      where btrim(coalesce(codigo_barra,'')) = v_cod limit 1;
    if found then
      return jsonb_build_object('ok',false,'error',
        'El código de barras '||v_cod||' ya existe en el producto '||v_dup.id_producto||' ('||coalesce(v_dup.descripcion,'sin descripción')||')');
    end if;
  end if;

  -- capturar lo provisto por el caller ANTES de auto-generar (GAS deriva esPresentacion del skuBase de entrada)
  v_sku_in := v_sku; v_id_in := v_id;

  -- 5) ids secuenciales atómicos si no vinieron (reemplaza _siguienteSecuenciaProducto — SIN lost-update)
  if v_id is null or v_sku is null then
    v_seq := nextval('mos.seq_producto');
    v_pad := lpad(v_seq::text, 7, '0');
    v_id  := coalesce(v_id,  'IDPRO'||v_pad);
    v_sku := coalesce(v_sku, 'LEV'||v_pad);
  end if;

  -- 6) defaults SUNAT/IGV (paridad GAS, incluida la migración de valores legacy gravado/exonerado/inafecto)
  v_tipoigv := case lower(v_tipoigv) when 'gravado' then '1' when 'exonerado' then '2' when 'inafecto' then '3' else v_tipoigv end;
  if v_tipoigv not in ('1','2','3') then v_tipoigv := '1'; end if;
  v_igvpct  := coalesce(mos._numn(p->>'IGV_Porcentaje'), case when v_tipoigv='1' then 18 else 0 end);
  v_codtrib := coalesce(nullif(btrim(coalesce(p->>'Cod_Tributo','')),''),
                        case v_tipoigv when '1' then '1000' when '2' then '9997' when '3' then '9998' else '' end);
  v_codsun  := coalesce(nullif(btrim(coalesce(p->>'Cod_SUNAT','')),''),'10000000');
  -- unidad / Unidad_Medida: si solo vino uno, sincronizar; si ambos distintos, prima Unidad_Medida
  v_unidad  := nullif(btrim(coalesce(p->>'unidad','')),'');
  v_unidadm := nullif(btrim(coalesce(p->>'Unidad_Medida','')),'');
  if v_unidad is not null and v_unidadm is not null and v_unidad <> v_unidadm then
    v_unidad := v_unidadm;
  end if;
  v_unidad  := coalesce(v_unidad, v_unidadm, 'NIU');
  v_unidadm := coalesce(v_unidadm, v_unidad, 'NIU');

  -- 7) factor + tipo DERIVADOS (modelo canónico). factor replica crearProductoMaster; tipo replica el backfill.
  -- esPresentacion replica GAS: !!(params.skuBase && params.skuBase !== id). Usa el skuBase DE ENTRADA
  -- (no el auto-generado, que siempre difiere del id). Si el caller no mandó skuBase → NO es presentación.
  v_es_deriv := (v_cpb <> '');
  v_es_pres  := (v_sku_in is not null and v_sku_in <> coalesce(v_id_in, v_id));
  if v_es_pres then
    v_factor := coalesce(mos._numn(p->>'factorConversion'), 1);
  elsif v_es_deriv then
    v_factor := null;          -- derivado usa factor_conversion_base
  else
    v_factor := 1;             -- base = factor 1
  end if;
  -- tipo_producto (backfill post()): base presente → DERIVADO; factor>0 y <>1 → PRESENTACION; resto → CANONICO
  if v_cpb <> '' then
    v_tipo := 'DERIVADO';
  elsif v_factor is not null and v_factor > 0 and v_factor <> 1 then
    v_tipo := 'PRESENTACION';
  else
    v_tipo := 'CANONICO';
  end if;

  if v_modo not in ('MARGEN','FIJO','COMPETITIVO','LIBRE') then v_modo := null; end if;

  -- 8) INSERT idempotente por PK (on conflict do nothing → carrera/doble-tap no duplica; NO if-exists)
  insert into mos.productos (
    id_producto, sku_base, codigo_barra, descripcion, marca, id_categoria, unidad,
    precio_venta, precio_costo, cod_tributo, igv_porcentaje, cod_sunat, tipo_igv, unidad_medida,
    estado, es_envasable, codigo_producto_base, factor_conversion, factor_conversion_base,
    merma_esperada_pct, stock_minimo, stock_maximo, zona, fecha_creacion, creado_por,
    modo_venta, margen_pct, precio_tope, tipo_producto, created_at, updated_at
  ) values (
    v_id, v_sku, nullif(v_cod,''), v_desc,
    nullif(btrim(coalesce(p->>'marca','')),''),
    nullif(btrim(coalesce(p->>'idCategoria','')),''),
    v_unidad,
    v_pv, coalesce(mos._numn(p->>'precioCosto'),0), v_codtrib, v_igvpct, v_codsun, v_tipoigv::smallint, v_unidadm,
    true,                                                          -- estado='1' en GAS → boolean true
    coalesce((p->>'esEnvasable') in ('1','true','t'), false),     -- '0'/'1' o bool → boolean
    nullif(v_cpb,''), v_factor, v_fbase,
    mos._numn(p->>'mermaEsperadaPct'),
    coalesce(mos._numn(p->>'stockMinimo'),0), coalesce(mos._numn(p->>'stockMaximo'),0),
    nullif(btrim(coalesce(p->>'zona','')),''),
    now(), nullif(btrim(coalesce(p->>'usuario','')),''),
    v_modo, v_margen, v_tope, v_tipo, now(), now()
  )
  on conflict (id_producto) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    -- carrera: otra tx insertó el mismo id_producto entre el check (3) y el insert → dedup
    return jsonb_build_object('ok',true,'dedup',true,
      'data', jsonb_build_object('idProducto', v_id, 'skuBase', v_sku));
  end if;

  -- 9) historial de precios (precio inicial 0 → v_pv) — espeja _registrarHistorialPrecio('Precio inicial')
  insert into mos.historial_precios (id, sku_base, codigo_barra, descripcion, precio_anterior, precio_nuevo, usuario, motivo, app_origen, fecha)
  values ('HP'||replace(now()::text,' ','_')||substr(md5(random()::text),1,4),
          v_sku, nullif(v_cod,''), v_desc, 0, v_pv, nullif(btrim(coalesce(p->>'usuario','')),''), 'Precio inicial', 'MOS', now());

  return jsonb_build_object('ok',true,'dedup',false,
    'data', jsonb_build_object('idProducto', v_id, 'skuBase', v_sku, 'tipo', v_tipo));
end;
$fn$;

revoke all on function mos.crear_producto(jsonb) from public;
grant execute on function mos.crear_producto(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.actualizar_producto(p jsonb) — espeja actualizarProductoMaster (patch parcial, guard no-vaciables, UPDATE atómico)
--   Incluye propagación de precio a presentaciones cuando cambia precioVenta de un CANÓNICO (sin recursión: la
--   propagación es un UPDATE masivo, no llamadas anidadas). Respeta modo_venta FIJO/LIBRE de cada presentación.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.actualizar_producto(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id       text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_codmatch text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_row      record;
  v_pv_new   numeric;
  v_pv_old   numeric;
  v_cambio_precio boolean := false;
  v_pres_upd int := 0;
  v_unidad   text := nullif(btrim(coalesce(p->>'unidad','')),'');
  v_unidadm  text := nullif(btrim(coalesce(p->>'Unidad_Medida','')),'');
  v_es_canon boolean;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- localizar la fila (match por idProducto cuando viene, si no por codigoBarra) — paridad GAS
  if v_id is not null then
    select * into v_row from mos.productos where id_producto = v_id limit 1;
  elsif v_codmatch is not null then
    select * into v_row from mos.productos where btrim(coalesce(codigo_barra,'')) = v_codmatch limit 1;
  else
    return jsonb_build_object('ok',false,'error','Requiere idProducto o codigoBarra');
  end if;
  if not found then return jsonb_build_object('ok',false,'error','Producto no encontrado'); end if;

  -- validación de precioVenta si viene (no 0 ni vacío) — paridad GAS
  if (p ? 'precioVenta') and nullif(btrim(coalesce(p->>'precioVenta','')),'') is not null then
    v_pv_new := mos._numn(p->>'precioVenta');
    if v_pv_new is null or v_pv_new <= 0 then
      return jsonb_build_object('ok',false,'error','El precio de venta no puede ser 0 ni vacío');
    end if;
  end if;

  -- sincronizar unidad/Unidad_Medida (paridad GAS: si solo uno, copiar; si ambos distintos, prima Unidad_Medida)
  if v_unidad is not null and v_unidadm is null then v_unidadm := v_unidad;
  elsif v_unidadm is not null and v_unidad is null then v_unidad := v_unidadm;
  elsif v_unidad is not null and v_unidadm is not null and v_unidad <> v_unidadm then v_unidad := v_unidadm;
  end if;

  v_pv_old := v_row.precio_venta;

  -- UPDATE ATÓMICO sobre la PK (lock de fila implícito → sin lost-update del read-modify-write de GAS).
  -- Cada campo: COALESCE(nuevo_si_presente_y_permitido, valor_actual). Los _camposNoVaciables NO se vacían:
  -- si el patch trae '' para ellos, se ignora (se conserva el valor actual). Campos vaciables (marca, zona,
  -- modo_venta, margen, tope, precio_costo…) sí pueden setearse a vacío si la clave viene presente.
  update mos.productos t set
    -- NO-VACIABLES (skuBase/codigoBarra/descripcion/factor/codigoProductoBase/factorConversionBase/idCategoria/unidad/Unidad_Medida):
    --   solo se cambian si vienen presentes Y no-vacíos.
    sku_base               = case when nullif(btrim(coalesce(p->>'skuBase','')),'') is not null then btrim(p->>'skuBase') else t.sku_base end,
    codigo_barra           = case when nullif(btrim(coalesce(p->>'codigoBarra','')),'') is not null then btrim(p->>'codigoBarra') else t.codigo_barra end,
    descripcion            = case when nullif(btrim(coalesce(p->>'descripcion','')),'') is not null then btrim(p->>'descripcion') else t.descripcion end,
    id_categoria           = case when nullif(btrim(coalesce(p->>'idCategoria','')),'') is not null then btrim(p->>'idCategoria') else t.id_categoria end,
    unidad                 = coalesce(v_unidad, t.unidad),
    unidad_medida          = coalesce(v_unidadm, t.unidad_medida),
    codigo_producto_base   = case when nullif(btrim(coalesce(p->>'codigoProductoBase','')),'') is not null then btrim(p->>'codigoProductoBase') else t.codigo_producto_base end,
    factor_conversion      = case when nullif(btrim(coalesce(p->>'factorConversion','')),'') is not null then mos._numn(p->>'factorConversion') else t.factor_conversion end,
    factor_conversion_base = case when nullif(btrim(coalesce(p->>'factorConversionBase','')),'') is not null then mos._numn(p->>'factorConversionBase') else t.factor_conversion_base end,
    -- VACIABLES (clave presente → se aplica, aunque sea vacío/0):
    marca                  = case when p ? 'marca'          then nullif(btrim(coalesce(p->>'marca','')),'')      else t.marca end,
    precio_venta           = case when v_pv_new is not null then v_pv_new                                         else t.precio_venta end,
    precio_costo           = case when p ? 'precioCosto'    then mos._numn(p->>'precioCosto')                     else t.precio_costo end,
    cod_tributo            = case when p ? 'Cod_Tributo'    then nullif(btrim(coalesce(p->>'Cod_Tributo','')),'') else t.cod_tributo end,
    igv_porcentaje         = case when p ? 'IGV_Porcentaje' then mos._numn(p->>'IGV_Porcentaje')                  else t.igv_porcentaje end,
    cod_sunat              = case when p ? 'Cod_SUNAT'      then nullif(btrim(coalesce(p->>'Cod_SUNAT','')),'')   else t.cod_sunat end,
    tipo_igv               = case when nullif(btrim(coalesce(p->>'Tipo_IGV','')),'') is not null
                                  and (p->>'Tipo_IGV') in ('1','2','3') then (p->>'Tipo_IGV')::smallint else t.tipo_igv end,
    estado                 = case when p ? 'estado'      then ((p->>'estado')      in ('1','true','t')) else t.estado end,
    es_envasable           = case when p ? 'esEnvasable' then ((p->>'esEnvasable') in ('1','true','t')) else t.es_envasable end,
    merma_esperada_pct     = case when p ? 'mermaEsperadaPct' then mos._numn(p->>'mermaEsperadaPct') else t.merma_esperada_pct end,
    stock_minimo           = case when p ? 'stockMinimo' then mos._numn(p->>'stockMinimo') else t.stock_minimo end,
    stock_maximo           = case when p ? 'stockMaximo' then mos._numn(p->>'stockMaximo') else t.stock_maximo end,
    zona                   = case when p ? 'zona'        then nullif(btrim(coalesce(p->>'zona','')),'') else t.zona end,
    modo_venta             = case when p ? 'modoVenta'
                                  then (case when upper(coalesce(p->>'modoVenta','')) in ('MARGEN','FIJO','COMPETITIVO','LIBRE')
                                             then upper(p->>'modoVenta') else null end)
                                  else t.modo_venta end,
    margen_pct             = case when p ? 'margenPct'  then mos._numn(p->>'margenPct')  else t.margen_pct end,
    precio_tope            = case when p ? 'precioTope' then mos._numn(p->>'precioTope') else t.precio_tope end,
    updated_at             = now()
  where id_producto = v_row.id_producto;

  -- Normalizar: si tras el update es CANÓNICO (sin base) y factor quedó NULL → setear 1 (modelo normalizado, paridad GAS)
  update mos.productos set factor_conversion = 1
   where id_producto = v_row.id_producto
     and coalesce(btrim(codigo_producto_base),'') = ''
     and factor_conversion is null;

  -- Recalcular tipo_producto (la sombra DEBE quedar consistente; backfill post() rule)
  update mos.productos set tipo_producto =
    case when coalesce(btrim(codigo_producto_base),'') <> '' then 'DERIVADO'::mos.producto_tipo
         when factor_conversion is not null and factor_conversion > 0 and factor_conversion <> 1 then 'PRESENTACION'::mos.producto_tipo
         else 'CANONICO'::mos.producto_tipo end
   where id_producto = v_row.id_producto;

  -- ¿cambió el precio? (tolerancia 0.001 como _valoresIguales de GAS)
  v_cambio_precio := (v_pv_new is not null) and (v_pv_old is null or abs(v_pv_new - v_pv_old) >= 0.001);

  if v_cambio_precio then
    -- historial de precios
    insert into mos.historial_precios (id, sku_base, codigo_barra, descripcion, precio_anterior, precio_nuevo, usuario, motivo, app_origen, fecha)
    select 'HP'||replace(now()::text,' ','_')||substr(md5(random()::text),1,4),
           t.sku_base, t.codigo_barra, t.descripcion, v_pv_old, v_pv_new,
           nullif(btrim(coalesce(p->>'usuario','')),''),
           coalesce(nullif(btrim(coalesce(p->>'motivoPrecio','')),''),'Actualización'), 'MOS', now()
      from mos.productos t where t.id_producto = v_row.id_producto;

    -- propagar a presentaciones SOLO si el producto actualizado es CANÓNICO y NO se pidió no-propagar
    select (coalesce(btrim(codigo_producto_base),'') = ''
            and (factor_conversion is null or factor_conversion = 1)) into v_es_canon
      from mos.productos where id_producto = v_row.id_producto;
    if v_es_canon and not coalesce((p->>'_noPropagar')::boolean, false) then
      v_pres_upd := mos._propagar_precio(v_row.sku_base, v_row.id_producto, v_pv_new,
                                         nullif(btrim(coalesce(p->>'usuario','')),''),
                                         nullif(btrim(coalesce(p->>'motivoPrecio','')),''));
    end if;
  end if;

  return jsonb_build_object('ok',true,'data', jsonb_build_object('presentacionesActualizadas', v_pres_upd));
end;
$fn$;

revoke all on function mos.actualizar_producto(jsonb) from public;
grant execute on function mos.actualizar_producto(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- mos._propagar_precio(...) — espeja _propagarPrecioVentaAPresentaciones (UPDATE atómico masivo, sin recursión)
--   Presentaciones = mismo sku_base, distinto id, SIN codigo_producto_base, factor>0 y <>1, modo_venta NOT IN (FIJO,LIBRE).
--   precio_pres = round(precio_canon * factor, 2). Solo aplica si precio_pres > 0.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos._propagar_precio(p_sku text, p_id_canon text, p_precio numeric, p_usuario text, p_motivo text)
returns int
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_n int := 0;
begin
  if p_sku is null or p_precio is null or p_precio <= 0 then return 0; end if;

  -- snapshot de las presentaciones afectadas para el historial (antes de actualizar)
  with afect as (
    select id_producto, sku_base, codigo_barra, descripcion, precio_venta as antes,
           round(p_precio * factor_conversion, 2) as nuevo
      from mos.productos
     where upper(sku_base) = upper(p_sku)
       and upper(id_producto) <> upper(p_id_canon)
       and coalesce(btrim(codigo_producto_base),'') = ''
       and factor_conversion is not null and factor_conversion > 0 and factor_conversion <> 1
       and upper(coalesce(modo_venta,'')) not in ('FIJO','LIBRE')
       and round(p_precio * factor_conversion, 2) > 0
  ),
  upd as (
    update mos.productos t set precio_venta = a.nuevo, updated_at = now()
      from afect a where t.id_producto = a.id_producto
      returning t.id_producto
  ),
  hist as (
    insert into mos.historial_precios (id, sku_base, codigo_barra, descripcion, precio_anterior, precio_nuevo, usuario, motivo, app_origen, fecha)
    select 'HP'||replace(now()::text,' ','_')||substr(md5(random()::text||a.id_producto),1,4),
           a.sku_base, a.codigo_barra, a.descripcion, a.antes, a.nuevo,
           p_usuario, 'Propagado desde canónico '||coalesce(p_id_canon,'')||coalesce(' · '||p_motivo,''), 'MOS', now()
      from afect a
    returning 1
  )
  select count(*) into v_n from upd;
  return coalesce(v_n,0);
end;
$fn$;

revoke all on function mos._propagar_precio(text,text,numeric,text,text) from public;
grant execute on function mos._propagar_precio(text,text,numeric,text,text) to service_role;  -- interno: solo lo llama actualizar_producto (security definer)

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.publicar_precio(p jsonb) — espeja publicarPrecio (persistencia del precio + propagación).
--   ⚠ Los SIDE-EFFECTS de impresión de GAS (etiquetas/membretes/alertas PrintNode) NO van acá: quedan en
--     GAS/Edge (B5). Esta RPC SOLO persiste el precio (delega en actualizar_producto, que ya propaga).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.publicar_precio(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_pn   numeric := mos._numn(p->>'precioNuevo');
  v_id   text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_cod  text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_patch jsonb;
  v_res  jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_pn is null or v_pn <= 0 then return jsonb_build_object('ok',false,'error','Requiere precioNuevo válido'); end if;
  if v_id is null and v_cod is null and v_sku is null then
    return jsonb_build_object('ok',false,'error','Requiere idProducto, codigoBarra o skuBase');
  end if;

  -- delega en actualizar_producto (UPDATE atómico + propagación + historial). Reusa el mismo gate/flag.
  v_patch := jsonb_build_object(
    'precioVenta', v_pn::text,
    'usuario',     coalesce(p->>'usuario',''),
    'motivoPrecio', coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'Publicación de precio')
  );
  if v_id  is not null then v_patch := v_patch || jsonb_build_object('idProducto', v_id); end if;
  if v_cod is not null then v_patch := v_patch || jsonb_build_object('codigoBarra', v_cod); end if;

  v_res := mos.actualizar_producto(v_patch);
  if not (v_res->>'ok')::boolean then return v_res; end if;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'precioNuevo', v_pn,
    'presentacionesActualizadas', coalesce((v_res->'data'->>'presentacionesActualizadas')::int, 0)
    -- NOTA: alertaGenerada/etiquetas NO se devuelven: la impresión es side-effect de GAS/Edge, no de la RPC.
  ));
end;
$fn$;

revoke all on function mos.publicar_precio(jsonb) from public;
grant execute on function mos.publicar_precio(jsonb) to service_role, authenticated;
