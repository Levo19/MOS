-- 157_wh_alertas_stock_purga_lectura.sql
-- ============================================================
-- [WH MIGRACIÓN · ALERTAS_STOCK] Purga-y-reescribe en Supabase + lectura directa.
-- ------------------------------------------------------------
-- PROBLEMA. La hoja ALERTAS_STOCK usa un patrón delete-y-reescribe: en cada auditoría
-- (_guardarAlertasStock, Auditoria.gs) se BORRAN físicamente las alertas NO revisadas y se
-- reinsertan las nuevas con ids AL... frescos; las revisadas se preservan como histórico. La
-- sombra wh.alertas_stock solo recibía UPSERT por sync (nunca DELETE) → acumuló 1174 pendientes
-- huérfanas. Por eso getAlertasStock seguía leyendo la Hoja (un flip directo daría alertas obsoletas).
--
-- FIX. Una RPC que replica EXACTAMENTE el patrón de la hoja de forma ATÓMICA en Supabase:
--   wh.guardar_alertas_stock(p { fecha, alertas:[{codigoProducto,descripcion,stockReal,stockTeorico,diferencia}] })
--     1. DELETE de wh.alertas_stock where revisado is not true   (purga las no-revisadas; conserva histórico)
--     2. INSERT de las nuevas (revisado=false). ids AL... los genera GAS y se pasan → mismos ids que la Hoja.
--   Todo en la transacción de la función. Idempotente a nivel de "estado final" (re-correr deja el mismo
--   conjunto de pendientes para esa auditoría; las revisadas nunca se tocan).
-- Y la lectura:
--   wh.get_alertas_stock(p { soloPendientes? })  → lista shape camelCase (idAlerta,fecha,codigoProducto,...,revisado SI/NO).
--
-- SEGURIDAD: security definer · search_path='' · gate wh._claim_ok(). grants service_role+authenticated.
-- ============================================================

-- 1) PURGA-Y-REESCRIBE atómico
create or replace function wh.guardar_alertas_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_fecha   text  := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_arr     jsonb := coalesce(p->'alertas','[]'::jsonb);
  v_fts     timestamptz;
  v_a       jsonb;
  v_borradas int := 0;
  v_insert   int := 0;
  v_id       text;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(v_arr) <> 'array' then return jsonb_build_object('ok',false,'error','alertas debe ser array'); end if;

  -- fecha de la auditoría (acepta 'yyyy-MM-dd', timestamp, o 'dd/MM/yyyy HH:mm'); default now().
  if v_fecha is null then v_fts := now();
  elsif v_fecha ~ '^\d{4}-\d{2}-\d{2}$' then
    -- date-only → medianoche LIMA (no UTC) para que el round-trip a Lima devuelva la MISMA fecha.
    v_fts := (v_fecha::date::timestamp) at time zone 'America/Lima';
  else
    begin v_fts := v_fecha::timestamptz; exception when others then
      begin
        if v_fecha ~ '^\d{2}/\d{2}/\d{4}' then
          v_fts := (to_timestamp(left(v_fecha,16), 'DD/MM/YYYY HH24:MI')::timestamp) at time zone 'America/Lima';
        else v_fts := (left(v_fecha,10)::date::timestamp) at time zone 'America/Lima'; end if;
      exception when others then v_fts := now(); end;
    end;
  end if;

  -- 1) purga de NO revisadas (espeja el deleteRow de la Hoja). Conserva las revisadas (histórico).
  delete from wh.alertas_stock where revisado is not true;
  get diagnostics v_borradas = row_count;

  -- 2) insertar las nuevas (revisado=false). id provisto por GAS (mismos ids que la Hoja) o generado.
  for v_a in select jsonb_array_elements(v_arr) loop
    v_id := nullif(btrim(coalesce(v_a->>'idAlerta','')), '');
    if v_id is null then v_id := 'AL' || floor(extract(epoch from clock_timestamp())*1000)::bigint || '_' || v_insert; end if;
    insert into wh.alertas_stock (id_alerta, fecha, cod_producto, descripcion, stock_real, stock_teorico, diferencia, revisado, fecha_revision)
    values (v_id, v_fts,
            nullif(btrim(coalesce(v_a->>'codigoProducto','')),''),
            coalesce(v_a->>'descripcion',''),
            wh._num(coalesce(v_a->>'stockReal','')),
            wh._num(coalesce(v_a->>'stockTeorico','')),
            wh._num(coalesce(v_a->>'diferencia','')),
            false, null)
    on conflict (id_alerta) do update set
      fecha=excluded.fecha, cod_producto=excluded.cod_producto, descripcion=excluded.descripcion,
      stock_real=excluded.stock_real, stock_teorico=excluded.stock_teorico, diferencia=excluded.diferencia;
    v_insert := v_insert + 1;
  end loop;

  return jsonb_build_object('ok',true,'borradas',v_borradas,'insertadas',v_insert);
end;
$fn$;
revoke all on function wh.guardar_alertas_stock(jsonb) from public;
grant execute on function wh.guardar_alertas_stock(jsonb) to service_role, authenticated;


-- 2) LECTURA directa
create or replace function wh.get_alertas_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_solo boolean := coalesce((p->>'soloPendientes')::boolean, false);
  v_data jsonb;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t._ord desc nulls last), '[]'::jsonb)
    into v_data
  from (
    select id_alerta as "idAlerta",
           to_char((fecha at time zone 'America/Lima'),'YYYY-MM-DD"T"HH24:MI:SS') as "fecha",
           cod_producto as "codigoProducto", descripcion as "descripcion",
           stock_real as "stockReal", stock_teorico as "stockTeorico", diferencia as "diferencia",
           case when revisado then 'SI' else 'NO' end as "revisado",
           case when fecha_revision is null then '' else to_char((fecha_revision at time zone 'America/Lima'),'YYYY-MM-DD"T"HH24:MI:SS') end as "fechaRevision",
           fecha as _ord
    from wh.alertas_stock
    where (not v_solo or revisado is not true)
  ) t;

  -- quitar el campo auxiliar _ord de cada item
  select coalesce(jsonb_agg(e - '_ord'), '[]'::jsonb) into v_data
    from jsonb_array_elements(v_data) e;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function wh.get_alertas_stock(jsonb) from public;
grant execute on function wh.get_alertas_stock(jsonb) to service_role, authenticated;
