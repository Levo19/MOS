-- 526_vencimientos_lista.sql — SEMÁFORO DE VENCIMIENTOS UNIFICADO (WH + MOS).
-- Pedido del dueño: una sola fuente para "por vencer" con la categoría nueva URGENTE:
--   VENCIDO (<0d) · CRITICO (≤DIAS_ALERTA_VENC_CRITICO, def 7) · ALERTA (≤DIAS_ALERTA_VENC,
--   def 30) · URGENTE (≤DIAS_ALERTA_VENC_URGENTE, def 90 — "en zonas no debería haber
--   producto a menos de 3 meses de vencer") · SANO (>90).
-- Callable desde WH (claim warehouseMos) y MOS (claim mos) — patrón mermas_lista.
create or replace function wh.vencimientos_lista(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select case when wh._claim_ok() or mos._claim_ok()
    then (
      with cfg as (
        select coalesce((select valor::int from wh.config where clave='DIAS_ALERTA_VENC_CRITICO'), 7)  as crit,
               coalesce((select valor::int from wh.config where clave='DIAS_ALERTA_VENC'), 30)         as alerta,
               coalesce((select valor::int from wh.config where clave='DIAS_ALERTA_VENC_URGENTE'), 90) as urgente
      ),
      lotes as (
        select l.id_lote, l.cod_producto, l.fecha_vencimiento, l.cantidad_actual, l.id_guia,
               ((l.fecha_vencimiento at time zone 'America/Lima')::date
                 - (now() at time zone 'America/Lima')::date) as dias
          from wh.lotes_vencimiento l
         where l.estado = 'ACTIVO' and coalesce(l.cantidad_actual,0) > 0
           and l.fecha_vencimiento is not null
      )
      select jsonb_build_object('ok', true,
        'umbrales', (select jsonb_build_object('critico',crit,'alerta',alerta,'urgente',urgente) from cfg),
        'data', coalesce((
          select jsonb_agg(jsonb_build_object(
            'idLote', lo.id_lote,
            'codigoProducto', lo.cod_producto,
            'fechaVencimiento', to_char(lo.fecha_vencimiento at time zone 'America/Lima', 'YYYY-MM-DD'),
            'cantidadActual', lo.cantidad_actual,
            'idGuia', coalesce(lo.id_guia,''),
            'diasRestantes', lo.dias,
            'severidad', case
              when lo.dias < 0 then 'VENCIDO'
              when lo.dias <= (select crit from cfg) then 'CRITICO'
              when lo.dias <= (select alerta from cfg) then 'ALERTA'
              when lo.dias <= (select urgente from cfg) then 'URGENTE'
              else 'SANO' end
          ) order by lo.dias asc)
          from lotes lo), '[]'::jsonb))
    )
    else jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA') end;
$fn$;
grant execute on function wh.vencimientos_lista(jsonb) to authenticated;
