-- [990] "Personal del Día por Zona" — rastreo operativo de cada empleado en una zona/fecha (para el overlay
--  del módulo Zonas). Devuelve por empleado: cuántos PRODUCTOS AUDITÓ (+detalle sistema/real/dif) y su trabajo
--  del rol: ALMACÉN → envasado (unidades, eficiencia); ZONAS → ventas (a quién, monto, tickets).
--  El PAGO del día NO va aquí (se reusa mos.personal_dia_lista, que ya calcula jornal/bonos/desc). Solo lectura.
create or replace function mos.personal_dia_zona(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_app  text := coalesce(me.jwt_app(),'');
  v_zona text := upper(nullif(btrim(coalesce(p->>'zona','')),''));
  v_fec  date := coalesce(nullif(p->>'fecha','')::date, (now() at time zone 'America/Lima')::date);
  v_meta int  := coalesce((p->>'meta')::int, 30);
  v_out  jsonb;
begin
  if v_app not in ('MOS','mosExpress') and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','') <> 'service_role' then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_zona is null then return jsonb_build_object('ok',false,'error','zona requerida'); end if;

  if v_zona in ('ALMACEN','ALMACÉN','ALM') then
    -- ══ ALMACÉN ══ auditó (wh.auditorias) + envasó (wh.envasados), por usuario.
    with aud as (
      select a.usuario,
             count(distinct a.cod_producto) n,
             jsonb_agg(distinct jsonb_build_object(
               'producto', coalesce((select pr.descripcion from mos.productos pr where pr.codigo_barra=a.cod_producto or pr.id_producto=a.cod_producto limit 1), a.cod_producto),
               'sistema', a.stock_sistema, 'real', a.stock_fisico, 'diff', a.diferencia)) det
        from wh.auditorias a
       where coalesce(a.fecha_ejecucion, a.fecha_asignacion)::date = v_fec
         and coalesce(nullif(btrim(a.usuario),''),'') <> ''
       group by a.usuario
    ),
    env as (
      select e.usuario,
             coalesce(sum(e.unidades_producidas),0) unid,
             round(avg(nullif(e.eficiencia_pct,0)))::int efic,
             jsonb_agg(jsonb_build_object(
               'producto', coalesce((select pr.descripcion from mos.productos pr where pr.codigo_barra=e.cod_producto_envasado or pr.codigo_barra=e.cod_producto_base limit 1), coalesce(e.cod_producto_envasado,e.cod_producto_base)),
               'esperadas', e.unidades_esperadas, 'producidas', e.unidades_producidas, 'eficiencia', round(coalesce(e.eficiencia_pct,0))::int) order by e.fecha) det
        from wh.envasados e
       where e.fecha::date = v_fec and coalesce(nullif(btrim(e.usuario),''),'') <> ''
       group by e.usuario
    ),
    todos as (select usuario from aud union select usuario from env)
    select jsonb_agg(jsonb_build_object(
      'nombre', t.usuario,
      'rol', coalesce((select initcap(rol) from mos.personal where lower(btrim(nombre||' '||coalesce(apellido,'')))=lower(btrim(t.usuario)) or lower(btrim(nombre))=lower(btrim(t.usuario)) limit 1),'Almacenero'),
      'auditados', coalesce(a.n,0),
      'meta', v_meta,
      'conteoDetalle', coalesce(a.det,'[]'::jsonb),
      'rolKind','alm',
      'envasadoUnid', coalesce(e.unid,0),
      'eficiencia', coalesce(e.efic,0),
      'envasado', coalesce(e.det,'[]'::jsonb)
    ) order by coalesce(a.n,0) desc, t.usuario)
    into v_out
    from todos t left join aud a on a.usuario=t.usuario left join env e on e.usuario=t.usuario;

  else
    -- ══ ZONA-01 / ZONA-02 ══ auditó (me.auditorias) + vendió (me.ventas), por vendedor.
    with aud as (
      select a.vendedor usuario,
             count(distinct a.cod_barras) n,
             jsonb_agg(distinct jsonb_build_object(
               'producto', coalesce((select pr.descripcion from mos.productos pr where pr.codigo_barra=a.cod_barras limit 1), a.cod_barras),
               'sistema', a.cant_sistema, 'real', a.cant_real, 'diff', a.diferencia)) det
        from me.auditorias a
       where a.fecha::date = v_fec and upper(coalesce(a.zona_id,'')) = v_zona
         and coalesce(nullif(btrim(a.vendedor),''),'') <> ''
       group by a.vendedor
    ),
    ven as (
      select v.vendedor usuario,
             coalesce(sum(v.total),0) monto, count(*) tickets,
             count(distinct coalesce(nullif(btrim(v.cliente_nombre),''), v.cliente_doc, 'varios')) nclientes,
             (select jsonb_agg(x order by (x->>'monto')::numeric desc) from (
                select jsonb_build_object(
                  'cliente', coalesce(nullif(btrim(v2.cliente_nombre),''),'Cliente varios'),
                  'doc', coalesce(nullif(btrim(v2.cliente_doc),''),'—'),
                  'monto', sum(v2.total), 'tickets', count(*)) x
                  from me.ventas v2
                 where v2.vendedor=v.vendedor and v2.fecha::date=v_fec and upper(coalesce(v2.zona_id,''))=v_zona
                   and upper(coalesce(v2.forma_pago,'')) not like 'ANULADO%'
                 group by coalesce(nullif(btrim(v2.cliente_nombre),''),'Cliente varios'), coalesce(nullif(btrim(v2.cliente_doc),''),'—')
                 limit 12) s) det
        from me.ventas v
       where v.fecha::date = v_fec and upper(coalesce(v.zona_id,'')) = v_zona
         and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
         and coalesce(nullif(btrim(v.vendedor),''),'') <> ''
       group by v.vendedor
    ),
    todos as (select usuario from aud union select usuario from ven)
    select jsonb_agg(jsonb_build_object(
      'nombre', t.usuario,
      'rol', coalesce((select initcap(rol) from mos.personal where lower(btrim(nombre||' '||coalesce(apellido,'')))=lower(btrim(t.usuario)) or lower(btrim(nombre))=lower(btrim(t.usuario)) limit 1),'Vendedor'),
      'auditados', coalesce(a.n,0),
      'meta', v_meta,
      'conteoDetalle', coalesce(a.det,'[]'::jsonb),
      'rolKind','zona',
      'vendido', coalesce(vn.monto,0),
      'tickets', coalesce(vn.tickets,0),
      'nclientes', coalesce(vn.nclientes,0),
      'ventas', coalesce(vn.det,'[]'::jsonb)
    ) order by coalesce(a.n,0) desc, t.usuario)
    into v_out
    from todos t left join aud a on a.usuario=t.usuario left join ven vn on vn.usuario=t.usuario;
  end if;

  return jsonb_build_object('ok',true,'zona',v_zona,'fecha',v_fec,'meta',v_meta,
    'personal', coalesce(v_out,'[]'::jsonb));
end; $fn$;

revoke all on function mos.personal_dia_zona(jsonb) from public;
grant execute on function mos.personal_dia_zona(jsonb) to authenticated, anon;

select '990 personal_dia_zona listo' as ok;
