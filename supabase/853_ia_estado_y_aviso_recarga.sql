-- 853_ia_estado_y_aviso_recarga.sql
--
-- [DUEÑO] "que en este módulo me diga el estado de créditos para ver si debo recargar, y emitir
--  notificación push para saber que la IA murió y requiere recarga".
--
-- IMPORTANTE, Y SE DICE EN EL PANEL: **Anthropic NO publica el saldo por API.** Su Admin API solo
-- devuelve reportes de COSTO histórico (/v1/organizations/cost_report), nunca el crédito restante.
-- Así que el estado no se inventa ni se estima: se DEDUCE de lo que responde la API de verdad —
-- cuando el saldo se acaba, cada llamada vuelve con
--   "Your credit balance is too low to access the Anthropic API".
-- Esa es la señal, y es exacta: el momento en que la IA deja de funcionar es el momento en que hay
-- que recargar. Ni antes ni después.
--
-- AVISO: se dispara UNA vez y no vuelve a molestar en 6 horas. Sin ese freno, los tres crones
-- (cada 10 min) mandarían ~18 avisos por hora del mismo problema. Cuando la IA revive, avisa otra
-- vez —ahora en verde— y el contador se limpia.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) El semáforo: qué le pasa a la IA AHORA, con desde cuándo y cuánto se gastó
--    desde que volvió a funcionar (que es, en la práctica, la última recarga).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.ia_estado()
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_ult      record;   -- última llamada, sea cual sea
  v_ok       record;   -- última que SÍ funcionó
  v_motivo   text;
  v_fallos   int := 0;
  v_desde    timestamptz;
  v_gasto    numeric := 0;
  v_estado   text;
begin
  select ts, ok, coalesce(error,'') err, funcion into v_ult
    from mos.ia_uso order by id desc limit 1;
  if v_ult.ts is null then
    return jsonb_build_object('estado','SIN_DATOS','motivo','','fallos',0,
      'detalle','Todavía no hay ninguna llamada registrada.');
  end if;

  select ts into v_ok from mos.ia_uso where ok order by id desc limit 1;

  v_motivo := case
    when v_ult.err ilike '%credit balance is too low%' then 'SIN_SALDO'
    when v_ult.err ilike '%rate_limit%' or v_ult.err ilike '% 429%' then 'LIMITE_TASA'
    when v_ult.err ilike '%overloaded%' or v_ult.err ilike '% 529%' then 'ANTHROPIC_SATURADO'
    when v_ult.err ilike '%authentication%' or v_ult.err ilike '% 401%' then 'API_KEY'
    when v_ult.err ilike '%timeout%' or v_ult.err ilike '%abort%' then 'TIEMPO_AGOTADO'
    when not v_ult.ok then 'OTRO' else '' end;

  v_estado := case when v_ult.ok then 'OPERATIVA'
                   when v_motivo in ('SIN_SALDO','API_KEY') then 'CAIDA'
                   else 'INESTABLE' end;

  -- racha de fallos seguidos (desde la última que funcionó)
  select count(*), min(ts) into v_fallos, v_desde
    from mos.ia_uso
   where not ok and (v_ok.ts is null or ts > v_ok.ts);

  -- gasto desde que la IA volvió a funcionar = gasto desde la última recarga real
  if v_estado = 'OPERATIVA' then
    select coalesce(sum(costo_usd),0) into v_gasto from mos.ia_uso
     where ok and ts >= coalesce((select max(ts) from mos.ia_uso u2
                                   where not u2.ok and u2.error ilike '%credit balance%'), '-infinity'::timestamptz);
  end if;

  return jsonb_build_object(
    'estado',   v_estado,
    'motivo',   v_motivo,
    'fallos',   coalesce(v_fallos,0),
    'caidaDesde', case when v_estado <> 'OPERATIVA' then to_char(v_desde at time zone 'America/Lima','YYYY-MM-DD HH24:MI') end,
    'ultimaOk', to_char(v_ok.ts at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
    'horasSinIa', case when v_estado <> 'OPERATIVA'
                       then round(extract(epoch from (now() - coalesce(v_desde, now())))/3600.0, 1) end,
    'gastoDesdeRecarga', round(v_gasto, 4),
    'ultimaLlamada', to_char(v_ult.ts at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
    'detalle',  left(v_ult.err, 220));
end $fn$;

grant execute on function mos.ia_estado() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) El aviso. Vive DENTRO del registro de uso: el instante exacto en que la API
--    rechaza por saldo es el instante en que hay que avisar, no un cron después.
--    Todo en su propio bloque de excepción: avisar jamás puede tumbar la IA.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos._ia_avisar_estado(p_ok boolean, p_error text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  c_key   constant text := 'ia_aviso_sinsaldo_ts';
  v_ult   timestamptz;
  v_sin   boolean := (not coalesce(p_ok,true)) and coalesce(p_error,'') ilike '%credit balance is too low%';
begin
  select nullif(btrim(coalesce(valor,'')),'')::timestamptz into v_ult
    from mos.config where clave = c_key;

  if v_sin then
    -- ya se avisó hace menos de 6 h → callar (3 crones × 10 min serían ~18 avisos/hora)
    if v_ult is not null and v_ult > now() - interval '6 hours' then return; end if;
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
      'titulo', '🔴 La IA se quedó sin saldo',
      'cuerpo', 'Anthropic está rechazando las llamadas: OCR de guías, listas del almacén, '
                || 'descripciones y sustitutos están APAGADOS. Recargá créditos para que vuelvan.',
      'data', jsonb_build_object('tipo','ia_sin_saldo','ir','config:ia')));
    insert into mos.config (clave, valor) values (c_key, now()::text)
      on conflict (clave) do update set valor = excluded.valor;

  elsif coalesce(p_ok,false) and v_ult is not null then
    -- la IA volvió: se avisa el alta y se limpia la marca para que el próximo corte sí avise
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
      'titulo', '🟢 La IA volvió a funcionar',
      'cuerpo', 'La recarga entró: el OCR de guías, las listas del almacén y las descripciones '
                || 'ya están corriendo de nuevo.',
      'data', jsonb_build_object('tipo','ia_recuperada','ir','config:ia')));
    delete from mos.config where clave = c_key;
  end if;
exception when others then null;   -- avisar nunca puede romper el registro ni la IA
end $fn$;

-- engancharlo al registro de uso
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'ia_registrar_uso';

  v_new := replace(v_def,
    $old$  return jsonb_build_object('ok',true,'id',v_id,'costoUsd',v_costo,'sinTarifa',(t.id is null));$old$,
    $old$  -- [853] avisar al dueño en el instante exacto en que la IA muere por saldo (y cuando vuelve)
  perform mos._ia_avisar_estado(coalesce((p->>'ok')::boolean, true), coalesce(p->>'error',''));

  return jsonb_build_object('ok',true,'id',v_id,'costoUsd',v_costo,'sinTarifa',(t.id is null));$old$);
  if v_new = v_def then raise exception '853: no se encontró el return de ia_registrar_uso'; end if;
  execute v_new;
end $mig$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) El estado entra al resumen que ya lee el panel (una sola llamada).
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'ia_uso_resumen';
  v_new := replace(v_def,
    $old$    'primerRegistro', (select to_char(min(dia),'YYYY-MM-DD') from mos.ia_uso),$old$,
    $old$    'primerRegistro', (select to_char(min(dia),'YYYY-MM-DD') from mos.ia_uso),
    'estado', mos.ia_estado(),$old$);
  if v_new = v_def then raise exception '853: no se encontró primerRegistro en el resumen'; end if;
  execute v_new;
end $mig$;

commit;
