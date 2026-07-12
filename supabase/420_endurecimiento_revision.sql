-- ════════════════════════════════════════════════════════════════════════════
-- 420 · Endurecimiento post-revisión 100x (envasado colab + crédito planilla)
-- ════════════════════════════════════════════════════════════════════════════
-- Corrige hallazgos HIGH/MED de la revisión adversarial de SQL 418/419:
--   HIGH3: mos.finanzas_rango contaba un ticket flipeado a PLANILLA como venta
--          (bucket 'else total') → la compensación contra jornal inflaba las
--          ventas netas de un día pasado. Fix: excluir 'PLANILLA' del cómputo de
--          ventas (una nota de crédito descontada NO es plata que entró a caja).
--   HIGH4: editar/anular un envasado COLABORATIVO cuando el día de algún
--          participante ya está PAGADA/VETADA rompía la paridad (el sellado no
--          recomputa, el otro sí → el negocio paga 1.5×). Fix: trigger BEFORE que
--          bloquea la mutación relevante-al-pago si un participante está sellado.
--   LOW9:  índice de créditos sobre la expresión REAL consultada (btrim).
-- (HIGH1/HIGH2/LOW11 y MED5/MED6 van en 418/419 re-aplicados.)
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION mos.finanzas_rango(p_desde text, p_hasta text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_margen numeric := 20;
  v_data   jsonb;
begin
  select valor::numeric into v_margen
  from mos.config
  where clave = 'finMargenDefault' and valor ~ '^[0-9]+(\.[0-9]+)?$';
  if v_margen is null or v_margen < 0 or v_margen >= 100 then v_margen := 20; end if;

  with dias as (
    select to_char(d, 'YYYY-MM-DD') as dia
    from generate_series(p_desde::date, p_hasta::date, interval '1 day') as d
  ),
  vcobr as (
    select to_char(v.fecha at time zone 'America/Lima', 'YYYY-MM-DD') as dia,
           v.id_venta, coalesce(v.total,0)::numeric as total,
           upper(coalesce(v.forma_pago,'')) as fp, v.forma_pago
    from me.ventas v
    where upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'              -- C2: prefijo
      and upper(coalesce(v.forma_pago,'')) not in ('POR_COBRAR','CREDITO','PLANILLA')
      and (v.fecha at time zone 'America/Lima')::date between p_desde::date and p_hasta::date
  ),
  neto as (
    select dia, mos._r2(sum(
      ( case
          when fp='EFECTIVO' then total
          when fp='VIRTUAL'  then 0
          when fp like 'MIXTO%' then
            coalesce( (substring(upper(forma_pago) from 'EFE:([0-9.]+)'))::numeric,
                      round(total - coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric,0), 2) )
          else 0 end )
      +
      ( case
          when fp='EFECTIVO' then 0
          when fp='VIRTUAL'  then total
          when fp like 'MIXTO%' then coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric,0)
          else total end )
    )) as ventas_netas
    from vcobr group by dia
  ),
  det as (
    select v.dia, upper(trim(d.sku)) as nsku_l, upper(trim(coalesce(d.cod_barras,''))) as ncod_l,
           coalesce(d.cantidad,0)::numeric as cantidad, coalesce(d.precio,0)::numeric as precio
    from me.ventas_detalle d
    join vcobr v on v.id_venta = d.id_venta
  ),
  m_id as (
    select distinct on (upper(trim(id_producto))) upper(trim(id_producto)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where id_producto is not null and trim(id_producto)<>''
    order by upper(trim(id_producto)), id_producto desc
  ),
  m_cod as (
    select distinct on (upper(trim(codigo_barra))) upper(trim(codigo_barra)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where codigo_barra is not null and trim(codigo_barra)<>''
    order by upper(trim(codigo_barra)), id_producto desc
  ),
  m_sku as (
    select distinct on (upper(trim(sku_base))) upper(trim(sku_base)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where sku_base is not null and trim(sku_base)<>''
    order by upper(trim(sku_base)), id_producto asc
  ),
  canon as (
    select distinct on (upper(trim(sku_base))) upper(trim(sku_base)) nsku,
           coalesce(precio_costo,0)::numeric costo
    from mos.productos where sku_base is not null and trim(sku_base)<>''
    order by upper(trim(sku_base)), case when coalesce(factor_conversion,1)=1 then 0 else 1 end, id_producto
  ),
  det_res as (
    select dt.dia, dt.cantidad, dt.precio,
           coalesce(mi.factor, mc1.factor, mc2.factor, msk.factor, 1) as factor,
           coalesce(mi.nsku, mc1.nsku, mc2.nsku, msk.nsku) as nsku
    from det dt
    left join m_id  mi  on mi.k  = dt.nsku_l
    left join m_cod mc1 on mc1.k = dt.nsku_l
    left join m_cod mc2 on mc2.k = dt.ncod_l
    left join m_sku msk on msk.k = dt.nsku_l
  ),
  cogs as (
    select dr.dia, mos._r2(sum(
      case when coalesce(cn.costo,0) > 0
           then (dr.cantidad * dr.factor) * cn.costo
           else (dr.precio * dr.cantidad) * (1 - v_margen/100)
      end
    )) as costo_ventas
    from det_res dr
    left join canon cn on cn.nsku = dr.nsku
    group by dr.dia
  ),
  liq as (
    select to_char(l.fecha at time zone 'America/Lima','YYYY-MM-DD') as dia,
           lower(trim(l.nombre)) as k,
           upper(coalesce(l.estado,'PENDIENTE')) as estado,
           case when coalesce(l.total_dia,0)>0 then l.total_dia::numeric else coalesce(l.monto_base,0)::numeric end as monto,
           l.id_dia
    from mos.liquidaciones_dia l
    where l.presente = true and l.nombre is not null and trim(l.nombre)<>''
      and (l.fecha at time zone 'America/Lima')::date between p_desde::date and p_hasta::date
      and not exists (
        select 1 from mos.personal p
        where (
            ( (p.apellido is null or trim(p.apellido)='') and lower(trim(p.nombre)) = lower(trim(l.nombre)) )
            or ( p.apellido is not null and trim(p.apellido)<>'' and lower(trim(p.nombre)||' '||trim(p.apellido)) = lower(trim(l.nombre)) )
          )
          and ( upper(coalesce(p.app_origen,''))='MOS'
             or upper(coalesce(p.rol,'')) in ('MASTER','ADMINISTRADOR','ADMIN')
             or ( coalesce(p.rol,'')<>'' and upper(p.rol) not in ('ALMACENERO','ENVASADOR','OPERADOR','CAJERO','VENDEDOR') ) )
      )
  ),
  liq_dedup as (
    select dia, k, estado, monto, row_number() over (partition by dia, k order by id_dia) rn
    from liq
  ),
  personal as (
    select dia, mos._r2(sum(case when estado<>'VETADA' then monto else 0 end)) total_personal
    from liq_dedup where rn=1 group by dia
  ),
  gastos as (
    select to_char(g.fecha at time zone 'America/Lima','YYYY-MM-DD') as dia,
           mos._r2(sum(coalesce(g.monto,0)::numeric)) total_gastos_otros
    from mos.gastos g
    where (g.fecha at time zone 'America/Lima')::date between p_desde::date and p_hasta::date
    group by dia
  ),
  pl as (
    select d.dia,
           coalesce(n.ventas_netas,0) ventas_netas, coalesce(c.costo_ventas,0) costo_ventas,
           coalesce(pe.total_personal,0) personal, coalesce(ga.total_gastos_otros,0) gastos_otros
    from dias d
    left join neto n on n.dia=d.dia
    left join cogs c on c.dia=d.dia
    left join personal pe on pe.dia=d.dia
    left join gastos ga on ga.dia=d.dia
  ),
  pl2 as (
    select dia, ventas_netas, costo_ventas,
           mos._r2(ventas_netas - costo_ventas) utilidad_bruta,
           mos._r2(personal + gastos_otros) total_gastos
    from pl
  ),
  pl3 as (
    select dia, ventas_netas, costo_ventas, utilidad_bruta, total_gastos,
           mos._r2(utilidad_bruta - total_gastos) utilidad_neta,
           case when ventas_netas>0 then mos._r2(utilidad_bruta/ventas_netas*100) else 0 end margen_bruto_pct
    from pl2
  )
  select jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'serie', coalesce((
        select jsonb_agg(jsonb_build_object(
          'fecha',dia,'utilidadNeta',utilidad_neta,'ventasNetas',ventas_netas,
          'costoVentas',costo_ventas,'totalGastos',total_gastos,
          'utilidadBruta',utilidad_bruta,'margenBrutoPct',margen_bruto_pct
        ) order by dia) from pl3), '[]'::jsonb),
      'totales', (
        select jsonb_build_object(
          'ventasNetas',sum(ventas_netas),'costoVentas',sum(costo_ventas),
          'utilidadBruta',sum(utilidad_bruta),'totalGastos',sum(total_gastos),'utilidadNeta',sum(utilidad_neta),
          'margenBrutoPct', case when sum(ventas_netas)>0 then mos._r2(sum(utilidad_bruta)/sum(ventas_netas)*100) else 0 end,
          'margenNetoPct',  case when sum(ventas_netas)>0 then mos._r2(sum(utilidad_neta)/sum(ventas_netas)*100) else 0 end
        ) from pl3),
      'desde', p_desde, 'hasta', p_hasta
    )
  ) into v_data;

  -- [FIX cero-GAS] mergear el latido de la sombra (_fresh/_heartbeat/_now/_ttl_min) → el frontend
  -- (_getFinanzasRangoDirecto exige _fresh===true) usa Supabase cuando el sync está fresco (<TTL), y solo
  -- cae a GAS si la sombra está vieja. Sin esto, _fresh venía undefined → finanzas caía a GAS SIEMPRE.
  return v_data || mos._frescura_sombra();
end;
$function$;


-- ── HIGH4: guard de día sellado para envasado colaborativo ────────────────────
-- Solo actúa sobre registros COLABORATIVOS y solo cuando la mutación afecta el
-- pago (unidades, colaborador, o pasar a ANULADO). Si el día de CUALQUIER
-- participante (usuario o colaborador, viejo o nuevo) está PAGADA/VETADA, aborta
-- con un error claro: el monto está sellado y recomputar al otro lado desbalancea.
create or replace function mos._tg_envasado_guard_sellado()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare
  v_dia date;
  v_afecta_pago boolean;
  v_sellados text;
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') <> '1' then
    return case when TG_OP='DELETE' then OLD else NEW end;
  end if;
  -- ¿este cambio mueve dinero de envasado?
  if TG_OP = 'DELETE' then
    v_afecta_pago := (upper(coalesce(OLD.estado,'')) <> 'ANULADO');
  else
    v_afecta_pago := (coalesce(OLD.unidades_producidas,0) <> coalesce(NEW.unidades_producidas,0))
                  or (btrim(coalesce(OLD.colaborador,'')) <> btrim(coalesce(NEW.colaborador,'')))
                  or (upper(coalesce(OLD.estado,'')) <> upper(coalesce(NEW.estado,'')));
  end if;
  -- solo importa si hubo colaborador en juego (antes o después) — un registro
  -- individual sellado ya está protegido por el skip PAGADA/VETADA del recompute.
  if not v_afecta_pago
     or (btrim(coalesce(OLD.colaborador,'')) = '' and btrim(coalesce((case when TG_OP='DELETE' then OLD else NEW end).colaborador,'')) = '') then
    return case when TG_OP='DELETE' then OLD else NEW end;
  end if;
  v_dia := (OLD.fecha at time zone 'America/Lima')::date;
  -- participantes a proteger: usuario + colaborador viejo + colaborador nuevo
  select string_agg(distinct l.nombre, ', ') into v_sellados
    from mos.liquidaciones_dia l
   where (l.fecha at time zone 'America/Lima')::date = v_dia
     and upper(coalesce(l.estado,'')) in ('PAGADA','VETADA')
     and mos._norm_nom(coalesce((select btrim(nombre||' '||coalesce(apellido,'')) from mos.personal per where per.id_personal = l.id_personal limit 1), l.nombre))
         in ( mos._norm_nom(OLD.usuario),
              mos._norm_nom(nullif(btrim(coalesce(OLD.colaborador,'')),'')),
              mos._norm_nom(nullif(btrim(coalesce((case when TG_OP='DELETE' then OLD else NEW end).colaborador,'')),'')) );
  if v_sellados is not null then
    raise exception 'ENVASADO_COLAB_SELLADO: no se puede editar/anular un envasado colaborativo cuyo pago del dia ya se liquido (%). Reabri la liquidacion primero.', v_sellados
      using errcode = 'raise_exception';
  end if;
  return case when TG_OP='DELETE' then OLD else NEW end;
end; $fn$;

drop trigger if exists tg_envasado_guard_sellado on wh.envasados;
create trigger tg_envasado_guard_sellado
  before update or delete on wh.envasados
  for each row execute function mos._tg_envasado_guard_sellado();

-- ── LOW9: índice sobre la EXPRESIÓN consultada (btrim), no la columna cruda ────
drop index if exists mos.idx_me_ventas_credito_doc;
create index if not exists idx_me_ventas_credito_doc_btrim
  on me.ventas (btrim(cliente_doc)) where upper(forma_pago) = 'CREDITO';

notify pgrst, 'reload schema';
