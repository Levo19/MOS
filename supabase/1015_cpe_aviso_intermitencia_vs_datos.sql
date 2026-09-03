-- ============================================================================
-- 1015_cpe_aviso_intermitencia_vs_datos.sql — (pedido del dueño 03-sep)
-- ----------------------------------------------------------------------------
-- El push decía "🔴 SUNAT rechazó" también cuando el "rechazo" era un error INTERNO de los
-- servidores de SUNAT ("El sistema no puede responder su solicitud… no se pudo grabar el
-- log/zip") — eso se cura solo (NubeFact reenvía + nuestro reconciliador re-emite cada hora;
-- caso FM01-152/153 del 03-sep: de rechazo a aceptada en 9 min). Un rojo así solo asusta.
--
-- Ahora el aviso CLASIFICA el motivo:
--   ⏳ INTERMITENCIA (infra SUNAT, o NubeFact con HTTP 5xx) → "se reintenta solo, nada que hacer"
--   🔴 SUNAT rechazó / ⛔ NubeFact rechazó (validación de DATOS) → "revisa Tributario" (la alarma real)
-- El sello en me.ventas también distingue (SUNAT INTERMITENTE: … vs RECHAZO SUNAT: …).
-- Devuelve `titulo` en el json (para poder probarlo en tx). Reemplaza me.cpe_avisar_rechazo (869).
-- ============================================================================
create or replace function me.cpe_avisar_rechazo(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_ref    text := nullif(btrim(coalesce(p->>'refLocal','')),'');
  v_corr   text := nullif(btrim(coalesce(p->>'correlativo','')),'');
  v_http   text := nullif(btrim(coalesce(p->>'http','')),'');
  v_motivo text := left(btrim(coalesce(p->>'motivo','')), 300);
  v_total  numeric := coalesce((p->>'total')::numeric, 0);
  v_origen text := case when upper(coalesce(p->>'origen','')) = 'SUNAT' then 'SUNAT' else 'NUBEFACT' end;
  v_infra  boolean := false;
  v_titulo text; v_cuerpo text;
  v_firma  text; v_ult text; v_ult_ts timestamptz;
  v_res    jsonb;
begin
  if coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','') <> 'service_role' then
    return jsonb_build_object('ok', false, 'error', 'SOLO_SERVICE_ROLE');
  end if;
  if v_ref is null and v_corr is null then return jsonb_build_object('ok', false, 'error', 'ref requerida'); end if;

  -- [1015] ¿es infraestructura (se cura sola) o validación de datos (alarma real)?
  --   · SUNAT: sus errores internos vienen con estas frases (observadas en producción).
  --   · NubeFact: HTTP 5xx = su plataforma, no nuestros datos.
  v_infra := (v_origen = 'SUNAT' and v_motivo ~* '(no puede responder|no se pudo grabar|no se pudo escribir|servicio no disponible|service unavailable|intente (nuevamente|m[aá]s tarde)|time ?out|internal server|en mantenimiento)')
          or (v_origen = 'NUBEFACT' and coalesce(v_http,'') ~ '^5');

  update me.ventas
     set nf_sunat_desc = case
           when v_infra and v_origen = 'SUNAT' then 'SUNAT INTERMITENTE: ' || v_motivo
           when v_infra then 'NUBEFACT INTERMITENTE (' || coalesce(v_http,'?') || '): ' || v_motivo
           when v_origen = 'SUNAT' then 'RECHAZO SUNAT: ' || v_motivo
           else 'RECHAZO NubeFact (' || coalesce(v_http,'?') || '): ' || v_motivo end,
         nf_sunat_code = case when v_origen = 'SUNAT' then coalesce(nullif(v_http,''), 'SUNAT')
                              else 'NF_' || coalesce(v_http,'ERR') end
   where (v_ref is not null and ref_local = v_ref) or (v_ref is null and correlativo = v_corr);

  v_firma := left(regexp_replace(lower(v_motivo), '[0-9.,]+', '#', 'g'), 80);
  select valor into v_ult from mos.config where clave = 'CPE_RECHAZO_AVISO' limit 1;
  if v_ult is not null and split_part(v_ult, '@', 1) = v_firma then
    v_ult_ts := to_timestamp(coalesce(nullif(split_part(v_ult, '@', 2),'')::bigint, 0));
    if v_ult_ts > now() - interval '30 minutes' then
      return jsonb_build_object('ok', true, 'aviso', false, 'motivo', 'mismo rechazo hace <30 min');
    end if;
  end if;

  if v_infra then
    v_titulo := '⏳ ' || (case when v_origen = 'SUNAT' then 'SUNAT' else 'NubeFact' end) || ' intermitente · '
                || coalesce(v_corr, 'comprobante')
                || case when v_total > 0 then ' · S/ ' || to_char(v_total, 'FM999999990.00') else '' end;
    v_cuerpo := 'Falla de SUS servidores (no de tus datos): ' || left(v_motivo, 90)
                || ' · se reintenta solo (NubeFact + reconciliador cada hora) — nada que hacer';
  else
    v_titulo := (case when v_origen = 'SUNAT' then '🔴 SUNAT rechazó ' else '⛔ NubeFact rechazó ' end)
                || coalesce(v_corr, 'un comprobante')
                || case when v_total > 0 then ' · S/ ' || to_char(v_total, 'FM999999990.00') else '' end;
    v_cuerpo := left(v_motivo, 140) || ' · revisa Tributario';
  end if;

  v_res := mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
    'titulo', v_titulo,
    'cuerpo', v_cuerpo,
    'data', jsonb_build_object('tipo', case when v_infra then 'CPE_INTERMITENCIA' else 'CPE_RECHAZO' end, 'correlativo', v_corr)));

  insert into mos.config (clave, valor, descripcion)
       values ('CPE_RECHAZO_AVISO', v_firma || '@' || extract(epoch from now())::bigint,
               'Último rechazo de NubeFact avisado por push (firma@epoch) — lo escribe me.cpe_avisar_rechazo')
  on conflict (clave) do update set valor = excluded.valor;

  return jsonb_build_object('ok', true, 'aviso', true, 'infra', v_infra, 'titulo', v_titulo, 'push', v_res);
end $$;

revoke all on function me.cpe_avisar_rechazo(jsonb) from public, anon, authenticated;
grant execute on function me.cpe_avisar_rechazo(jsonb) to service_role;
