-- 410 · wh.get_reporte(p) → reemplaza el getReporte de GAS (reporte.html, vista QR de guía/preingreso).
-- Read-only, público (el reporte se abre por link con el id; no expone PII sensible). Shape idéntico al GAS.

create or replace function wh.get_reporte(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_tipo text := lower(btrim(coalesce(p->>'tipo','')));
  v_id   text := btrim(coalesce(p->>'id',''));
  v_g wh.guias%rowtype;
  v_pi wh.preingresos%rowtype;
  v_prov text; v_det jsonb; v_pre jsonb; v_guia jsonb; v_carg jsonb;
begin
  if v_tipo = '' or v_id = '' then return jsonb_build_object('ok',false,'error','tipo e id requeridos'); end if;

  if v_tipo = 'guia' then
    select * into v_g from wh.guias where id_guia = v_id;
    if not found then return jsonb_build_object('ok',false,'error','Guia no encontrada: '||v_id); end if;
    select nombre into v_prov from mos.proveedores where id_proveedor = v_g.id_proveedor;
    -- detalle con descripción resuelta (catálogo manda; luego producto_nuevo; luego el código)
    select coalesce(jsonb_agg(jsonb_build_object(
      'codigoProducto',   d.cod_producto,
      'descripcion',      coalesce(pr.descripcion, pn.descripcion, d.cod_producto),
      'cantidadEsperada', d.cant_esperada,
      'cantidadReal',     coalesce(d.cant_recibida, 0),
      'fechaVencimiento', split_part(coalesce(d.fecha_vencimiento::text,''),'T',1),
      'observacion',      coalesce(d.observacion,''),
      'esProductoNuevo',  (pr.descripcion is null and (pn.descripcion is not null or d.cod_producto like 'NLEV%')),
      'esIncompleto',     (pr.descripcion is null and pn.descripcion is null and d.cod_producto not like 'NLEV%'),
      'estadoPN',         coalesce(pn.estado,'')
    ) order by d.linea), '[]'::jsonb) into v_det
    from wh.guia_detalle d
    left join mos.productos pr on pr.codigo_barra = d.cod_producto
    left join wh.producto_nuevo pn on pn.codigo_barra = d.cod_producto
    where d.id_guia = v_id and coalesce(d.observacion,'') <> 'ANULADO';

    v_pre := null;
    if coalesce(v_g.id_preingreso,'') <> '' then
      select jsonb_build_object('idPreingreso', pi.id_preingreso, 'estado', coalesce(pi.estado,''),
             'monto', coalesce(pi.monto,''), 'nFotos',
             (case when coalesce(pi.fotos,'')='' then 0 else array_length(string_to_array(pi.fotos,','),1) end))
        into v_pre from wh.preingresos pi where pi.id_preingreso = v_g.id_preingreso;
    end if;

    return jsonb_build_object('ok',true,'data', jsonb_build_object(
      'tipo','guia', 'idGuia',v_g.id_guia, 'tipoGuia',coalesce(v_g.tipo,''), 'estado',coalesce(v_g.estado,''),
      'fecha', coalesce(v_g.fecha::text,''), 'idProveedor',coalesce(v_g.id_proveedor,''), 'proveedor',coalesce(v_prov,''),
      'usuario',coalesce(v_g.usuario,''), 'comentario',coalesce(v_g.comentario,''), 'foto',coalesce(v_g.foto,''),
      'idPreingreso',coalesce(v_g.id_preingreso,''), 'preingreso', v_pre, 'detalle', v_det,
      'generado', to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));

  elsif v_tipo = 'preingreso' then
    select * into v_pi from wh.preingresos where id_preingreso = v_id;
    if not found then return jsonb_build_object('ok',false,'error','Preingreso no encontrado: '||v_id); end if;
    select nombre into v_prov from mos.proveedores where id_proveedor = v_pi.id_proveedor;
    begin v_carg := coalesce(nullif(v_pi.cargadores,'')::jsonb, '[]'::jsonb); exception when others then v_carg := '[]'::jsonb; end;
    v_guia := null;
    if coalesce(v_pi.id_guia,'') <> '' then
      select jsonb_build_object('idGuia', g.id_guia, 'tipo', coalesce(g.tipo,''), 'estado', coalesce(g.estado,''),
             'usuario', coalesce(g.usuario,''),
             'items', (select count(*) from wh.guia_detalle d where d.id_guia = g.id_guia and coalesce(d.observacion,'')<>'ANULADO'))
        into v_guia from wh.guias g where g.id_guia = v_pi.id_guia;
    end if;
    return jsonb_build_object('ok',true,'data', jsonb_build_object(
      'tipo','preingreso', 'idPreingreso',v_pi.id_preingreso, 'fecha',coalesce(v_pi.fecha::text,''),
      'estado',coalesce(v_pi.estado,''), 'idProveedor',coalesce(v_pi.id_proveedor,''), 'proveedor',coalesce(v_prov,''),
      'monto',coalesce(v_pi.monto,''), 'comentario',coalesce(v_pi.comentario,''),
      'fotos', case when coalesce(v_pi.fotos,'')='' then '[]'::jsonb else to_jsonb(string_to_array(v_pi.fotos,',')) end,
      'cargadores', v_carg, 'usuario',coalesce(v_pi.usuario,''), 'idGuia',coalesce(v_pi.id_guia,''), 'guia', v_guia,
      'generado', to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  else
    return jsonb_build_object('ok',false,'error','tipo invalido: '||v_tipo);
  end if;
end; $fn$;

grant execute on function wh.get_reporte(jsonb) to authenticated, service_role, anon;
