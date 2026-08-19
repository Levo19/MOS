-- 869 · Cuando NubeFact rechaza en el momento de la venta, avisar AL INSTANTE y con el motivo.
--
-- Hasta acá el camino era: NubeFact rechaza → la venta queda PENDIENTE sin motivo → a los
-- 20 min el vigilante avisa "1 comprobante sin llegar" (sin decir por qué) → una hora después
-- el cron reintenta, vuelve a fallar y recién ahí graba el motivo. Tres pasos para enterarse
-- de algo que NubeFact dijo con todas las letras en el segundo cero.
--
-- Ahora emitir-cpe, al recibir el rechazo, llama a esto: se persiste el motivo en la venta
-- (Tributario lo pinta de una) y sale el push al MASTER con el correlativo y el texto del
-- rechazo. Con cooldown de 30 min por motivo — el 14-ago fueron 23 rechazos seguidos y
-- 23 pushes iguales no ayudan a nadie; el vigilante cada 15 min sigue cubriendo el conteo.

begin;

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
  -- quién rechazó: NUBEFACT (pre-validación, el comprobante nunca salió) o SUNAT (salió y
  -- SUNAT lo devolvió). Los dos van al MASTER; el título dice cuál, porque se resuelven distinto.
  v_origen text := case when upper(coalesce(p->>'origen','')) = 'SUNAT' then 'SUNAT' else 'NUBEFACT' end;
  v_firma  text; v_ult text; v_ult_ts timestamptz;
  v_res    jsonb;
begin
  -- solo el Edge (service_role): esto dispara pushes, no lo llama un cliente
  if coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','') <> 'service_role' then
    return jsonb_build_object('ok', false, 'error', 'SOLO_SERVICE_ROLE');
  end if;
  if v_ref is null and v_corr is null then return jsonb_build_object('ok', false, 'error', 'ref requerida'); end if;

  -- 1) el motivo queda en la venta, ya. Tributario lo muestra en el card sin esperar a nadie.
  update me.ventas
     set nf_sunat_desc = case when v_origen = 'SUNAT' then 'RECHAZO SUNAT: ' || v_motivo
                              else 'RECHAZO NubeFact (' || coalesce(v_http,'?') || '): ' || v_motivo end,
         nf_sunat_code = case when v_origen = 'SUNAT' then coalesce(nullif(v_http,''), 'SUNAT')
                              else 'NF_' || coalesce(v_http,'ERR') end
   where (v_ref is not null and ref_local = v_ref) or (v_ref is null and correlativo = v_corr);

  -- 2) push al MASTER, con cooldown por motivo (30 min): el mismo error repetido no vuelve
  --    a sonar; uno distinto sí. La firma es el motivo sin números, para que "línea 4" y
  --    "línea 10" del mismo problema cuenten como uno.
  v_firma := left(regexp_replace(lower(v_motivo), '[0-9.,]+', '#', 'g'), 80);
  select valor into v_ult from mos.config where clave = 'CPE_RECHAZO_AVISO' limit 1;
  if v_ult is not null and split_part(v_ult, '@', 1) = v_firma then
    v_ult_ts := to_timestamp(coalesce(nullif(split_part(v_ult, '@', 2),'')::bigint, 0));
    if v_ult_ts > now() - interval '30 minutes' then
      return jsonb_build_object('ok', true, 'aviso', false, 'motivo', 'mismo rechazo hace <30 min');
    end if;
  end if;

  v_res := mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
    'titulo', (case when v_origen = 'SUNAT' then '🔴 SUNAT rechazó ' else '⛔ NubeFact rechazó ' end) || coalesce(v_corr, 'un comprobante')
              || case when v_total > 0 then ' · S/ ' || to_char(v_total, 'FM999999990.00') else '' end,
    'cuerpo', left(v_motivo, 140) || ' · revisa Tributario',
    'data', jsonb_build_object('tipo', 'CPE_RECHAZO', 'correlativo', v_corr)));

  insert into mos.config (clave, valor, descripcion)
       values ('CPE_RECHAZO_AVISO', v_firma || '@' || extract(epoch from now())::bigint,
               'Último rechazo de NubeFact avisado por push (firma@epoch) — lo escribe me.cpe_avisar_rechazo')
  on conflict (clave) do update set valor = excluded.valor;

  return jsonb_build_object('ok', true, 'aviso', true, 'push', v_res);
end $$;

revoke all on function me.cpe_avisar_rechazo(jsonb) from public, anon, authenticated;
grant execute on function me.cpe_avisar_rechazo(jsonb) to service_role;

commit;
