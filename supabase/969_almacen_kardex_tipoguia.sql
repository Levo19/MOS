-- [969] _almacen_kardex_movs: exponer el TIPO REAL de la guía en cada movimiento (tipoGuia). Un CIERRE_GUIA
--  es la APLICACIÓN de una guía al stock (usuario sistema-cierre-idem/-21h = proceso automático), NO un
--  "cierre de día". Antes el front veía usuario=cierre y lo pintaba "🌙 Cierre del día" (confuso: era un
--  ingreso de proveedor). Ahora traemos g.tipo (INGRESO_PROVEEDOR, SALIDA_ZONA, SALIDA_ENVASADO...) para que
--  la fila diga el nombre real y abra la guía. El join a wh.guias ahora es para TODO movimiento con origen=guía
--  (antes solo salidas); zona/destino siguen limitados a salidas (sin cambio de comportamiento).
create or replace function mos._almacen_kardex_movs(v_codes text[])
 returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_movs jsonb := '[]'::jsonb;
begin
  if v_codes is null or coalesce(array_length(v_codes,1),0) = 0 then
    return '[]'::jsonb;
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
        'tipoGuia',      coalesce(g.tipo,''),
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
        'idLote',          lote.id_lote,
        'loteVencimiento', lote.fecha_vencimiento,
        'zona',          case when coalesce(m.delta,0) < 0 then mos._norm_zona_almacen(g.id_zona) else '' end,
        'destino',       case when coalesce(m.delta,0) < 0 then mos._norm_zona_almacen(g.id_zona) else '' end
      ) as row
    from wh.stock_movimientos m
    -- guía del movimiento → tipo real (+ zona destino/usuario en salidas)
    left join wh.guias g on g.id_guia = m.origen
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
       order by (lv.id_guia = m.origen) desc,
                abs(extract(epoch from (coalesce(lv.fecha_creacion, m.fecha) - m.fecha))) asc
       limit 1
    ) lote on true
    where btrim(m.cod_producto) = any(v_codes)
  ) s;

  return v_movs;
end;
$function$;
select '969 _almacen_kardex_movs + tipoGuia listo' as ok;
