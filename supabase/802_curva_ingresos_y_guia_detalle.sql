-- 802_curva_ingresos_y_guia_detalle.sql — [DUEÑO] "podés poner puntos donde existe un ingreso
-- pero no tiene costo registrado… así sé que ese día entró pero no tiene costo aún" +
-- "al clickear quiero el card moderno detallando la guía donde ingresó, resaltando el producto
-- en cuestión… incluso con preview de la foto".
--
-- Hoy la curva solo sabe de COSTOS. Si la mercadería entró por una guía y nadie cargó el costo,
-- ese día no existe en el gráfico: el dueño no tiene forma de ver el hueco. Estas dos RPC lo
-- cierran.
--
--  (A) mos.curva_ingresos({skuBase|idProducto}) — TODOS los ingresos por guía de ese producto,
--      resolviendo el dominio completo de códigos: los codigo_barra de todos los hermanos del
--      sku (canónico + packs + derivados) MÁS los de mos.equivalencias activas. Cada ingreso
--      dice si tiene un costo VÁLIDO registrado en esa guía (reusa mos._costo_anulacion del
--      801: un costo revertido NO cuenta como registrado). El front pinta un punto hueco en
--      los que vienen con `tieneCosto=false`.
--
--  (B) mos.curva_guia_detalle({idGuia, skuBase|idProducto}) — la guía completa para el card
--      flotante: cabecera (proveedor, documento, fecha, tipo, monto, foto), TODOS los ítems con
--      nombre resuelto y `esEste=true` en las líneas del producto en cuestión, y el costo que
--      esa guía dejó para él (con su motivo de anulación si lo tiene). wh.guia_preview seguía
--      sirviendo al mini-preview viejo: se deja intacta, esta es más rica y no la reemplaza.

create or replace function mos.curva_ingresos(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_idp   text := nullif(btrim(coalesce(p->>'idProducto','')),'');
  v_pv    numeric := 0;
  v_pc    numeric := 0;
  v_out   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_sku is null and v_idp is not null then
    select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) into v_sku
      from mos.productos pr where pr.id_producto = v_idp limit 1;
  end if;
  if v_sku is null then return jsonb_build_object('ok',false,'error','Requiere skuBase o idProducto'); end if;

  -- precio/costo del CANÓNICO: los necesita _costo_anulacion para juzgar cada costo.
  select coalesce(pr.precio_venta,0), coalesce(pr.precio_costo,0) into v_pv, v_pc
    from mos.productos pr
   where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku
     and coalesce(nullif(pr.factor_conversion,0),1) = 1
   order by pr.codigo_barra limit 1;

  with codigos as (
    select upper(btrim(pr.codigo_barra)) cb from mos.productos pr
     where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku
       and nullif(btrim(pr.codigo_barra),'') is not null
    union
    select upper(btrim(eq.codigo_barra)) from mos.equivalencias eq
     where eq.sku_base = v_sku and coalesce(eq.activo, true)
       and nullif(btrim(eq.codigo_barra),'') is not null
  ),
  ing as (
    select d.id_guia,
           sum(coalesce(d.cant_recibida, d.cantidad_aplicada, d.cant_esperada, 0)) cant,
           count(*) lineas,
           max(coalesce(d.precio_unitario,0)) precio_linea
      from wh.guia_detalle d
     where upper(btrim(coalesce(d.cod_producto,''))) in (select cb from codigos)
     group by d.id_guia
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'idGuia',   g.id_guia,
           'ts',       to_char(g.fecha at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
           'proveedor', coalesce(
                          (select pv.nombre from mos.proveedores pv
                            where pv.id_proveedor = g.id_proveedor
                              and coalesce(nullif(btrim(pv.nombre),''),'') <> '' limit 1),
                          nullif(btrim(g.ocr_razon_social),''),
                          nullif(btrim(g.id_proveedor),''), '—'),
           'documento', coalesce(nullif(btrim(g.numero_documento),''),''),
           'estado',    coalesce(g.estado,''),
           'cantidad',  i.cant,
           'lineas',    i.lineas,
           'precioLinea', nullif(i.precio_linea,0),
           'tieneFoto', (coalesce(nullif(btrim(g.foto),''),'') <> ''),
           -- ¿esta guía dejó un costo VÁLIDO para el producto? (revertido = no cuenta)
           'tieneCosto', exists (
              select 1 from mos.historial_precio_costo h
               where h.tipo='COSTO' and h.sku_base = v_sku and h.id_guia = g.id_guia
                 and mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc) is null),
           'costo', (select round(h.valor,4) from mos.historial_precio_costo h
                      where h.tipo='COSTO' and h.sku_base = v_sku and h.id_guia = g.id_guia
                        and mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc) is null
                      order by h.ts desc, h.id desc limit 1)
         ) order by g.fecha), '[]'::jsonb)
    into v_out
    from ing i join wh.guias g on g.id_guia = i.id_guia
   -- SOLO mercadería que ENTRA del proveedor: es la única que tiene un costo por registrar.
   -- Los pickups (GPCK_*, tipo SALIDA_ZONA) y los envasados son movimientos internos — el
   -- producto no entró al negocio, se movió. Contarlos como "ingreso sin costo" seria mentir.
   where upper(btrim(coalesce(g.tipo,''))) = 'INGRESO_PROVEEDOR'
     -- OJO: el estado se escribe ANULADA (femenino), no ANULADO. Se cubren ambos.
     and upper(btrim(coalesce(g.estado,''))) not in ('ANULADA','ANULADO');

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'skuBase', v_sku, 'ingresos', coalesce(v_out,'[]'::jsonb)));
end;
$function$;

grant execute on function mos.curva_ingresos(jsonb) to anon, authenticated, service_role;


create or replace function mos.curva_guia_detalle(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_idp  text := nullif(btrim(coalesce(p->>'idProducto','')),'');
  v_g    record;
  v_pv   numeric := 0;
  v_pc   numeric := 0;
  v_items jsonb;
  v_costo jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_guia is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  if v_sku is null and v_idp is not null then
    select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) into v_sku
      from mos.productos pr where pr.id_producto = v_idp limit 1;
  end if;

  select * into v_g from wh.guias where id_guia = v_guia limit 1;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  select coalesce(pr.precio_venta,0), coalesce(pr.precio_costo,0) into v_pv, v_pc
    from mos.productos pr
   where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = coalesce(v_sku,'~')
     and coalesce(nullif(pr.factor_conversion,0),1) = 1
   order by pr.codigo_barra limit 1;

  -- TODOS los ítems (el card los muestra completos: el dueño quiere ver la guía, no un resumen),
  -- con la(s) línea(s) del producto en cuestión marcadas para resaltarlas.
  with codigos as (
    select upper(btrim(pr.codigo_barra)) cb from mos.productos pr
     where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = coalesce(v_sku,'~')
       and nullif(btrim(pr.codigo_barra),'') is not null
    union
    select upper(btrim(eq.codigo_barra)) from mos.equivalencias eq
     where eq.sku_base = coalesce(v_sku,'~') and coalesce(eq.activo, true)
       and nullif(btrim(eq.codigo_barra),'') is not null
  )
  select coalesce(jsonb_agg(x.obj order by x.linea), '[]'::jsonb) into v_items
    from (
      select d.linea, jsonb_build_object(
               'linea', d.linea,
               'codigo', coalesce(d.cod_producto,''),
               'nombre', coalesce((select pr.descripcion from mos.productos pr
                                    where upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto)) limit 1),
                                  d.cod_producto),
               'cantidad', coalesce(d.cant_recibida, d.cantidad_aplicada, d.cant_esperada, 0),
               'precio',   nullif(coalesce(d.precio_unitario,0),0),
               'esEste',   (upper(btrim(coalesce(d.cod_producto,''))) in (select cb from codigos))
             ) obj
        from wh.guia_detalle d where d.id_guia = v_guia
    ) x;

  -- el costo que ESTA guía dejó para el producto (con su motivo de anulación si lo tiene)
  if v_sku is not null then
    select jsonb_build_object(
             'valor', round(h.valor,4), 'usuario', h.usuario, 'source', coalesce(h.source,''),
             'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
             'motivoAnulacion', mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc))
      into v_costo
      from mos.historial_precio_costo h
     where h.tipo='COSTO' and h.sku_base = v_sku and h.id_guia = v_guia
     order by h.ts desc, h.id desc limit 1;
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idGuia', v_g.id_guia,
    'fecha',  to_char(v_g.fecha at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'),
    'tipo',   coalesce(v_g.tipo,''),
    'estado', coalesce(v_g.estado,''),
    'usuario', coalesce(v_g.usuario,''),
    'zona',   coalesce(v_g.id_zona,''),
    'comentario', coalesce(v_g.comentario,''),
    'proveedor', coalesce(
                   (select pv.nombre from mos.proveedores pv where pv.id_proveedor = v_g.id_proveedor
                     and coalesce(nullif(btrim(pv.nombre),''),'') <> '' limit 1),
                   nullif(btrim(v_g.ocr_razon_social),''),
                   nullif(btrim(v_g.id_proveedor),''), '—'),
    'documento', coalesce(nullif(btrim(v_g.numero_documento),''),''),
    'monto',  nullif(v_g.monto_total, 0),
    'foto',   coalesce(nullif(btrim(v_g.foto),''), ''),
    'nItems', jsonb_array_length(v_items),
    'items',  v_items,
    'costo',  v_costo
  ));
end;
$function$;

grant execute on function mos.curva_guia_detalle(jsonb) to anon, authenticated, service_role;
