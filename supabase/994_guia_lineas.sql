-- [994] mos.guia_lineas(idGuia) — líneas de una guía de ALMACÉN (wh.guia_detalle) para el visor de guía del
--  tablero Personal del Día. zona_traslado_guia sólo cubre traslados ME→WH; las guías internas de WH
--  (SALIDA_ZONA, INGRESO_PROVEEDOR, etc.) guardan su detalle en wh.guia_detalle. Solo lectura.
create or replace function mos.guia_lineas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_app text := coalesce(me.jwt_app(),'');
  v_id  text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_g   wh.guias%rowtype;
  v_out jsonb;
begin
  if v_app not in ('MOS','mosExpress') and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','') <> 'service_role' then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idGuia requerido'); end if;

  select * into v_g from wh.guias where id_guia = v_id limit 1;

  select jsonb_agg(jsonb_build_object(
      'linea', d.linea,
      'cod', d.cod_producto,
      'descripcion', coalesce((select pr.descripcion from mos.productos pr
                                where pr.codigo_barra = d.cod_producto or pr.id_producto = d.cod_producto limit 1), d.cod_producto),
      'esperada', d.cant_esperada,
      'recibida', d.cant_recibida,
      'aplicada', d.cantidad_aplicada,
      'precio', d.precio_unitario,
      'lote', nullif(btrim(coalesce(d.id_lote,'')),''),
      'venc', d.fecha_vencimiento,
      'obs', nullif(btrim(coalesce(d.observacion,'')),'')
    ) order by d.linea)
    into v_out
    from wh.guia_detalle d
   where d.id_guia = v_id;

  return jsonb_build_object('ok', true,
    'idGuia', v_id,
    'tipo', v_g.tipo,
    'estado', v_g.estado,
    'usuario', v_g.usuario,
    'numeroDocumento', v_g.numero_documento,
    'montoTotal', v_g.monto_total,
    'comentario', nullif(btrim(coalesce(v_g.comentario,'')),''),
    'lineas', coalesce(v_out,'[]'::jsonb));
end; $fn$;

revoke all on function mos.guia_lineas(jsonb) from public;
grant execute on function mos.guia_lineas(jsonb) to authenticated, anon;

select '994 guia_lineas listo' as ok;
