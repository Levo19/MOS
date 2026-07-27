-- ════════════════════════════════════════════════════════════════════
-- 569 · Revisión senior — dos fixes:
-- (1) ALTO: al resolver un código EQUIVALENTE al canónico, el desempate usaba solo
--     `codigo_producto_base is null` → pero las PRESENTACIONES también tienen base NULL
--     (solo los derivados llevan base) y comparten sku_base → podía elegir una PRESENTACIÓN
--     y devolver su descripcion/precio. Canónico correcto = base vacío Y factor_conversion=1
--     (regla del catálogo). Corrige _voucher_guia, get_reporte (567) y operacion_detalle (568).
-- (2) MEDIO seguridad: wh.voucher_data devolvía `monto` de preingreso y estaba GRANT a anon
--     (566). Se usa solo desde la app autenticada → se REVOCA anon (get_reporte sigue anon
--     para reporte.html, pero ese ya existía).
-- ════════════════════════════════════════════════════════════════════

create or replace function wh._voucher_guia(v_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_g wh.guias%rowtype; v_prov text; v_det jsonb;
begin
  select * into v_g from wh.guias where id_guia = v_id;
  if not found then return null; end if;
  select nombre into v_prov from mos.proveedores where id_proveedor = v_g.id_proveedor;
  select coalesce(jsonb_agg(jsonb_build_object(
    'descripcion',     coalesce(pr.descripcion, eqp.descripcion, d.cod_producto),
    'codigoProducto',  d.cod_producto,
    'cantidad',        coalesce(d.cant_recibida, 0),
    'esProductoNuevo', (pr.id_producto is null and eq.sku_base is null and (pn.descripcion is not null or d.cod_producto like 'NLEV%')),
    'esSinIdentificar',(pr.id_producto is null and eq.sku_base is null and pn.descripcion is null and d.cod_producto not like 'NLEV%')
  ) order by d.linea), '[]'::jsonb) into v_det
  from wh.guia_detalle d
  left join mos.productos pr on (upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto)) or pr.id_producto = d.cod_producto)
  left join lateral (select e.sku_base from mos.equivalencias e where upper(btrim(e.codigo_barra)) = upper(btrim(d.cod_producto)) and e.activo is true limit 1) eq on (pr.id_producto is null)
  left join lateral (select px.descripcion from mos.productos px where px.sku_base = eq.sku_base
                      order by (coalesce(nullif(btrim(px.codigo_producto_base),''),'')='' and coalesce(px.factor_conversion,1)=1) desc, px.id_producto limit 1) eqp on true
  left join wh.producto_nuevo pn on pn.codigo_barra = d.cod_producto
  where d.id_guia = v_id and coalesce(d.observacion,'') <> 'ANULADO';
  return jsonb_build_object(
    'kind','guia', 'idGuia',v_g.id_guia, 'tipoGuia',coalesce(v_g.tipo,''), 'estado',coalesce(v_g.estado,''),
    'fecha',coalesce(v_g.fecha::text,''), 'proveedor',coalesce(v_prov, v_g.id_proveedor, ''),
    'usuario',coalesce(v_g.usuario,''), 'comentario',coalesce(v_g.comentario,''), 'foto',coalesce(v_g.foto,''),
    'idPreingreso',coalesce(v_g.id_preingreso,''), 'detalle', v_det);
end; $$;

create or replace function wh.get_reporte(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_tipo text := lower(btrim(coalesce(p->>'tipo','')));
  v_id   text := btrim(coalesce(p->>'id',''));
  v_g wh.guias%rowtype; v_pi wh.preingresos%rowtype;
  v_prov text; v_det jsonb; v_pre jsonb; v_guia jsonb; v_carg jsonb;
begin
  if v_tipo = '' or v_id = '' then return jsonb_build_object('ok',false,'error','tipo e id requeridos'); end if;
  if v_tipo = 'guia' then
    select * into v_g from wh.guias where id_guia = v_id;
    if not found then return jsonb_build_object('ok',false,'error','Guia no encontrada: '||v_id); end if;
    select nombre into v_prov from mos.proveedores where id_proveedor = v_g.id_proveedor;
    select coalesce(jsonb_agg(jsonb_build_object(
      'codigoProducto',   d.cod_producto,
      'descripcion',      coalesce(pr.descripcion, eqp.descripcion, d.cod_producto),
      'cantidadEsperada', d.cant_esperada,
      'cantidadReal',     coalesce(d.cant_recibida, 0),
      'fechaVencimiento', split_part(coalesce(d.fecha_vencimiento::text,''),'T',1),
      'observacion',      coalesce(d.observacion,''),
      'esProductoNuevo',  (pr.id_producto is null and eq.sku_base is null and (pn.descripcion is not null or d.cod_producto like 'NLEV%')),
      'esIncompleto',     (pr.id_producto is null and eq.sku_base is null and pn.descripcion is null and d.cod_producto not like 'NLEV%'),
      'estadoPN',         coalesce(pn.estado,'')
    ) order by d.linea), '[]'::jsonb) into v_det
    from wh.guia_detalle d
    left join mos.productos pr on (upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto)) or pr.id_producto = d.cod_producto)
    left join lateral (select e.sku_base from mos.equivalencias e where upper(btrim(e.codigo_barra)) = upper(btrim(d.cod_producto)) and e.activo is true limit 1) eq on (pr.id_producto is null)
    left join lateral (select px.descripcion from mos.productos px where px.sku_base = eq.sku_base
                        order by (coalesce(nullif(btrim(px.codigo_producto_base),''),'')='' and coalesce(px.factor_conversion,1)=1) desc, px.id_producto limit 1) eqp on true
    left join wh.producto_nuevo pn on pn.codigo_barra = d.cod_producto
    where d.id_guia = v_id and coalesce(d.observacion,'') <> 'ANULADO';
    v_pre := null;
    if coalesce(v_g.id_preingreso,'') <> '' then
      select jsonb_build_object('idPreingreso', pi.id_preingreso, 'estado', coalesce(pi.estado,''),
             'monto', coalesce(pi.monto::text,''), 'nFotos',
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
      'monto',coalesce(v_pi.monto::text,''), 'comentario',coalesce(v_pi.comentario,''),
      'fotos', case when coalesce(v_pi.fotos,'')='' then '[]'::jsonb else to_jsonb(string_to_array(v_pi.fotos,',')) end,
      'cargadores', v_carg, 'usuario',coalesce(v_pi.usuario,''), 'idGuia',coalesce(v_pi.id_guia,''), 'guia', v_guia,
      'generado', to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  else
    return jsonb_build_object('ok',false,'error','tipo invalido: '||v_tipo);
  end if;
end; $fn$;

create or replace function mos.operacion_detalle(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_fuente text := upper(btrim(coalesce(p->>'fuente','')));
  v_idg    text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_lin    jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_fuente = '' or v_idg is null then return jsonb_build_object('ok',false,'error','Requiere fuente y idGuia'); end if;

  if v_fuente = 'WH' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'idDetalle',         coalesce(d.id_detalle,''),
      'codigoProducto',    d.cod_producto,
      'descripcion',       coalesce(pr.descripcion, eqp.descripcion, '⚠ '||d.cod_producto||' (no en catálogo)'),
      'esEquivalencia',    (pr.id_producto is null and eq.sku_base is not null),
      'cantidad',          coalesce(nullif(d.cant_recibida,0), d.cant_esperada, 0),
      'precioUnitario',    coalesce(d.precio_unitario,0),
      'subtotal',          coalesce(nullif(d.cant_recibida,0), d.cant_esperada, 0) * coalesce(d.precio_unitario,0),
      'fechaVencimiento',  coalesce(d.fecha_vencimiento::text,''),
      'precioVentaActual', coalesce(pr.precio_venta, eqp.precio_venta, 0),
      'precioCostoActual', coalesce(pr.precio_costo, eqp.precio_costo, 0),
      'categoria',         coalesce(nullif(pr.id_categoria,''), eqp.id_categoria, '')
    ) order by d.linea), '[]'::jsonb) into v_lin
    from wh.guia_detalle d
    left join mos.productos pr on (upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto)) or pr.id_producto = d.cod_producto)
    left join lateral (select e.sku_base from mos.equivalencias e where upper(btrim(e.codigo_barra)) = upper(btrim(d.cod_producto)) and e.activo is true limit 1) eq on (pr.id_producto is null)
    left join lateral (select px.descripcion, px.precio_venta, px.precio_costo, px.id_categoria from mos.productos px
                        where px.sku_base = eq.sku_base order by (coalesce(nullif(btrim(px.codigo_producto_base),''),'')='' and coalesce(px.factor_conversion,1)=1) desc, px.id_producto limit 1) eqp on true
    where d.id_guia = v_idg;
    return jsonb_build_object('ok',true,'data', jsonb_build_object('fuente','WH','idGuia',v_idg,'lineas',v_lin));

  elsif v_fuente = 'ME' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'codigoBarra',    d.cod_barras,
      'descripcion',    coalesce(pr.descripcion, eqp.descripcion, '⚠ '||d.cod_barras||' (no en catálogo)'),
      'esEquivalencia', (pr.id_producto is null and eq.sku_base is not null),
      'cantidad',       coalesce(d.cantidad,0),
      'precioUnitario', coalesce(pr.precio_venta, eqp.precio_venta, 0),
      'subtotal',       coalesce(d.cantidad,0) * coalesce(pr.precio_venta, eqp.precio_venta, 0)
    ) order by d.linea), '[]'::jsonb) into v_lin
    from me.guias_detalle d
    left join mos.productos pr on upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_barras))
    left join lateral (select e.sku_base from mos.equivalencias e where upper(btrim(e.codigo_barra)) = upper(btrim(d.cod_barras)) and e.activo is true limit 1) eq on (pr.id_producto is null)
    left join lateral (select px.descripcion, px.precio_venta, px.precio_costo, px.id_categoria from mos.productos px
                        where px.sku_base = eq.sku_base order by (coalesce(nullif(btrim(px.codigo_producto_base),''),'')='' and coalesce(px.factor_conversion,1)=1) desc, px.id_producto limit 1) eqp on true
    where d.id_guia = v_idg;
    return jsonb_build_object('ok',true,'data', jsonb_build_object('fuente','ME','idGuia',v_idg,'lineas',v_lin));
  end if;
  return jsonb_build_object('ok',false,'error','Fuente desconocida: '||v_fuente);
end; $fn$;
revoke all on function mos.operacion_detalle(jsonb) from public, anon;
grant execute on function mos.operacion_detalle(jsonb) to authenticated, service_role;

-- (2) seguridad: voucher_data (y sus helpers) NO deben ser anónimos (filtran monto de preingreso).
-- OJO: las funciones tienen grant implícito a PUBLIC (default de Postgres) → hay que revocar de PUBLIC
-- ademas de anon; authenticated/service_role conservan su grant explícito.
revoke execute on function wh.voucher_data(jsonb) from public, anon;
revoke execute on function wh._voucher_guia(text) from public, anon;
revoke execute on function wh._voucher_pre(text)  from public, anon;
grant  execute on function wh.voucher_data(jsonb) to authenticated, service_role;
grant  execute on function wh._voucher_guia(text) to authenticated, service_role;
grant  execute on function wh._voucher_pre(text)  to authenticated, service_role;
grant  execute on function wh.get_reporte(jsonb)  to anon, authenticated, service_role;   -- reporte.html sí es anónimo
