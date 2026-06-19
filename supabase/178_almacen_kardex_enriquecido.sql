-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 178_almacen_kardex_enriquecido.sql — HISTORIAL DE ALMACÉN: + HORA, + LOTE (ingresos), + ZONA destino (salidas)
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- Pedido del dueño: en el historial de cada producto mostrar, por movimiento:
--   · HORA (ya viene: 'fecha' es timestamptz; el front la formatea en America/Lima).
--   · LOTE (FIFO): el lote CREADO por un INGRESO (envasado/guía). El consumo FIFO por salida NO se registra
--     por movimiento en los datos actuales (guia_detalle.id_lote casi siempre NULL, lotes_historial vacía),
--     así que el lote sólo es atable en INGRESOS. Para salidas se omite el chip de lote (el front muestra los
--     lotes ACTIVOS del producto en el pie como contexto FIFO).
--   · ZONA destino + QUIÉN en SALIDAS: zona desde wh.guias.id_zona (autoritativo); usuario ya venía.
--
-- 🔗 FORMA REAL DE UNIR MOVIMIENTO ↔ LOTE (verificada contra los datos de prod):
--   INGRESO de guía proveedor:  wh.lotes_vencimiento.id_guia = mov.origen  AND cod_producto  (origen='G…')
--   INGRESO por envasado:       NO comparte id con la guía. El lote se ata por
--                                 cod_producto + cantidad_inicial = delta + |fecha_creacion − mov.fecha| ≤ 120s
--                               (cubre ~96% de los envasados; el resto degrada sin chip → pie de lotes activos).
--   SALIDA:                     lote consumido NO registrado → no se ata; se muestra zona+usuario.
--
-- 🟢 SOLO LECTURA · additivo · idempotente (create or replace). NO toca escritura, stock, dinero, flags ni sync.
--    Mantiene EXACTAMENTE el shape previo y SÓLO agrega claves nuevas: idLote, loteVencimiento, zona, destino.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function mos.almacen_kardex_historial(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_cod   text := nullif(btrim(coalesce(p->>'codBarra','')),'');
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_codes text[];
  v_movs  jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- Resolver el conjunto de códigos: WH solo maneja canónicos (codigo_barra) + equivalentes activos.
  if v_cod is not null then
    select coalesce(array_agg(distinct c), array[v_cod]) into v_codes
      from (
        select v_cod as c
        union all
        select upper(btrim(ev.codigo_barra))
          from mos.equivalencias ev
         where coalesce(ev.activo,true)
           and ev.sku_base in (select pr.sku_base from mos.productos pr where pr.codigo_barra = v_cod)
           and nullif(btrim(ev.codigo_barra),'') is not null
      ) q;
  elsif v_sku is not null then
    select coalesce(array_agg(distinct c), array[]::text[]) into v_codes
      from (
        select pr.codigo_barra c from mos.productos pr where pr.sku_base = v_sku and pr.codigo_barra is not null
        union all
        select upper(btrim(ev.codigo_barra)) from mos.equivalencias ev
         where coalesce(ev.activo,true) and ev.sku_base = v_sku and nullif(btrim(ev.codigo_barra),'') is not null
      ) q;
    if coalesce(array_length(v_codes,1),0) = 0 then
      return jsonb_build_object('ok', false, 'error', 'skuBase sin codigo_barra en catálogo');
    end if;
    v_cod := v_codes[1];
  else
    return jsonb_build_object('ok', false, 'error', 'Requiere codBarra o skuBase');
  end if;

  select coalesce(jsonb_agg(row order by row_fecha desc, row_id desc), '[]'::jsonb) into v_movs
  from (
    select
      m.fecha as row_fecha,
      m.id_mov as row_id,
      jsonb_build_object(
        'idGuia',        coalesce(m.origen,''),
        'fecha',         m.fecha,
        'tipo',          me._kardex_label(
                            case
                              when upper(coalesce(m.tipo_operacion,'')) like '%AUDITORIA%' then 'AUDITORIA'
                              when upper(coalesce(m.tipo_operacion,'')) like '%AJUSTE%'    then 'AJUSTE'
                              when upper(coalesce(m.tipo_operacion,'')) like '%ENVASADO%'  then 'ENVASADO'
                              when upper(coalesce(m.tipo_operacion,'')) like '%INICIAL%'   then 'INICIAL'
                              else (case when coalesce(m.delta,0) >= 0 then 'INGRESO' else 'SALIDA' end)
                            end, coalesce(m.delta,0)),
        'tipoOperacion', coalesce(m.tipo_operacion,''),
        'esIngreso',     (coalesce(m.delta,0) > 0),
        'cantidad',      abs(coalesce(m.delta,0)),
        'saldo',         m.stock_despues,
        'stockAntes',    m.stock_antes,
        'usuario',       coalesce(nullif(btrim(m.usuario),''),'—'),
        'origen',        coalesce(m.origen,''),
        'estado',        'CERRADA',
        'fuente',        case when upper(coalesce(m.tipo_operacion,'')) like '%AJUSTE%'
                               or upper(coalesce(m.tipo_operacion,'')) like '%AUDITORIA%' then 'ajuste' else 'guia' end,
        'aplicado',      true,
        -- ── LOTE (sólo INGRESOS, donde es atable) ────────────────────────────────────────────────────────────
        'idLote',          lote.id_lote,
        'loteVencimiento', lote.fecha_vencimiento,
        -- ── ZONA destino (sólo SALIDAS hacia zona; '' si no aplica / sin zona conocida) ───────────────────────
        'zona',          case when coalesce(m.delta,0) < 0 then mos._norm_zona_almacen(g.id_zona) else '' end,
        'destino',       case when coalesce(m.delta,0) < 0 then mos._norm_zona_almacen(g.id_zona) else '' end
      ) as row
    from wh.stock_movimientos m
    -- guía de la salida → zona destino + usuario autoritativo
    left join wh.guias g
           on coalesce(m.delta,0) < 0 and g.id_guia = m.origen
    -- lote del INGRESO: (1) por id_guia (proveedor) ó (2) por cod+cantidad+ventana de fecha (envasado).
    left join lateral (
      select lv.id_lote,
             case when lv.fecha_vencimiento is not null
                  then to_char(lv.fecha_vencimiento, 'YYYY-MM-DD"T"HH24:MI:SSOF') else null end as fecha_vencimiento
        from wh.lotes_vencimiento lv
       where coalesce(m.delta,0) > 0
         and btrim(lv.cod_producto) = btrim(m.cod_producto)
         and (
               lv.id_guia = m.origen
               or (lv.cantidad_inicial = m.delta
                   and abs(extract(epoch from (lv.fecha_creacion - m.fecha))) <= 120)
             )
       order by (lv.id_guia = m.origen) desc,   -- preferimos el match exacto por guía
                abs(extract(epoch from (coalesce(lv.fecha_creacion, m.fecha) - m.fecha))) asc
       limit 1
    ) lote on true
    where btrim(m.cod_producto) = any(v_codes)
  ) s;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'ambito', 'ALMACEN', 'codBarra', v_cod, 'codBarras', to_jsonb(v_codes), 'skuBase', v_sku,
      'reconstruido', false, 'totalMovimientos', jsonb_array_length(v_movs),
      'movimientos', v_movs)) || mos._frescura_sombra();
end;
$function$;

-- Normaliza el código de zona crudo de wh.guias a etiqueta legible y estable.
-- Tolera variantes históricas (z001/Z001/z002/ALMACEN/vacío). '' si no hay zona conocida.
create or replace function mos._norm_zona_almacen(p_raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when nullif(btrim(coalesce(p_raw,'')),'') is null then ''
    when upper(btrim(p_raw)) = 'ALMACEN' then ''
    when upper(btrim(p_raw)) = 'Z001' then 'ZONA-01'
    when upper(btrim(p_raw)) = 'Z002' then 'ZONA-02'
    else upper(btrim(p_raw))
  end;
$$;

revoke all on function mos.almacen_kardex_historial(jsonb) from public;
grant execute on function mos.almacen_kardex_historial(jsonb) to service_role, authenticated;
revoke all on function mos._norm_zona_almacen(text) from public;
grant execute on function mos._norm_zona_almacen(text) to service_role, authenticated;
