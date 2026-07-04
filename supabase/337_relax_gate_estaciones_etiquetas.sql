-- 337_relax_gate_estaciones_etiquetas.sql
-- [CERO-GAS fix letras rojas] estaciones_lista + etiquetas_pendientes usaban solo _claim_ok (rechaza mosExpress)
-- → ME recibía APP_NO_AUTORIZADA. Relajado para aceptar token ME (lecturas read-only). Cuerpo idéntico.
CREATE OR REPLACE FUNCTION mos.estaciones_lista(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_zona text := nullif(btrim(coalesce(p->>'idZona','')), '');
  v_app  text := nullif(btrim(coalesce(p->>'appOrigen','')), '');
  v_act  text := nullif(btrim(coalesce(p->>'activo','')), '');
  v_pin  boolean := coalesce((p->>'incluirPin')::boolean, false);
  v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','') <> 'mosExpress' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(obj order by nom), '[]'::jsonb) into v_arr from (
    select coalesce(e.nombre,'') as nom,
      (jsonb_build_object(
        'idEstacion', coalesce(e.id_estacion,''), 'idZona', coalesce(e.id_zona,''), 'nombre', coalesce(e.nombre,''),
        'tipo', coalesce(e.tipo,''), 'appOrigen', coalesce(e.app_origen,''),
        'activo', case when coalesce(e.activo,false) then '1' else '0' end, 'descripcion', coalesce(e.descripcion,'')
      ) || case when v_pin then jsonb_build_object('adminPin', coalesce(e.admin_pin,'')) else '{}'::jsonb end) as obj
    from mos.estaciones e
    where (v_zona is null or e.id_zona = v_zona)
      and (v_app  is null or e.app_origen = v_app)
      and (v_act  is null or (case when coalesce(e.activo,false) then '1' else '0' end) = v_act)
  ) s;
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $function$
;

CREATE OR REPLACE FUNCTION mos.etiquetas_pendientes(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_zona  text := nullif(btrim(coalesce(p->>'idZona','')), '');
  v_user  text := lower(nullif(btrim(coalesce(p->>'usuario','')), ''));
  v_now   timestamptz := now();
  v_data  jsonb;
  v_count int;
begin
  if not mos._claim_ok() and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','') <> 'mosExpress' then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(row order by ord_min desc, ord_id), '[]'::jsonb), count(*)
    into v_data, v_count
  from (
    select jsonb_build_object(
      'idEtiq',             t.id_etiq,
      'idZona',             t.id_zona,
      'zonaNombre',         t.zona_nombre,
      'idProducto',         t.id_producto,
      'descripcion',        t.descripcion,
      'codigoBarra',        t.codigo_barra,
      'skuBase',            t.sku_base,
      'precioAnterior',     t.precio_anterior,
      'precioNuevo',        t.precio_nuevo,
      'ts_cambio',          t.ts_cambio,
      'cambiadoPor',        t.cambiado_por,
      'estado',             t.estado,
      'visto_csv',          t.visto_csv,
      'ts_impresa',         t.ts_impresa,
      'impresaPor',         t.impresa_por,
      'jobId',              t.job_id,
      'ts_pegada',          t.ts_pegada,
      'pegadaPor',          t.pegada_por,
      'comentario',         t.comentario,
      -- enriquecimientos (paridad GAS, función pura de columnas):
      '_minutosDesdeCambio', case when t.ts_cambio is not null
                                  then round(extract(epoch from (v_now - t.ts_cambio)) / 60.0)::int
                                  else 0 end,
      '_vistoPorMi',        case when v_user is null then false
                                 else v_user = any(mos._etiq_visto_tokens(t.visto_csv)) end,
      '_cantidadVistos',    coalesce(array_length(mos._etiq_visto_tokens(t.visto_csv), 1), 0)
    ) as row,
    case when t.ts_cambio is not null
         then round(extract(epoch from (v_now - t.ts_cambio)) / 60.0)::int else 0 end as ord_min,
    t.id_etiq as ord_id
    from mos.etiquetas_zona t
    where upper(coalesce(t.estado,'')) not in ('PEGADA','OBSOLETA')      -- paridad: oculta cerradas/obsoletas
      and (v_zona is null or t.id_zona = v_zona)                          -- idZona opcional (String ==)
      -- ventana 3 días: ocultar las más viejas. ts NULL NO se oculta (GAS: ts=0 salta el corte).
      and (t.ts_cambio is null or (v_now - t.ts_cambio) <= interval '3 days')
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$function$
;
