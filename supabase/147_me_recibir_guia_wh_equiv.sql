CREATE OR REPLACE FUNCTION me.recibir_guia_wh(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id   text := btrim(coalesce(p->>'idGuiaWH', p->>'idGuia', ''));
  v_g    wh.guias%rowtype;
  v_ref  text;
  v_ver  me.zona_traslado_verificacion%rowtype;
  v_zona text := upper(btrim(coalesce(p->>'zona','')));   -- opcional: zona ME que recibe (si el cliente la sabe)
  v_lineas jsonb;
  v_nlin int;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuiaWH'); end if;

  select * into v_g from wh.guias where id_guia = v_id;
  if not found then return jsonb_build_object('ok',false,'error','Guía WH no encontrada: '||v_id); end if;

  -- id sintético de la verificación ME para esta guía WH (no colisiona con ids de guías ME).
  v_ref := 'WH:'||v_id;
  select * into v_ver from me.zona_traslado_verificacion where id_guia = v_ref;

  -- líneas DESPACHADAS por WH (cant_recibida): el operario contará contra esto al cerrar. Excluye anuladas y 0.
  -- Incluye lote/vencimiento (control de inventario en recepción): id_lote + fecha_vencimiento de la línea WH.
  select coalesce(jsonb_agg(jsonb_build_object(
      'linea',       d.linea,
      'codBarra',    d.cod_producto,
      'descripcion', coalesce(pr.descripcion, d.cod_producto),
      'enviado',     coalesce(d.cant_recibida, 0),
      'lote',        nullif(btrim(coalesce(d.id_lote,'')), ''),
      'venc',        d.fecha_vencimiento
    ) order by d.linea), '[]'::jsonb), count(*)::int
  into v_lineas, v_nlin
  from wh.guia_detalle d
  left join lateral (select coalesce(
      -- [fix perf] `codigo_barra <> ''` habilita el índice parcial (sin esto el planner hace seq scan de
      -- mos.productos por CADA línea de la guía → O(n_lineas × 2369), frágil con guías grandes y timeout 8s).
      (select pp.descripcion from mos.productos pp where pp.codigo_barra = d.cod_producto and pp.codigo_barra <> '' limit 1),
      (select pp.descripcion from mos.equivalencias e join mos.productos pp on pp.sku_base=e.sku_base and coalesce(nullif(pp.factor_conversion,0),1)=1 where e.codigo_barra = d.cod_producto and e.activo limit 1),
      -- [fix nombres] 3er fallback: WH a veces grabó el id_producto en cod_producto (10 códigos) → resolver por id.
      (select pp.descripcion from mos.productos pp where pp.id_producto = d.cod_producto limit 1)
    ) as descripcion) pr on true
  where d.id_guia = v_id
    and nullif(btrim(coalesce(d.cod_producto,'')),'') is not null
    and coalesce(d.cant_recibida,0) <> 0
    and upper(coalesce(d.observacion,'')) <> 'ANULADO';

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'idGuiaWH',     v_g.id_guia,
      'refVerif',     v_ref,
      'tipoGuia',     v_g.tipo,
      'estadoWH',     v_g.estado,
      'zonaWH',       v_g.id_zona,          -- la zona destino que WH grabó (informativo)
      'zonaRecibe',   nullif(v_zona,''),    -- la zona ME que el cliente declara (puede diferir del label WH)
      'fecha',        v_g.fecha,
      'usuario',      coalesce(v_g.usuario,'—'),
      'comentario',   coalesce(v_g.comentario,''),
      'lineas',       v_nlin,
      'verificada',   (v_ver.id_guia is not null),
      'verificacion', case when v_ver.id_guia is not null then to_jsonb(v_ver) else null end,
      'detalle',      v_lineas)) || mos._frescura_sombra();
end;
$function$
