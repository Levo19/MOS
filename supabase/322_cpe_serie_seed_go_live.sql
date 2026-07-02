-- ============================================================================
-- 322_cpe_serie_seed_go_live.sql — herramienta de go-live: sembrar fac.series con
-- TODAS las series por zona + helper de serie por zona. (200x CPE, bloqueador #1)
-- ----------------------------------------------------------------------------
-- El review destapó que fac.series (el contador que consume fac.emitir_cpe) solo conocía
-- B001/F001, mientras que las series REALES por zona viven en mos.series_documentales
-- (BBB1/FFF1/… y, a futuro, una por cada zona incluido MOS/VIP). Sin sembrarlas, emitir por
-- una serie desconocida arranca en 0 → manda nº 1 a NubeFact → duplicado/desync.
--
-- Este archivo:
--  1) fac.serie_de_zona(zona, tipo) — helper de lectura (misma regla que fac.emitir_cpe usa inline).
--  2) fac.admin_seed_series_from_zonas — siembra en fac.series toda BOLETA/FACTURA activa de
--     mos.series_documentales que falte (correlativo 0). NO toca las existentes ni resetea nada.
--     El ALINEADO al número real de NubeFact se hace aparte, POR SERIE, con fac.admin_alinear_correlativo.
--  NO activa nada (no toca fac.config.activo ni FAC_CPE_DIRECTO). Seguro de correr antes del go-live.
-- ============================================================================

-- 1) helper: serie vigente de una zona por tipo (BOLETA/FACTURA). Reusa mos.series_documentales.
create or replace function fac.serie_de_zona(p_zona text, p_tipo text)
returns text language sql stable security definer set search_path = '' as $fn$
  select max(btrim(serie)) from mos.series_documentales
   where btrim(coalesce(id_zona,'')) = btrim(coalesce(p_zona,''))
     and coalesce(activo,true) = true
     and btrim(coalesce(serie,'')) <> ''
     and upper(regexp_replace(coalesce(tipo_documento,''),'[\s_]','','g')) =
         case when upper(coalesce(p_tipo,''))='FACTURA' then 'FACTURA' else 'BOLETA' end;
$fn$;
revoke all on function fac.serie_de_zona(text,text) from public;
grant execute on function fac.serie_de_zona(text,text) to authenticated, service_role;

-- 2) go-live seed: registra en fac.series toda serie BOLETA/FACTURA activa de mos.series_documentales.
--    Idempotente (on conflict do nothing). Devuelve lo sembrado + lo que ya existía + lo que FALTA alinear.
create or replace function fac.admin_seed_series_from_zonas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nuevas int := 0; v_total int := 0; v_falta_align jsonb;
begin
  if not fac._app_ok() then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not fac._admin_ok(p->>'clave_admin','FAC_SEED_SERIES','') then return jsonb_build_object('status','error','error','CLAVE_ADMIN_INVALIDA'); end if;

  with distintas as (
    select distinct btrim(serie) as serie,
           case when upper(regexp_replace(coalesce(tipo_documento,''),'[\s_]','','g'))='FACTURA' then 1 else 2 end as tipo
    from mos.series_documentales
    where coalesce(activo,true)=true and btrim(coalesce(serie,''))<>''
      and upper(regexp_replace(coalesce(tipo_documento,''),'[\s_]','','g')) in ('BOLETA','FACTURA')
  ),
  ins as (
    insert into fac.series(serie,tipo,correlativo)
    select serie, tipo, 0 from distintas
    on conflict (serie) do nothing
    returning 1
  )
  select count(*) into v_nuevas from ins;

  select count(*) into v_total from fac.series;
  -- series que siguen en 0 (probablemente faltan alinear a NubeFact antes de emitir REAL)
  select coalesce(jsonb_agg(jsonb_build_object('serie',serie,'tipo',tipo,'correlativo',correlativo) order by serie),'[]'::jsonb)
    into v_falta_align from fac.series where correlativo = 0;

  return jsonb_build_object('status','success','sembradas_nuevas',v_nuevas,'series_total',v_total,
    'en_cero_falta_alinear', v_falta_align,
    'nota','Alinea cada serie a su ÚLTIMO número real de NubeFact con fac.admin_alinear_correlativo ANTES de emitir en producción.');
end;
$fn$;
revoke all on function fac.admin_seed_series_from_zonas(jsonb) from public;
grant execute on function fac.admin_seed_series_from_zonas(jsonb) to authenticated, service_role;
