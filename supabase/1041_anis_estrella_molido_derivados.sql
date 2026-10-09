-- 1041 · ANIS ESTRELLA MOLIDO GRANEL (LEV121 / WHANEODO) recupera sus 3 derivados (250GR · 50GR · 5GR)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- APLICADO 2026-10-09. Dueño: incluir el ENTERO 5GR, dejar las presentaciones 5 g, envases sin elegir (los elige en MOS).
--
-- CAUSA RAÍZ
--   La migración MIGRACION_ME (filas creadas 2026-06-08, fecha_creacion 2026-04-11) trajo la familia
--   "ANIS ESTRELLA MOLIDO" sin el vínculo de derivado: LEV1317/LEV1316/LEV1608 quedaron CANONICO con
--   codigo_producto_base NULL y factor_conversion_base NULL, y el granel LEV121 quedó es_envasable=false.
--   warehouseMos (js/app.js · EnvasadorView._buildCatalog) solo lista como "base" a los productos con
--   esEnvasable='1' y le cuelga los hijos con codigoProductoBase === base.skuBase|idProducto; además
--   descarta la base si no tiene hijos. Con los datos actuales el molido no cumple NINGUNA de las dos.
--   En MOS el catálogo los agrupa por codigo_producto_base → por eso "salen aparte".
--
-- QUÉ ES UN DERIVADO EN ESTE SISTEMA (modelo vivo, ver mos.actualizar_producto)
--   · codigo_producto_base = sku_base del granel  → tipo_producto se recalcula a 'DERIVADO'
--   · factor_conversion_base = kg del granel por 1 unidad del derivado (0.25 / 0.05 / 0.005).
--     No se parsea el nombre: wh.registrar_envasado recibe cantidad_base del front, y el front la
--     calcula con factorConversionBase (posibles = floor(stockBase / factorBase)).
--   · factor_conversion = 1 (el derivado tiene SU PROPIO sku_base y SU PROPIO stock por codigo_barra).
--   · envase_sku = sku del insumo (celofán) que wh.registrar_envasado descuenta por millar. NULL = "falta elegir"
--     (nunca bloquea el envasado).
--   · es_envasable = true en el GRANEL (no en el derivado).
--
-- POR QUÉ UPDATE DIRECTO Y NO mos.actualizar_producto
--   La RPC exige mos._claim_ok() (JWT de app) y no escribe historial_cambios. Este script replica
--   EXACTAMENTE su regla de tipo_producto y agrega historial_cambios con el formato de MOS_MODAL_PRODUCTO
--   (cap 50, igual que mos.aplicar_costos_compra). No se tocan descripcion/codigo_barra/categoria_ia/marca
--   → no se disparan tg_herencia_ficha / tg_herencia_cascada / tg_producto_cb_unico.
--   tg_touch_updated_at sube updated_at (delta de catálogo WH/MOS) y tg_bump_catversion invalida la caché
--   del POS al COMMIT.
--
-- EFECTO EN DINERO / STOCK (verificado en vivo 2026-10-09)
--   · Stock: NO se mueve nada. wh.stock y me.stock_zonas van por codigo_barra, que no cambia.
--   · Ventas: me.ventas_detalle no se toca. mos._venta_canonico resuelve por sku_base+factor_conversion
--     (ambos intactos) → los derivados siguen descontando SU stock, no el granel.
--   · Precio: mos._propagar_precio es NO-OP [772] → el precio del granel no arrastra a los derivados.
--   · POS ME: es_envasable=true NO oculta el granel (vendible compara contra '1' y el boolean es 'true';
--     probado: WHANENRO, envasable, sigue en la caché del POS).
--   · Demanda: mos.almacen_demanda_envasable / mos.granel_demanda_derivados empezarán a sumar la deuda de
--     los 3 derivados al granel LEV121 (efecto deseado).
-- ────────────────────────────────────────────────────────────────────────────────────────────────

begin;

do $$
declare
  -- ══ DECISIONES DEL DUEÑO ══════════════════════════════════════════════════════════════════════
  -- (A) Caso hermano: ANIS ESTRELLA ENTERO 5GR (LEV1607 / WAANENRO005GR) → derivado de LEV004 (0.005 kg).
  c_incluir_entero_5gr boolean := true;    -- dueño 09-oct: sí (arreglar todos)
  -- (B) Presentación "· 5 g" del granel (P-ANSES0-D200 y, si (A), P-ANSEST-D200): se APAGA (estado=false,
  --     nunca DELETE: hay ventas históricas que la referencian por cod_barras). Recomendado = true si el 5 g
  --     se vende como bolsita envasada (WA...005GR) y no como porción servida del granel en mostrador.
  c_desactivar_pres_5g boolean := false;   -- dueño 09-oct: dejar ambas (la porción 5 g se sirve del granel)
  -- ═════════════════════════════════════════════════════════════════════════════════════════════

  c_usr  constant text := 'MASTER';
  c_src  constant text := 'SQL_1041';
  c_mot  constant text := 'Vincular derivado a su granel (venía suelto de la migración; no aparecía para envasar en WH)';
  v_ts   text := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  r      record;
  v_n    int;
  v_hist jsonb;
begin
  -- ── 0. Bloqueo + guardas de estado vivo (si algo cambió desde el diagnóstico, aborta TODO) ──────
  perform 1 from mos.productos
   where id_producto in ('IDPRO0000138','IDPRO0000134','IDPRO0000135','IDPRO0000136','IDPRO0000137',
                         'IDPRO0000133','IDPRO0001822','IDPRO0001699')
   order by id_producto for update;

  -- Granel molido: canónico KGM factor 1, activo
  perform 1 from mos.productos
   where id_producto='IDPRO0000138' and sku_base='LEV121' and codigo_barra='WHANEODO'
     and tipo_producto::text='CANONICO' and upper(coalesce(unidad_medida,''))='KGM'
     and coalesce(nullif(factor_conversion,0),1)=1 and coalesce(estado,true)
     and coalesce(nullif(btrim(codigo_producto_base),''),'')='';
  if not found then raise exception '[1041] el granel LEV121/WHANEODO no está en el estado esperado'; end if;

  -- Granel entero (solo si se incluye el caso hermano)
  if c_incluir_entero_5gr then
    perform 1 from mos.productos
     where id_producto='IDPRO0000134' and sku_base='LEV004' and codigo_barra='WHANENRO'
       and tipo_producto::text='CANONICO' and upper(coalesce(unidad_medida,''))='KGM' and es_envasable;
    if not found then raise exception '[1041] el granel LEV004/WHANENRO no está en el estado esperado'; end if;
  end if;

  -- ── 1. Derivados: canónico suelto → DERIVADO del granel ────────────────────────────────────────
  for r in
    select * from (values
      -- id_producto,    sku_base,  codigo_barra,     base,     kg/u,   envase (= el del hermano ENTERO del mismo tamaño)
      ('IDPRO0000135', 'LEV1317', 'WHANEODO250GR', 'LEV121', 0.2500::numeric, null),  -- envase: el dueño lo elige en MOS
      ('IDPRO0000136', 'LEV1316', 'WHANEODO050GR', 'LEV121', 0.0500::numeric, null),  -- envase: el dueño lo elige en MOS
      ('IDPRO0000137', 'LEV1608', 'WAANEODO005GR', 'LEV121', 0.0050::numeric, null),       -- envase: elegir en MOS
      ('IDPRO0000133', 'LEV1607', 'WAANENRO005GR', 'LEV004', 0.0050::numeric, null)        -- (A) caso hermano
    ) as x(id, sku, cb, base, fcb, env)
    where x.sku <> 'LEV1607' or c_incluir_entero_5gr
  loop
    -- guarda por fila: canónico NIU suelto, único miembro de su sku_base (sin presentaciones colgando)
    select count(*) into v_n from mos.productos where sku_base = r.sku;
    if v_n <> 1 then raise exception '[1041] % tiene % filas con su sku_base (esperado 1)', r.sku, v_n; end if;

    v_hist := jsonb_build_object(
      'ts', v_ts, 'accion', 'editar', 'source', c_src, 'usuario', c_usr, 'motivo', c_mot,
      'cambios', jsonb_build_array(
        jsonb_build_object('campo','codigoProductoBase',   'antes', null,       'despues', r.base),
        jsonb_build_object('campo','factorConversionBase', 'antes', null,       'despues', r.fcb),
        jsonb_build_object('campo','tipoProducto',         'antes', 'CANONICO', 'despues', 'DERIVADO'))
        || case when r.env is not null
                then jsonb_build_array(jsonb_build_object('campo','envaseSku','antes', null, 'despues', r.env))
                else '[]'::jsonb end);

    update mos.productos t set
      codigo_producto_base   = r.base,
      factor_conversion_base = r.fcb,
      factor_conversion      = 1,
      tipo_producto          = 'DERIVADO'::mos.producto_tipo,   -- misma regla que mos.actualizar_producto
      envase_sku             = coalesce(t.envase_sku, r.env),
      historial_cambios      = case
        when jsonb_typeof(t.historial_cambios) = 'array' and jsonb_array_length(t.historial_cambios) >= 50 then
          (select jsonb_agg(e order by ord)
             from jsonb_array_elements(t.historial_cambios || v_hist) with ordinality x(e, ord) where ord > 1)
        when jsonb_typeof(t.historial_cambios) = 'array' then t.historial_cambios || v_hist
        else jsonb_build_array(v_hist) end
    where t.id_producto = r.id and t.sku_base = r.sku and t.codigo_barra = r.cb
      and t.tipo_producto::text = 'CANONICO'
      and coalesce(nullif(btrim(t.codigo_producto_base),''),'') = ''
      and t.factor_conversion_base is null
      and upper(coalesce(t.unidad_medida,'')) = 'NIU';
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception '[1041] % (%) no está en el estado esperado; nada aplicado', r.sku, r.cb; end if;
  end loop;

  -- ── 2. Granel molido pasa a envasable ─────────────────────────────────────────────────────────
  v_hist := jsonb_build_object('ts', v_ts, 'accion', 'editar', 'source', c_src, 'usuario', c_usr, 'motivo', c_mot,
              'cambios', jsonb_build_array(jsonb_build_object('campo','esEnvasable','antes', 0, 'despues', 1)));
  update mos.productos t set
    es_envasable      = true,
    historial_cambios = case
      when jsonb_typeof(t.historial_cambios) = 'array' and jsonb_array_length(t.historial_cambios) >= 50 then
        (select jsonb_agg(e order by ord)
           from jsonb_array_elements(t.historial_cambios || v_hist) with ordinality x(e, ord) where ord > 1)
      when jsonb_typeof(t.historial_cambios) = 'array' then t.historial_cambios || v_hist
      else jsonb_build_array(v_hist) end
  where t.id_producto = 'IDPRO0000138' and coalesce(t.es_envasable,false) = false;
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception '[1041] LEV121 ya era envasable o no se encontró'; end if;

  -- ── 3. (B) Apagar la presentación "· 5 g" del granel (duplica al derivado 5GR) ─────────────────
  if c_desactivar_pres_5g then
    for r in
      select * from (values ('IDPRO0001822','P-ANSES0-D200', true),
                            ('IDPRO0001699','P-ANSEST-D200', c_incluir_entero_5gr)) x(id, cb, aplica)
      where x.aplica
    loop
      v_hist := jsonb_build_object('ts', v_ts, 'accion', 'editar', 'source', c_src, 'usuario', c_usr,
                  'motivo', 'Presentación 5 g del granel apagada: el 5 g se vende como derivado envasado (WA...005GR)',
                  'cambios', jsonb_build_array(jsonb_build_object('campo','estado','antes', 1, 'despues', 0)));
      update mos.productos t set
        estado = false,
        historial_cambios = case when jsonb_typeof(t.historial_cambios) = 'array'
                                 then t.historial_cambios || v_hist else jsonb_build_array(v_hist) end
      where t.id_producto = r.id and t.codigo_barra = r.cb and t.tipo_producto::text = 'PRESENTACION'
        and coalesce(t.estado, true);
      get diagnostics v_n = row_count;
      if v_n <> 1 then raise exception '[1041] presentación % no está activa / no coincide', r.cb; end if;
    end loop;
  end if;
end $$;

-- ── 4. Verificación (lo que verá el Envasador de WH: base envasable + hijos + posibles con stock WH) ──
select b.codigo_barra as base_cod, b.descripcion as base, coalesce(s.cantidad_disponible,0) as stock_base_kg,
       d.codigo_barra as deriv_cod, d.descripcion as derivado, d.tipo_producto, d.factor_conversion_base as kg_por_u,
       d.envase_sku,
       floor(coalesce(s.cantidad_disponible,0) / nullif(d.factor_conversion_base,0)) as posibles
  from mos.productos b
  join mos.productos d on d.codigo_producto_base in (b.sku_base, b.id_producto) and coalesce(d.estado,true)
  left join wh.stock s on s.cod_producto = b.codigo_barra
 where b.es_envasable and coalesce(b.estado,true) and b.sku_base in ('LEV121','LEV004')
 order by b.sku_base, d.factor_conversion_base desc;

commit;

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- ROLLBACK (exacto al estado del 2026-10-09; quita solo las entradas SQL_1041 del historial)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- begin;
-- update mos.productos set
--        codigo_producto_base = null, factor_conversion_base = null, factor_conversion = 1,
--        tipo_producto = 'CANONICO'::mos.producto_tipo, envase_sku = null,
--        historial_cambios = (select jsonb_agg(e) from jsonb_array_elements(historial_cambios) e
--                              where e->>'source' is distinct from 'SQL_1041')
--  where id_producto in ('IDPRO0000135','IDPRO0000136','IDPRO0000137','IDPRO0000133')
--    and historial_cambios @> '[{"source":"SQL_1041"}]';
-- update mos.productos set es_envasable = false,
--        historial_cambios = (select jsonb_agg(e) from jsonb_array_elements(historial_cambios) e
--                              where e->>'source' is distinct from 'SQL_1041')
--  where id_producto = 'IDPRO0000138' and historial_cambios @> '[{"source":"SQL_1041"}]';
-- update mos.productos set estado = true,
--        historial_cambios = (select jsonb_agg(e) from jsonb_array_elements(historial_cambios) e
--                              where e->>'source' is distinct from 'SQL_1041')
--  where id_producto in ('IDPRO0001822','IDPRO0001699') and historial_cambios @> '[{"source":"SQL_1041"}]';
-- commit;
-- Nota rollback: si entre medio alguien ENVASÓ molido en WH, esos envasados (wh.envasados + guías + kardex)
-- quedan válidos; el rollback solo deshace el vínculo de catálogo, no revierte stock.
