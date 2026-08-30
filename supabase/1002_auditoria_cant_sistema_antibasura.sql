-- [1002] FIX "cant_sistema gigante" en auditorías de zona (número que parece código de barras).
--  Síntoma: en me.auditorias, cant_sistema = STRING(cant_real) || STRING(un código de barras) — p.ej. real=2,
--  sistema=27751037001944 = '2'||'7751037001944'. Causa: SCAN-BLEED en el front (el escáner USB/cámara concatena
--  un código de barras en el campo de la auditoría) → el front manda un cantSistema corrupto. me.registrar_auditoria
--  usa el stockAntes REAL de zona_ajustar_stock, PERO en el camino de dedup (reintento) stockAntes viene nulo →
--  cae al cantSistema del front (basura). El STOCK NO se afecta (me.stock_zonas queda correcto); solo el registro.
--  FIX server-side (inmune a cualquier bug del front): si cant_sistema es ABSURDO (>1e6, imposible para un stock;
--  es un código de barras), tomar el stock REAL de me.stock_zonas. Además: limpiar los registros ya corruptos.
create or replace function me.registrar_auditoria(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_app    text  := me.jwt_app();
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_vend   text  := nullif(btrim(coalesce(p->>'vendedor', '')), '');
  v_zona   text  := upper(btrim(coalesce(p->>'zona', '')));
  v_items  jsonb := coalesce(p->'items', '[]'::jsonb);
  v_day    text  := to_char(now() at time zone 'America/Lima', 'YYYYMMDD');
  v_idaud  text;
  v_it     jsonb; v_cb text; v_real numeric; v_sis numeric; v_aj jsonb;
  v_n int := 0;
  v_saltados jsonb := '[]'::jsonb;
begin
  if v_app not in ('mosExpress', 'MOS') then return jsonb_build_object('status', 'error', 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('status', 'error', 'error', 'zona requerida'); end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('status', 'error', 'error', 'items requerido');
  end if;
  v_idaud := 'A-' || v_day || '-' || substr(md5(coalesce(v_vend, '') || '|' || v_zona), 1, 10);

  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app', 'MOS'))::text, true);

  for v_it in select * from jsonb_array_elements(v_items) loop
    v_cb := upper(btrim(coalesce(v_it->>'cod_barras', v_it->>'codBarra', '')));
    if v_cb = '' then continue; end if;
    v_real := coalesce((v_it->>'cantReal')::numeric, 0);
    v_sis  := coalesce((v_it->>'cantSistema')::numeric, 0);

    v_aj := me.zona_ajustar_stock(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb, 'nuevo', v_real, 'usuario', coalesce(v_vend, ''),
      'localId', v_idaud || ':' || v_cb || ':' || v_real, 'origen', 'AUDITORIA'));
    if coalesce((v_aj->>'ok'), 'false') <> 'true' and (v_aj->>'error') = 'PRODUCTO_EN_GUIA_ABIERTA' then
      v_saltados := v_saltados || jsonb_build_object('codBarra', v_cb, 'guia', v_aj->>'guia');
      continue;
    end if;
    if coalesce((v_aj->>'ok'), 'false') = 'true' and (v_aj->'data'->>'stockAntes') is not null then
      v_sis := coalesce((v_aj->'data'->>'stockAntes')::numeric, v_sis);
    end if;

    -- [1002 · anti-scan-bleed] cant_sistema del front puede venir corrupto (código de barras concatenado en el
    --   campo). Un stock JAMÁS es tan grande → si es absurdo, NO confiar: tomar el stock REAL de me.stock_zonas.
    if abs(coalesce(v_sis, 0)) > 1000000 then
      v_sis := coalesce((select cantidad from me.stock_zonas
                          where cod_barras = v_cb and upper(coalesce(zona_id,'')) = v_zona limit 1), 0);
    end if;

    insert into me.auditorias (id_auditoria, fecha, vendedor, zona_id, cod_barras, cant_sistema, cant_real, diferencia)
    values (v_idaud, now(), coalesce(v_vend, ''), v_zona, v_cb, v_sis, v_real, (v_real - v_sis))
    on conflict (id_auditoria, cod_barras) do update
      set fecha = now(), cant_sistema = excluded.cant_sistema, cant_real = excluded.cant_real, diferencia = excluded.diferencia;
    v_n := v_n + 1;
  end loop;

  perform set_config('request.jwt.claims', v_claims::text, true);
  return jsonb_build_object('status', 'success', 'registrados', v_n, 'idAuditoria', v_idaud,
    'saltados', v_saltados, 'nSaltados', jsonb_array_length(v_saltados));
end;
$function$;

-- Limpieza de los registros ya corruptos: cant_sistema absurdo → tomar el stock real de la zona; si no existe,
--   igualar a cant_real (diferencia 0). NO toca me.stock_zonas (el stock está bien).
update me.auditorias a
   set cant_sistema = coalesce((select cantidad from me.stock_zonas z
                                 where z.cod_barras = a.cod_barras and upper(coalesce(z.zona_id,'')) = upper(coalesce(a.zona_id,'')) limit 1),
                               a.cant_real),
       diferencia   = a.cant_real - coalesce((select cantidad from me.stock_zonas z
                                 where z.cod_barras = a.cod_barras and upper(coalesce(z.zona_id,'')) = upper(coalesce(a.zona_id,'')) limit 1),
                               a.cant_real)
 where abs(a.cant_sistema) > 1000000;

select '1002 auditoria cant_sistema anti-basura listo' as ok;
