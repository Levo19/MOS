-- [1003] Personal del Día por Zona — v6: resuelve el nombre del producto en conteos también por EQUIVALENCIAS
--  (antes solo mos.productos.codigo_barra → un código equivalente mostraba el código pelado; ahora cae a
--  mos.equivalencias → sku_base → descripción canónica). Solo mejora el nombre mostrado; no toca conteos.
-- [995] Personal del Día por Zona — v5. Cada venta trae 'verif' (bool): TRUE si un Yape entrante quedó
--  MATCHEADO a esa venta (mos.yapes_entrantes.id_venta + estado='MATCHEADO') → el front pinta el sello ✓✓
--  de virtual verificado. El efectivo cobrado (forma_pago='EFECTIVO') lo deriva el front por la forma.
--  (Base v4 [993]: ventas individuales + guías con id; v3 roles/hora; v2 roster presencia/TZ/pago-por-id.)
-- [993] Personal del Día por Zona — v4. Refinamientos del dueño:
--  · GUÍAS: cada guía trae 'id' (id_guia) para abrir el overlay de guía completa desde el tablero.
--  · VENTAS (zonas): el detalle deja de AGRUPAR por cliente (sumaba "Cliente varios") y devuelve CADA venta
--    individual con hora + idVenta + correlativo + forma de pago → el front lista ticket por ticket (scroll) y al
--    click abre el comprobante completo. Los agregados (vendido/tickets/nclientes) se mantienen.
--  (Base v3 [992]: roles master/admin puro fuera, hora de ingreso, TZ Lima, pago por id.)
-- [992] Personal del Día por Zona — v3. Refinamientos del dueño:
--  A) ROLES: en ALMACÉN se excluye del tablero a MASTER y a ADMIN PURO (rol=ADMIN + app_origen='MOS'); se
--     mantiene al ADMIN ASCENDIDO (rol=ADMIN pero app_origen de app trabajadora: warehouseMos/mosExpress) y a
--     todos los operarios. En ZONAS el roster sale de me.presencia (rol operativo real); se excluye rol master/admin.
--  B) HORA DE INGRESO real (wh.sesiones.hora_inicio) para almacén → el dueño verifica que la sesión es real.
--  C) GUÍAS del día que creó cada persona (wh.guias por usuario: ingreso/salida) → card nuevo en el overlay.
--  Mantiene: TZ America/Lima en todos los filtros, hora en conteos/envasado, idPersonal para cruzar pago.
create or replace function mos.personal_dia_zona(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_app  text := coalesce(me.jwt_app(),'');
  v_zona text := upper(nullif(btrim(coalesce(p->>'zona','')),''));
  v_fec  date := coalesce(nullif(p->>'fecha','')::date, (now() at time zone 'America/Lima')::date);
  v_meta int  := coalesce((p->>'meta')::int, 30);
  v_es_hoy boolean := (v_fec = (now() at time zone 'America/Lima')::date);
  v_out  jsonb;
begin
  if v_app not in ('MOS','mosExpress') and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','') <> 'service_role' then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_zona is null then return jsonb_build_object('ok',false,'error','zona requerida'); end if;

  if v_zona in ('ALMACEN','ALMACÉN','ALM') then
    with roster as (
      select distinct on (s.id_personal)
             s.id_personal,
             nullif(btrim(coalesce(pp.nombre,'') || ' ' || coalesce(pp.apellido,'')),'') nombre_disp,
             coalesce(nullif(btrim(pp.nombre),''), s.id_personal) nombre_first,
             initcap(coalesce(nullif(pp.rol,''),'Almacenero')) rol,
             nullif(left(coalesce(s.hora_inicio,''),5),'') hora_ini
        from wh.sesiones s
        left join mos.personal pp on pp.id_personal = s.id_personal
       where (s.fecha_inicio at time zone 'America/Lima')::date = v_fec
         and upper(coalesce(pp.rol,'')) <> 'MASTER'
         and not (upper(coalesce(pp.rol,'')) = 'ADMIN' and coalesce(pp.app_origen,'') = 'MOS')
       order by s.id_personal, s.fecha_inicio desc
    ),
    aud as (
      select lower(btrim(a.usuario)) k,
             count(distinct a.cod_producto) n,
             jsonb_agg(distinct jsonb_build_object(
               'producto', coalesce(
                   (select pr.descripcion from mos.productos pr where pr.codigo_barra=a.cod_producto or pr.id_producto=a.cod_producto limit 1),
                   (select pr.descripcion from mos.equivalencias eq join mos.productos pr on pr.sku_base=eq.sku_base where eq.codigo_barra=a.cod_producto and coalesce(eq.activo,true)=true limit 1),
                   a.cod_producto),
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
    ),
    gui as (
      select lower(btrim(g.usuario)) k, count(*) n,
             jsonb_agg(jsonb_build_object(
               'id', g.id_guia,
               'tipo', g.tipo,
               'dir', case when g.tipo like 'INGRESO%' then 'in' else 'out' end,
               'hora', to_char(g.fecha at time zone 'America/Lima','HH24:MI'),
               'estado', g.estado, 'monto', g.monto_total,
               'doc', nullif(btrim(coalesce(g.numero_documento,'')),'')) order by g.fecha desc) det
        from wh.guias g
       where (g.fecha at time zone 'America/Lima')::date = v_fec and coalesce(nullif(btrim(g.usuario),''),'') <> ''
       group by lower(btrim(g.usuario))
    )
    select jsonb_agg(jsonb_build_object(
      'idPersonal', r.id_personal,
      'nombre', coalesce(r.nombre_disp, r.nombre_first),
      'rol', r.rol,
      'horaInicio', r.hora_ini,
      'auditados', coalesce(a.n,0),
      'meta', v_meta,
      'conteoDetalle', coalesce(a.det,'[]'::jsonb),
      'rolKind','alm',
      'envasadoUnid', coalesce(e.unid,0),
      'eficiencia', coalesce(e.efic,0),
      'envasado', coalesce(e.det,'[]'::jsonb),
      'guiasN', coalesce(g.n,0),
      'guias', coalesce(g.det,'[]'::jsonb)
    ) order by coalesce(a.n,0) desc, coalesce(r.nombre_disp,r.nombre_first))
    into v_out
    from roster r
    left join aud a on a.k = lower(btrim(coalesce(r.nombre_disp,''))) or a.k = lower(btrim(r.nombre_first))
    left join env e on e.k = lower(btrim(coalesce(r.nombre_disp,''))) or e.k = lower(btrim(r.nombre_first))
    left join gui g on g.k = lower(btrim(coalesce(r.nombre_disp,''))) or g.k = lower(btrim(r.nombre_first));

  else
    with roster0 as (
      select mp.id_personal, mp.nombre nombre_disp, lower(btrim(mp.nombre)) k, initcap(coalesce(nullif(mp.rol,''),'Vendedor')) rol
        from me.presencia mp
       where v_es_hoy and upper(coalesce(mp.zona,'')) = v_zona
         and lower(coalesce(mp.rol,'')) not in ('master','admin')
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
               'producto', coalesce(
                   (select pr.descripcion from mos.productos pr where pr.codigo_barra=a.cod_barras limit 1),
                   (select pr.descripcion from mos.equivalencias eq join mos.productos pr on pr.sku_base=eq.sku_base where eq.codigo_barra=a.cod_barras and coalesce(eq.activo,true)=true limit 1),
                   a.cod_barras),
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
             (select jsonb_agg(jsonb_build_object(
                  'idVenta', t.id_venta,
                  'cliente', coalesce(nullif(btrim(t.cliente_nombre),''),'Cliente varios'),
                  'doc', nullif(btrim(coalesce(t.cliente_doc,'')),''),
                  'hora', to_char(t.fecha at time zone 'America/Lima','HH24:MI'),
                  'monto', t.total, 'forma', t.forma_pago, 'tipoDoc', t.tipo_doc,
                  'corr', nullif(btrim(coalesce(t.correlativo,'')),''),
                  'verif', exists(select 1 from mos.yapes_entrantes ye where ye.id_venta = t.id_venta and upper(coalesce(ye.estado,'')) = 'MATCHEADO')) order by t.fecha desc)
                from (
                  select v2.id_venta, v2.fecha, v2.total, v2.forma_pago, v2.tipo_doc, v2.correlativo, v2.cliente_nombre, v2.cliente_doc
                    from me.ventas v2
                   where v2.vendedor = v.vendedor and (v2.fecha at time zone 'America/Lima')::date=v_fec and upper(coalesce(v2.zona_id,''))=v_zona
                     and upper(coalesce(v2.forma_pago,'')) not like 'ANULADO%'
                   order by v2.fecha desc limit 150) t) det
        from me.ventas v
       where (v.fecha at time zone 'America/Lima')::date = v_fec and upper(coalesce(v.zona_id,'')) = v_zona
         and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
         and coalesce(nullif(btrim(v.vendedor),''),'') <> ''
       group by v.vendedor
    ),
    gui as (
      select lower(btrim(g.usuario)) k, count(*) n,
             jsonb_agg(jsonb_build_object(
               'id', g.id_guia,
               'tipo', g.tipo,
               'dir', case when g.tipo like 'INGRESO%' then 'in' else 'out' end,
               'hora', to_char(g.fecha at time zone 'America/Lima','HH24:MI'),
               'estado', g.estado, 'monto', g.monto_total,
               'doc', nullif(btrim(coalesce(g.numero_documento,'')),'')) order by g.fecha desc) det
        from wh.guias g
       where (g.fecha at time zone 'America/Lima')::date = v_fec and coalesce(nullif(btrim(g.usuario),''),'') <> ''
       group by lower(btrim(g.usuario))
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
      'ventas', coalesce(vn.det,'[]'::jsonb),
      'guiasN', coalesce(g.n,0),
      'guias', coalesce(g.det,'[]'::jsonb)
    ) order by coalesce(vn.monto,0) desc, r.nombre_disp)
    into v_out
    from roster r
    left join aud a on a.k = r.k
    left join ven vn on vn.k = r.k
    left join gui g on g.k = r.k;
  end if;

  return jsonb_build_object('ok',true,'zona',v_zona,'fecha',v_fec,'meta',v_meta,'esHoy',v_es_hoy,
    'personal', coalesce(v_out,'[]'::jsonb));
end; $fn$;

revoke all on function mos.personal_dia_zona(jsonb) from public;
grant execute on function mos.personal_dia_zona(jsonb) to authenticated, anon;

select '1003 personal_dia_zona v6 equivalencias listo' as ok;
