-- [934 · FASE 1 notificaciones] Push RECURRENTE de CONSIDERADOS por nivel. Cada corrida avisa SOLO lo que
-- sigue pendiente (considerado ACTIVO cuya zona aún NO recibió despacho tras el ingreso) → dinámico: lo ya
-- despachado se cae solo, no se aglomera. Mensaje por nivel: Admin (MOS) = verifica despacho · WH = considera
-- llevar · ME = llegó lo que no te trajeron. (ME general: el push no targetea por zona; el detalle por zona
-- vive en su pickup/lista.) Reusa mos.emitir_push (audiencias por rol/app).
create or replace function mos.cron_considerados_avisar()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_nombres text[];
  v_n int;
  v_cuerpo text;
begin
  -- Nombres de productos con al menos una zona que se debía y AÚN no se despachó tras el ingreso.
  with cons as (
    select z.id, z.sku_base, z.nombre, z.creado, (zz->>'zona') as zona
      from wh.considerados z
      cross join lateral jsonb_array_elements(coalesce(z.zonas,'[]'::jsonb)) zz
     where z.estado = 'ACTIVO'
  ),
  pend as (
    select distinct upper(coalesce(nullif(btrim(c.nombre),''), c.sku_base)) as nombre
      from cons c
     where not exists (
       select 1 from wh.guias g
         join wh.guia_detalle gd on gd.id_guia = g.id_guia
         left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
         left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
        where g.tipo like 'SALIDA%'
          and coalesce(g.id_zona,'') = c.zona
          and coalesce(pr.sku_base, eq.sku_base) = c.sku_base
          and coalesce(gd.created_at, g.fecha) >= c.creado
          and upper(coalesce(gd.observacion,'')) not like 'ANULADO%')
  )
  select array_agg(nombre order by nombre), count(*) into v_nombres, v_n from pend;

  if coalesce(v_n,0) = 0 then return jsonb_build_object('ok', true, 'enviado', false); end if;

  -- "A, B, C… y N más" (estilo aprobado de precios)
  v_cuerpo := array_to_string(v_nombres[1:3], ', ')
    || case when v_n > 3 then '… y ' || (v_n - 3) || ' más' else '' end;

  -- Admin (MOS): verificar que se despache.
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
    'titulo', '📦 Llegó lo que se debía',
    'cuerpo', v_n || ' por despachar (deuda de semanas): ' || v_cuerpo || ' — verifica que se envíe.',
    'data', jsonb_build_object('tipo','considerados')));

  -- WH operador: considera llevar.
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('apps', jsonb_build_array('warehouseMos')),
    'titulo', '🚚 Considera llevar',
    'cuerpo', 'Se debe de semanas pasadas: ' || v_cuerpo || '. Considera despacharlo.',
    'data', jsonb_build_object('tipo','considerados')));

  -- ME (por app; el detalle por zona vive en su pickup): llegó lo que no le trajeron.
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('apps', jsonb_build_array('mosExpress')),
    'titulo', '🎁 Llegó lo que no te trajeron',
    'cuerpo', 'Atenta: llegó ' || v_cuerpo || ' que semanas pasadas no llegó a tu zona.',
    'data', jsonb_build_object('tipo','considerados')));

  return jsonb_build_object('ok', true, 'enviado', true, 'productos', v_n, 'cuerpo', v_cuerpo);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;
grant execute on function mos.cron_considerados_avisar() to service_role;

-- Recurrente: 2 veces al día (Lima ~9am y ~3pm = UTC 14 y 20). Solo avisa lo que sigue pendiente.
select cron.schedule('mos-considerados-avisar', '0 14,20 * * *', 'select mos.cron_considerados_avisar();');
