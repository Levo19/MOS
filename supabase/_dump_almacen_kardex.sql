CREATE OR REPLACE FUNCTION mos.almacen_kardex_historial(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cod   text := nullif(btrim(coalesce(p->>'codBarra','')),'');
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_codes text[];
  v_movs  jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- Resolver el conjunto de códigos: WH solo maneja canónicos (codigo_barra) + equivalentes activos.
  if v_cod is not null then
    -- incluir equivalentes que cuelgan del mismo sku_base de este código (grupo multi-barcode de WH)
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

  select coalesce(jsonb_agg(jsonb_build_object(
      'idGuia',        coalesce(m.origen,''),                         -- origen = idGuia para movs de guía
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
      'idLote',        null
    ) order by m.fecha desc, m.id_mov desc), '[]'::jsonb) into v_movs
  from wh.stock_movimientos m
  where btrim(m.cod_producto) = any(v_codes);

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'ambito', 'ALMACEN', 'codBarra', v_cod, 'codBarras', to_jsonb(v_codes), 'skuBase', v_sku,
      'reconstruido', false, 'totalMovimientos', jsonb_array_length(v_movs),
      'movimientos', v_movs)) || mos._frescura_sombra();
end;
$function$
