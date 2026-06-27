-- 269_mos_series_directo.sql — Escritura DIRECTA de Series Documentales a Supabase (100% Supabase, sin GAS).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- Las "Series documentales" (NV/Boleta/Factura + correlativo, por estación/zona) se EDITAN desde MOS
-- Configuraciones, pero la ESCRITURA iba por GAS→Hoja SERIES_DOCUMENTALES y dependía del sync batch (que muere).
-- La LECTURA ya es directa (series_lista). Ahora MOS escribe directo a mos.series_documentales (mismo patrón
-- que crear_estacion, SQL 215). + trigger de versión (200) para que ME/WH refresquen al cambiar una serie.
-- Gate: MOS_CATALOGO_DIRECTO (ya ON) + claim. Idempotente (local_id + PK). actualizar = patch PARCIAL.
-- Money-safe: series no es dinero directo; additivo; no toca otras tablas. (Fiscal: la SERIE es la que usa
-- la emisión CPE — por eso debe vivir en Supabase, fresca, no en una Hoja que se atrasa.)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

-- local_id para idempotencia de gesto (additivo)
alter table mos.series_documentales add column if not exists local_id text;

-- trigger de versión (faltaba) → un cambio de serie bumpea catalogo_version → ME/WH re-jalan
drop trigger if exists tg_bump_catversion_series on mos.series_documentales;
create trigger tg_bump_catversion_series
  after insert or update or delete on mos.series_documentales
  for each statement execute function mos._bump_catalogo_version();

-- ── CREAR ──
create or replace function mos.crear_serie(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id    text := nullif(btrim(coalesce(p->>'idSerie','')), '');
  v_est   text := nullif(btrim(coalesce(p->>'idEstacion','')), '');
  v_tipo  text := upper(replace(nullif(btrim(coalesce(p->>'tipoDocumento','')),''), ' ', '_'));
  v_serie text := nullif(btrim(coalesce(p->>'serie','')), '');
  v_corr  bigint := coalesce(nullif(regexp_replace(coalesce(p->>'correlativo','1'),'\D','','g'),'')::bigint, 1);
  v_existe text; v_inserted int;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_est is null or v_tipo is null or v_serie is null then
    return jsonb_build_object('ok',false,'error','Requiere idEstacion, tipoDocumento y serie');
  end if;

  if v_local is not null then
    select id_serie into v_existe from mos.series_documentales where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idSerie', v_existe)); end if;
  end if;
  if v_id is not null and exists (select 1 from mos.series_documentales where id_serie = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idSerie', v_id));
  end if;

  v_id := coalesce(v_id, 'SER'||(extract(epoch from clock_timestamp())*1000)::bigint::text);
  insert into mos.series_documentales (id_serie, id_estacion, id_zona, tipo_documento, serie, correlativo, activo, local_id)
  values (
    v_id, v_est, nullif(btrim(coalesce(p->>'idZona','')),''), v_tipo, v_serie, v_corr, true, v_local
  )
  on conflict (id_serie) do nothing;
  get diagnostics v_inserted = row_count;
  return jsonb_build_object('ok',true,'dedup', v_inserted = 0, 'data', jsonb_build_object('idSerie', v_id));
exception when unique_violation then
  return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idSerie', v_id));
end;
$fn$;

-- ── ACTUALIZAR (patch PARCIAL: solo claves presentes en p) ──
create or replace function mos.actualizar_serie(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idSerie','')), ''); v_n int;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idSerie'); end if;

  update mos.series_documentales set
    id_estacion    = case when p ? 'idEstacion'    then coalesce(nullif(btrim(p->>'idEstacion'),''), id_estacion)         else id_estacion end,
    id_zona        = case when p ? 'idZona'        then nullif(btrim(p->>'idZona'),'')                                    else id_zona end,
    tipo_documento = case when p ? 'tipoDocumento' then coalesce(upper(replace(nullif(btrim(p->>'tipoDocumento'),''),' ','_')), tipo_documento) else tipo_documento end,
    serie          = case when p ? 'serie'         then coalesce(nullif(btrim(p->>'serie'),''), serie)                    else serie end,
    correlativo    = case when p ? 'correlativo'   then coalesce(nullif(regexp_replace(coalesce(p->>'correlativo',''),'\D','','g'),'')::bigint, correlativo) else correlativo end,
    activo         = case when p ? 'activo'        then (lower(coalesce(p->>'activo','')) in ('1','true','t','si','sí','y','yes')) else activo end
  where id_serie = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','Serie no encontrada: '||v_id); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

revoke all on function mos.crear_serie(jsonb)      from public;
revoke all on function mos.actualizar_serie(jsonb) from public;
grant execute on function mos.crear_serie(jsonb)      to authenticated;
grant execute on function mos.actualizar_serie(jsonb) to authenticated;
