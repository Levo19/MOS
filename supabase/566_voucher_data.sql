-- ════════════════════════════════════════════════════════════════════
-- 566 · wh.voucher_data(p{tipo,id}) — datos para el VOUCHER-imagen compartible.
-- Devuelve una pila de "tickets": el principal (desde donde se comparte) + anexos.
--   tipo=guia        → [guia(+detalle), preingreso vinculado?]
--   tipo=preingreso  → [preingreso, ...TODAS sus guias(+detalle)]
-- Read-only, security definer, público (mismo criterio que get_reporte).
-- ════════════════════════════════════════════════════════════════════

-- Guía → jsonb {kind:'guia', ...campos, detalle:[{descripcion,cantidad,esProductoNuevo,esSinIdentificar}]}
create or replace function wh._voucher_guia(v_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_g wh.guias%rowtype; v_prov text; v_det jsonb;
begin
  select * into v_g from wh.guias where id_guia = v_id;
  if not found then return null; end if;
  select nombre into v_prov from mos.proveedores where id_proveedor = v_g.id_proveedor;
  select coalesce(jsonb_agg(jsonb_build_object(
    'descripcion',     coalesce(pr.descripcion, pn.descripcion, d.cod_producto),
    'codigoProducto',  d.cod_producto,
    'cantidad',        coalesce(d.cant_recibida, 0),
    'esProductoNuevo', (pr.descripcion is null and (pn.descripcion is not null or d.cod_producto like 'NLEV%')),
    'esSinIdentificar',(pr.descripcion is null and pn.descripcion is null and d.cod_producto not like 'NLEV%')
  ) order by d.linea), '[]'::jsonb) into v_det
  from wh.guia_detalle d
  left join mos.productos pr on pr.codigo_barra = d.cod_producto
  left join wh.producto_nuevo pn on pn.codigo_barra = d.cod_producto
  where d.id_guia = v_id and coalesce(d.observacion,'') <> 'ANULADO';
  return jsonb_build_object(
    'kind','guia', 'idGuia',v_g.id_guia, 'tipoGuia',coalesce(v_g.tipo,''), 'estado',coalesce(v_g.estado,''),
    'fecha',coalesce(v_g.fecha::text,''), 'proveedor',coalesce(v_prov, v_g.id_proveedor, ''),
    'usuario',coalesce(v_g.usuario,''), 'comentario',coalesce(v_g.comentario,''), 'foto',coalesce(v_g.foto,''),
    'idPreingreso',coalesce(v_g.id_preingreso,''), 'detalle', v_det);
end; $$;

-- Preingreso → jsonb {kind:'preingreso', ...campos, cargadores:[nombres], fotos:[urls]}
create or replace function wh._voucher_pre(v_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_pi wh.preingresos%rowtype; v_prov text; v_carg jsonb;
begin
  select * into v_pi from wh.preingresos where id_preingreso = v_id;
  if not found then return null; end if;
  select nombre into v_prov from mos.proveedores where id_proveedor = v_pi.id_proveedor;
  begin
    if coalesce(v_pi.cargadores,'') = '' or jsonb_typeof(v_pi.cargadores::jsonb) <> 'array' then
      v_carg := '[]'::jsonb;
    else
      select coalesce(jsonb_agg(coalesce(nullif(btrim(e->>'nombre'),''), e->>'idPersonal', e->>'id', '?')), '[]'::jsonb)
        into v_carg from jsonb_array_elements(v_pi.cargadores::jsonb) e;
    end if;
  exception when others then v_carg := '[]'::jsonb; end;
  return jsonb_build_object(
    'kind','preingreso', 'idPreingreso',v_pi.id_preingreso, 'estado',coalesce(v_pi.estado,''),
    'fecha',coalesce(v_pi.fecha::text,''), 'proveedor',coalesce(v_prov, v_pi.id_proveedor, ''),
    'usuario',coalesce(v_pi.usuario,''), 'monto',coalesce(v_pi.monto::text,''),
    'comentario',coalesce(v_pi.comentario,''), 'cargadores', v_carg,
    'fotos', case when coalesce(v_pi.fotos,'')='' then '[]'::jsonb else to_jsonb(string_to_array(v_pi.fotos,',')) end);
end; $$;

create or replace function wh.voucher_data(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_tipo text := lower(btrim(coalesce(p->>'tipo','')));
  v_id   text := btrim(coalesce(p->>'id',''));
  v_tickets jsonb := '[]'::jsonb;
  v_gj jsonb; v_pj jsonb; v_gid text;
begin
  if v_tipo = '' or v_id = '' then return jsonb_build_object('ok',false,'error','tipo e id requeridos'); end if;

  if v_tipo = 'guia' then
    v_gj := wh._voucher_guia(v_id);
    if v_gj is null then return jsonb_build_object('ok',false,'error','Guia no encontrada: '||v_id); end if;
    v_tickets := jsonb_build_array(v_gj);
    if coalesce(v_gj->>'idPreingreso','') <> '' then
      v_pj := wh._voucher_pre(v_gj->>'idPreingreso');
      if v_pj is not null then v_tickets := v_tickets || jsonb_build_array(v_pj); end if;
    end if;

  elsif v_tipo = 'preingreso' then
    v_pj := wh._voucher_pre(v_id);
    if v_pj is null then return jsonb_build_object('ok',false,'error','Preingreso no encontrado: '||v_id); end if;
    v_tickets := jsonb_build_array(v_pj);
    for v_gid in select id_guia from wh.guias where id_preingreso = v_id order by id_guia loop
      v_gj := wh._voucher_guia(v_gid);
      if v_gj is not null then v_tickets := v_tickets || jsonb_build_array(v_gj); end if;
    end loop;

  else
    return jsonb_build_object('ok',false,'error','tipo invalido: '||v_tipo);
  end if;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'tipo', v_tipo, 'idPrincipal', v_id, 'tickets', v_tickets,
    'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI')));
end; $fn$;

grant execute on function wh._voucher_guia(text) to anon, authenticated, service_role;
grant execute on function wh._voucher_pre(text)  to anon, authenticated, service_role;
grant execute on function wh.voucher_data(jsonb)  to anon, authenticated, service_role;
