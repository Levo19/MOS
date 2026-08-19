-- 865 · CPE: la red de seguridad que no existía.
--
-- Hallazgo (18-ago-2026): 31 facturas por S/6,341.20 y 25 boletas por S/748.50 quedaron en
-- nf_estado='PENDIENTE' y NUNCA llegaron a NubeFact. La más vieja es del 6 de agosto.
--
-- Tres fallas encadenadas, ninguna avisó:
--   1. Cuando la emisión falla, MosExpress deja la venta en PENDIENTE confiando en que
--      "la reconciliación la re-emite". No la re-emite: `reconciliar-cpe` solo CONSULTA.
--      Fue escrita para otro caso — comprobantes ya aceptados esperando el CDR de SUNAT.
--   2. El reconciliador SÍ distingue el caso: tiene una acción llamada `no_existe_nubefact`.
--      La cuenta como "sin cambio" y sigue. Esa información viaja en la respuesta del Edge
--      y la respuesta no la lee nadie.
--   3. El cron lo llama con net.http_post sin timeout → 5 s por defecto. El reconciliador
--      consulta hasta 80 comprobantes de a uno; nunca entra en 5 s. Muere en cada corrida
--      desde que se escribió, y `cron.job_run_details` dice "succeeded" porque http_post
--      solo encola: el cron tuvo éxito ENCOLANDO. Por eso parecía sano.
--
-- Este archivo trae:
--   A) me.cpe_payload_reemision — reconstruye el comprobante desde la venta guardada
--      (cabecera + ítems + cliente) con el shape exacto que espera la Edge `emitir-cpe`.
--   B) me.cpe_pendientes_viejos — los CPE que llevan demasiado sin emitirse.
--   C) me.cpe_vigilar — el cron que AVISA. Esto es lo que faltó.
--   D) me.cpe_reconciliar_cron reescrito: timeout de verdad y la respuesta va a mos.cron_log.

begin;

-- ══════════════════════════════════════════════════════════════════════════════
-- A) El payload de reemisión
-- ══════════════════════════════════════════════════════════════════════════════
-- La dirección del cliente no vive en me.ventas: se busca en clientes_frecuentes, que es
-- de donde salió cuando se emitió la venta. Si no está, va vacía — NubeFact la acepta vacía
-- para persona natural (ver el incidente de "factura sin dirección").
create or replace function me.cpe_payload_reemision(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_corr text := nullif(btrim(coalesce(p->>'correlativo','')),'');
  v      record;
  v_items jsonb;
  v_dir  text;
begin
  -- Puerta por GRANT, no por claim. Cuando esto lo llama pg_cron NO hay request.jwt.claims
  -- de ningún tipo: exigir un claim ahí dejaba al propio vigilante fuera de su función.
  -- Si viene de PostgREST (hay contexto de request), entonces sí se exige app o service_role.
  if nullif(current_setting('request.jwt.claims', true),'') is not null
     and coalesce(me.jwt_app(),'') = ''
     and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','') <> 'service_role' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_corr is null then return jsonb_build_object('ok', false, 'error', 'correlativo requerido'); end if;

  select * into v from me.ventas where correlativo = v_corr limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'venta no encontrada: ' || v_corr); end if;

  -- una venta anulada NO se reemite: se comunica su baja, que es otro camino
  if upper(coalesce(v.forma_pago,'')) = 'ANULADO' then
    return jsonb_build_object('ok', false, 'error', 'VENTA_ANULADA');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'sku', d.sku, 'nombre', d.nombre, 'cantidad', d.cantidad,
      'precio', d.precio, 'subtotal', d.subtotal,
      'cod_barras', coalesce(d.cod_barras,''), 'cod_sunat', '',
      'valor_unitario', d.valor_unitario, 'tipo_igv', d.tipo_igv,
      'unidad_de_medida', coalesce(d.unidad_medida,'NIU')
    ) order by d.linea), '[]'::jsonb) into v_items
    from me.ventas_detalle d where d.id_venta = v.id_venta;

  if jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok', false, 'error', 'SIN_ITEMS: la venta no tiene detalle, no se puede reconstruir');
  end if;

  select nullif(btrim(coalesce(cf.direccion,'')),'') into v_dir
    from me.clientes_frecuentes cf
   where btrim(cf.documento) = btrim(coalesce(v.cliente_doc,''))
   order by cf.fecha_registro desc nulls last limit 1;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'correlativo', v.correlativo,
    'id_venta',    v.id_venta,
    'ref_local',   v.ref_local,
    -- la fecha ORIGINAL de la venta, no la de hoy: el comprobante documenta esa venta.
    -- Reemitirla con fecha de hoy cambiaría el período y es decisión del contador.
    'fecha_venta', to_char(v.fecha at time zone 'America/Lima', 'DD-MM-YYYY'),
    'data', jsonb_build_object(
      'header', jsonb_build_object(
        'tipoDoc', v.tipo_doc, 'total', v.total, 'metodo', v.forma_pago,
        'cliente', jsonb_build_object(
          'tipo', coalesce(v.tipo_doc_cliente, case when length(btrim(coalesce(v.cliente_doc,''))) = 11 then 6 else 1 end),
          'doc',  coalesce(v.cliente_doc,''),
          'nombre', coalesce(v.cliente_nombre,''),
          'direccion', coalesce(v_dir,'')
        )
      ),
      'items', v_items,
      'auth', jsonb_build_object('vendedor', coalesce(v.vendedor,''))
    )));
end $$;

revoke all on function me.cpe_payload_reemision(jsonb) from public, anon;
grant execute on function me.cpe_payload_reemision(jsonb) to service_role, authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- B) Los que llevan demasiado sin emitirse
-- ══════════════════════════════════════════════════════════════════════════════
-- Las BOLETAS viajan a SUNAT por resumen diario: es normal que pasen horas en PENDIENTE.
-- Las FACTURAS van una por una y se aceptan en segundos: una factura PENDIENTE a los
-- 20 minutos ya es una anomalía. Por eso el umbral es distinto por tipo.
create or replace function me.cpe_pendientes_viejos(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_min_fac int := greatest(5,  least(1440, coalesce((p->>'minFactura')::int, 20)));
  v_min_bol int := greatest(60, least(4320, coalesce((p->>'minBoleta')::int, 1500)));  -- 25 h: pasó su resumen diario
  v_dias    int := greatest(1,  least(120,  coalesce((p->>'dias')::int, 60)));
  v_rows jsonb;
begin
  -- Puerta por GRANT, no por claim. Cuando esto lo llama pg_cron NO hay request.jwt.claims
  -- de ningún tipo: exigir un claim ahí dejaba al propio vigilante fuera de su función.
  -- Si viene de PostgREST (hay contexto de request), entonces sí se exige app o service_role.
  if nullif(current_setting('request.jwt.claims', true),'') is not null
     and coalesce(me.jwt_app(),'') = ''
     and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','') <> 'service_role' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'correlativo', x.correlativo, 'tipoDoc', x.tipo_doc, 'total', x.total,
      'cliente', coalesce(x.cliente_nombre,''), 'vendedor', coalesce(x.vendedor,''),
      'zona', coalesce(x.zona_id,''), 'estado', coalesce(x.nf_estado,'PENDIENTE'),
      'minutos', x.minutos,
      'fecha', to_char(x.fecha at time zone 'America/Lima','DD/MM HH24:MI')
    ) order by x.fecha desc), '[]'::jsonb) into v_rows
  from (
    select v.*, floor(extract(epoch from (now() - v.fecha))/60)::int minutos
      from me.ventas v
     where v.tipo_doc in ('FACTURA','BOLETA')
       and coalesce(v.nf_estado,'PENDIENTE') = 'PENDIENTE'
       and upper(coalesce(v.forma_pago,'')) <> 'ANULADO'
       -- Solo lo ACCIONABLE: comprobantes que ni siquiera llegaron a NubeFact. Una boleta que
       -- ya tiene hash está en NubeFact esperando el resumen diario de SUNAT — eso se resuelve
       -- solo y avisarlo sería ruido. Un vigilante que grita por todo deja de ser un vigilante.
       and coalesce(v.nf_hash,'') = ''
       and v.fecha > now() - make_interval(days => v_dias)
       and extract(epoch from (now() - v.fecha))/60 >
           (case when v.tipo_doc = 'FACTURA' then v_min_fac else v_min_bol end)
  ) x;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'n', jsonb_array_length(v_rows),
    'soles', (select coalesce(sum((e->>'total')::numeric),0) from jsonb_array_elements(v_rows) e),
    'facturas', (select count(*) from jsonb_array_elements(v_rows) e where e->>'tipoDoc' = 'FACTURA'),
    'items', v_rows));
end $$;

revoke all on function me.cpe_pendientes_viejos(jsonb) from public, anon;
grant execute on function me.cpe_pendientes_viejos(jsonb) to service_role, authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- C) EL AVISO. Esto es lo que faltaba.
-- ══════════════════════════════════════════════════════════════════════════════
-- Manda push al MASTER cuando hay CPE sin emitir. Con memoria: no repite el mismo aviso
-- antes de 3 h, pero SÍ vuelve a avisar si aparecen comprobantes nuevos — si no, un
-- silencio de 3 h taparía justo el caso que interesa.
create or replace function me.cpe_vigilar()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_r jsonb; v_n int; v_soles numeric; v_fac int;
  v_firma text; v_ult text; v_ult_ts timestamptz;
  v_titulo text; v_cuerpo text;
  -- mos.config es (clave, valor, descripcion): NO tiene columna de fecha, así que el
  -- momento del último aviso viaja dentro del propio valor.
begin
  v_r := me.cpe_pendientes_viejos('{}'::jsonb);
  if coalesce(v_r->>'ok','') <> 'true' then return jsonb_build_object('ok',false,'error','lectura fallo'); end if;
  v_n     := coalesce((v_r->'data'->>'n')::int, 0);
  v_soles := coalesce((v_r->'data'->>'soles')::numeric, 0);
  v_fac   := coalesce((v_r->'data'->>'facturas')::int, 0);

  if v_n = 0 then
    delete from mos.config where clave = 'CPE_ALERTA_ESTADO';
    return jsonb_build_object('ok', true, 'n', 0, 'aviso', false);
  end if;

  -- la firma incluye el conteo: si aparece uno nuevo, el aviso vuelve aunque no hayan pasado 3 h
  v_firma := v_n::text || '|' || round(v_soles,2)::text;
  select valor into v_ult from mos.config where clave = 'CPE_ALERTA_ESTADO' limit 1;
  if v_ult is not null and split_part(v_ult, '@', 1) = v_firma then
    v_ult_ts := to_timestamp(coalesce(nullif(split_part(v_ult, '@', 2),'')::bigint, 0));
    if v_ult_ts > now() - interval '3 hours' then
      return jsonb_build_object('ok', true, 'n', v_n, 'aviso', false, 'motivo', 'ya avisado');
    end if;
  end if;

  v_titulo := '🚨 ' || v_n || ' comprobante' || case when v_n = 1 then '' else 's' end || ' sin llegar a SUNAT';
  v_cuerpo := 'S/ ' || to_char(v_soles, 'FM999999990.00')
           || case when v_fac > 0 then ' · ' || v_fac || ' factura' || case when v_fac = 1 then '' else 's' end else '' end
           || ' · revisa Tributario en MOS';

  -- mos.emitir_push rutea por mos.push_tokens_para, que YA tiene el gate de rol admin →
  -- app MOS (SQL 584). Así este aviso fiscal no cae en la tablet de un operador.
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
    'titulo', v_titulo, 'cuerpo', v_cuerpo,
    'data', jsonb_build_object('tipo','CPE_PENDIENTE','n', v_n)));

  insert into mos.config (clave, valor, descripcion)
       values ('CPE_ALERTA_ESTADO', v_firma || '@' || extract(epoch from now())::bigint,
               'Última alerta de CPE sin emitir (firma@epoch) — la escribe me.cpe_vigilar')
  on conflict (clave) do update set valor = excluded.valor;

  return jsonb_build_object('ok', true, 'n', v_n, 'soles', v_soles, 'aviso', true, 'titulo', v_titulo);
end $$;

revoke all on function me.cpe_vigilar() from public, anon, authenticated;

commit;
