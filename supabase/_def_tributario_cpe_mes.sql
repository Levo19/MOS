CREATE OR REPLACE FUNCTION me.tributario_cpe_mes(p_mes integer DEFAULT NULL::integer, p_anio integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'me', 'public'
AS $function$
declare
  v_mes  int := p_mes;
  v_anio int := p_anio;
  v_cpe  jsonb;
begin
  if v_mes is null or v_mes = 0 or v_anio is null or v_anio = 0 then
    v_mes  := extract(month from (now() at time zone 'America/Lima'))::int;
    v_anio := extract(year  from (now() at time zone 'America/Lima'))::int;
  end if;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idVenta',     coalesce(v.id_venta, ''),
             'fecha',       to_char(v.fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
             'correlativo', coalesce(v.correlativo, ''),
             'tipo',        v.tipo_doc,
             'cliente',     coalesce(v.cliente_nombre, ''),
             'clienteDoc',  coalesce(v.cliente_doc, ''),
             'total',       coalesce(v.total, 0),
             'formaPago',   coalesce(v.forma_pago, ''),
             'nfEstado',    coalesce(v.nf_estado, ''),
             'nfHash',      coalesce(v.nf_hash, ''),
             'nfEnlace',    coalesce(v.nf_enlace, '')
           )
           order by v.fecha desc
         ), '[]'::jsonb)
  into v_cpe
  from me.ventas v
  where v.tipo_doc in ('BOLETA','FACTURA')
    and coalesce(v.estado_envio,'') <> 'HUERFANA_LIMPIADA'
    and (v.fecha at time zone 'America/Lima') >= make_timestamp(v_anio, v_mes, 1, 0, 0, 0)
    and (v.fecha at time zone 'America/Lima') <  (make_timestamp(v_anio, v_mes, 1, 0, 0, 0) + interval '1 month');

  return jsonb_build_object('status', 'success', 'cpe', v_cpe);
end;
$function$
