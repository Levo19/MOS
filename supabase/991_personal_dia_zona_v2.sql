-- [991] Personal del Día por Zona — v2. Correcciones tras revisión del dueño:
--  1) ROSTER POR SESIÓN/PRESENCIA DEL DÍA (no por actividad): para el DÍA DE HOY la lista sale de quién tiene
--     sesión abierta hoy en la app correcta — ZONAS = me.presencia (ME), ALMACÉN = wh.sesiones (WH). Así un
--     master que sólo generó un CPE (venta a su nombre) NO contamina la zona: si no abrió sesión ahí, no aparece.
--     Para días PASADOS (no hay presencia histórica en ME) el roster de zonas cae a actividad de ese día.
--  2) ZONA HORARIA: todos los filtros de fecha castean en 'America/Lima' (antes ::date crudo = UTC → corría la
--     actividad de la noche al día siguiente).
--  3) HORA: cada conteo/envasado/… trae 'hora' (HH24:MI Lima) para que el dueño verifique CUÁNDO se hizo.
--  4) idPersonal en cada fila → el front cruza el PAGO por id (robusto), no por nombre (que fallaba en almacén:
--     RPC daba "Jorgenis Gonzalez" y Finanzas "Jorgenis").
create or replace function mos.personal_dia_zona(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_app  text := coalesce(me.jwt_app(),'');
  v_zona text := upper(nullif(btrim(coalesce(p->>'zona','')),''));
  v_fec  date := coalesce(nullif(p->>'fecha','')::date, (now() at time zone 'America/Lima')::date);
  v_meta int  := coalesce((p->>'meta')::int, 30);
  v_hoy  date := (now() at time zone 'America/Lima')::date;
  v_es_hoy boolean := (v_fec = (now() at time zone 'America/Lima')::date);
  v_out  jsonb;
begin
  if v_app not in ('MOS','mosExpress') and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','') <> 'service_role' then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_zona is null then return jsonb_build_object('ok',false,'error','zona requerida'); end if;

  if v_zona in ('ALMACEN','ALMACÉN','ALM') then
    -- ══ ALMACÉN ══ roster = sesión WH del día (wh.sesiones es histórico por fecha_inicio) + su envasado/auditoría.
    with roster as (
      select distinct on (s.id_personal)
             s.id_personal,
             nullif(btrim(coalesce(pp.nombre,'') || ' ' || coalesce(pp.apellido,'')),'') nombre_disp,
             coalesce(nullif(btrim(pp.nombre),''), s.id_personal) nombre_first,
             initcap(coalesce(nullif(pp.rol,''),'Almacenero')) rol
        from wh.sesiones s
        left join mos.personal pp on pp.id_personal = s.id_personal
       where (s.fecha_inicio at time zone 'America/Lima')::date = v_fec
       order by s.id_personal, s.fecha_inicio desc
    ),
    aud as (
      select lower(btrim(a.usuario)) k,
             count(distinct a.cod_producto) n,
             jsonb_agg(distinct jsonb_build_object(
               'producto', coalesce((select pr.descripcion from mos.productos pr where pr.codigo_barra=a.cod_producto or pr.id_producto=a.cod_producto limit 1), a.cod_producto),
               'sistema', a.stock_sistema, 'real', a.stock_fisico, 'diff', a.diferencia,
               'hora', to_char(coalesce(a.fecha_ejecucion,a.fecha_asignacion) at time zone 'America/Lima','HH24:MI'))) det
        from wh.auditorias a
       where (coalesce(a.fecha_ejecucion, a.fecha_asignacion) at time zone 'America/Lima')::date = v_fec
         and coalesce(nullif(btrim(a.usuario),''),'') <> ''
       group by lower(btrim(a.usuario))
    ),
    env as (
      select lower(btrim(e.usuario)) k,
             coalesce(sum(e.unidades_producidas),0) unid,
             round(avg(nullif(e.eficiencia_pct,0)))::int efic,
             jsonb_agg(jsonb_build_object(
               'producto', coalesce((select pr.descripcion from mos.productos pr where pr.codigo_barra=e.cod_producto_envasado or pr.codigo_barra=e.cod_producto_base limit 1), coalesce(e.cod_producto_envasado,e.cod_producto_base)),
               'esperadas', e.unidades_esperadas, 'producidas', e.unidades_producidas,
               'eficiencia', round(coalesce(e.eficiencia_pct,0))::int,
               'hora', to_char(e.fecha at time zone 'America/Lima','HH24:MI'),
               'colaborador', nullif(btrim(coalesce(e.colaborador,'')),'')) order by e.fecha) det
        from wh.envasados e
       where (e.fecha at time zone 'America/Lima')::date = v_fec and coalesce(nullif(btrim(e.usuario),''),'') <> ''
       group by lower(btrim(e.usuario))
    )
    select jsonb_agg(jsonb_build_object(
      'idPersonal', r.id_personal,
      'nombre', coalesce(r.nombre_disp, r.nombre_first),
      'rol', r.rol,
      'auditados', coalesce(a.n,0),
      'meta', v_meta,
      'conteoDetalle', coalesce(a.det,'[]'::jsonb),
      'rolKind','alm',
      'envasadoUnid', coalesce(e.unid,0),
      'eficiencia', coalesce(e.efic,0),
      'envasado', coalesce(e.det,'[]'::jsonb)
    ) order by coalesce(a.n,0) desc, coalesce(r.nombre_disp,r.nombre_first))
    into v_out
    from roster r
    left join aud a on a.k = lower(btrim(coalesce(r.nombre_disp,''))) or a.k = lower(btrim(r.nombre_first))
    left join env e on e.k = lower(btrim(coalesce(r.nombre_disp,''))) or e.k = lower(btrim(r.nombre_first));

  else
    -- ══ ZONA-01 / ZONA-02 ══ roster = presencia ME de HOY (o actividad si es día pasado) + auditó/vendió.
    with roster0 as (
      select mp.id_personal, mp.nombre nombre_disp, lower(btrim(mp.nombre)) k, initcap(coalesce(nullif(mp.rol,''),'Vendedor')) rol
        from me.presencia mp
       where v_es_hoy and upper(coalesce(mp.zona,'')) = v_zona
         and ( (mp.last_seen at time zone 'America/Lima')::date = v_fec or (mp.ingreso at time zone 'America/Lima')::date = v_fec )
      union all
      select null::text, x.vendedor, lower(btrim(x.vendedor)) k, 'Vendedor'
        from (
          select distinct vendedor from me.ventas
           where (not v_es_hoy) and (fecha at time zone 'America/Lima')::date = v_fec and upper(coalesce(zona_id,''))=v_zona
             and upper(coalesce(forma_pago,'')) not like 'ANULADO%' and coalesce(nullif(btrim(vendedor),''),'')<>''
          union
          select distinct vendedor from me.auditorias
           where (not v_es_hoy) and (fecha at time zone 'America/Lima')::date = v_fec and upper(coalesce(zona_id,''))=v_zona
             and coalesce(nullif(btrim(vendedor),''),'')<>''
        ) x
    ),
    roster as (
      select distinct on (k) k, id_personal, nombre_disp, rol
        from roster0 where coalesce(nullif(btrim(nombre_disp),''),'') <> '' order by k, id_personal nulls last
    ),
    aud as (
      select lower(btrim(a.vendedor)) k,
             count(distinct a.cod_barras) n,
             jsonb_agg(distinct jsonb_build_object(
               'producto', coalesce((select pr.descripcion from mos.productos pr where pr.codigo_barra=a.cod_barras limit 1), a.cod_barras),
               'sistema', a.cant_sistema, 'real', a.cant_real, 'diff', a.diferencia,
               'hora', to_char(a.fecha at time zone 'America/Lima','HH24:MI'))) det
        from me.auditorias a
       where (a.fecha at time zone 'America/Lima')::date = v_fec and upper(coalesce(a.zona_id,'')) = v_zona
         and coalesce(nullif(btrim(a.vendedor),''),'') <> ''
       group by lower(btrim(a.vendedor))
    ),
    ven as (
      select lower(btrim(v.vendedor)) k,
             coalesce(sum(v.total),0) monto, count(*) tickets,
             count(distinct coalesce(nullif(btrim(v.cliente_nombre),''), v.cliente_doc, 'varios')) nclientes,
             (select jsonb_agg(x order by (x->>'monto')::numeric desc) from (
                select jsonb_build_object(
                  'cliente', coalesce(nullif(btrim(v2.cliente_nombre),''),'Cliente varios'),
                  'doc', coalesce(nullif(btrim(v2.cliente_doc),''),'—'),
                  'monto', sum(v2.total), 'tickets', count(*)) x
                  from me.ventas v2
                 where v2.vendedor = v.vendedor and (v2.fecha at time zone 'America/Lima')::date=v_fec and upper(coalesce(v2.zona_id,''))=v_zona
                   and upper(coalesce(v2.forma_pago,'')) not like 'ANULADO%'
                 group by coalesce(nullif(btrim(v2.cliente_nombre),''),'Cliente varios'), coalesce(nullif(btrim(v2.cliente_doc),''),'—')
                 limit 12) s) det
        from me.ventas v
       where (v.fecha at time zone 'America/Lima')::date = v_fec and upper(coalesce(v.zona_id,'')) = v_zona
         and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
         and coalesce(nullif(btrim(v.vendedor),''),'') <> ''
       group by v.vendedor
    )
    select jsonb_agg(jsonb_build_object(
      'idPersonal', coalesce(r.id_personal,''),
      'nombre', r.nombre_disp,
      'rol', r.rol,
      'auditados', coalesce(a.n,0),
      'meta', v_meta,
      'conteoDetalle', coalesce(a.det,'[]'::jsonb),
      'rolKind','zona',
      'vendido', coalesce(vn.monto,0),
      'tickets', coalesce(vn.tickets,0),
      'nclientes', coalesce(vn.nclientes,0),
      'ventas', coalesce(vn.det,'[]'::jsonb)
    ) order by coalesce(vn.monto,0) desc, r.nombre_disp)
    into v_out
    from roster r
    left join aud a on a.k = r.k
    left join ven vn on vn.k = r.k;
  end if;

  return jsonb_build_object('ok',true,'zona',v_zona,'fecha',v_fec,'meta',v_meta,'esHoy',v_es_hoy,
    'personal', coalesce(v_out,'[]'::jsonb));
end; $fn$;

revoke all on function mos.personal_dia_zona(jsonb) from public;
grant execute on function mos.personal_dia_zona(jsonb) to authenticated, anon;

select '991 personal_dia_zona v2 listo' as ok;
