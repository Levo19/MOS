-- ============================================================
-- 121_mos_eco_status.sql — [MIGRACIÓN MOS · FASE 2 · SEMÁFORO ECOSISTEMA · INERTE]
-- Porta a RPC Supabase el getter COMPUTADO del semáforo del ecosistema:
--   · mos.eco_status(p jsonb {})  ← getEcoStatus (gas/Conexiones.gs:825)
--
-- Esto LEVANTA el bloqueador de la NOTA E de 119_mos_computados.sql (getEcoStatus quedó
-- diferido porque dependía de ZONAS_CONFIG, mapa serie→zona / estación→zona, que NO está
-- migrado como tabla). Aquí se reconstruye ZONAS_CONFIG como CTE-vista derivada de
-- mos.series_documentales + mos.estaciones (tal como Config.gs:getZonasConfig lo arma desde
-- el catálogo), y luego se arma el semáforo con paridad exacta de shape.
--
-- ⚠️ INERTE / NO-APLICAR-AL-FRONT-AUN: este archivo SOLO define la RPC con su grant. NADIE la
--    llama todavía (no se cabló api.js). MOS sigue 100% por GAS para este panel. Idéntico
--    patrón inerte que 93/94/109/110/113/119.
--
-- ── DERIVACIÓN ZONAS_CONFIG (espeja Config.gs getZonasConfig, líneas 77-127) ─────────────────
--   El GAS arma una fila por ESTACIÓN con: { Estacion_Nombre=estaciones.nombre, Zona_ID=id_zona,
--   Serie_Nota/Boleta/Factura } donde las series se toman de SERIES_DOCUMENTALES (filtradas por
--   activo) preferentemente por id_estacion, fallback por id_zona, normalizando tipo_documento
--   (NOTA_VENTA→Serie_Nota, BOLETA→Serie_Boleta, FACTURA→Serie_Factura).
--   getEcoStatus luego deriva DOS mapas de esas filas (gas/Conexiones.gs:853-879):
--     · serieZonaMap[serie]            → Zona_ID   (primera ocurrencia gana, todas las series→misma zona de su fila)
--     · estZonaMap[Estacion_Nombre]    → Zona_ID   (primera ocurrencia gana)
--   Aquí se reproducen ambos directo de las sombras:
--     · serie→zona  = distinct-on(serie)  desde series_documentales activas, order by serie,id_estacion
--     · estacion(nombre)→zona = distinct-on(nombre) desde estaciones, order by nombre,id_estacion
--   PARIDAD "primera gana": en GAS depende del orden de filas de la hoja; aquí se ordena por
--   id_estacion (estable). En datos reales cada serie y cada nombre de estación mapean
--   consistentemente a UNA zona (verificado), así que la diferencia de orden es inocua salvo
--   colisión real (nombre de estación repetido en dos zonas → gana el id_estacion menor; misma
--   ambigüedad que ya tiene el GAS).
--
-- ── PARIDAD DE TIEMPO RELATIVO ("hace N min") ────────────────────────────────────────────────
--   El GAS calcula strings relativos al `new Date()` del request (ultimaVenta/ultimaGuia/
--   zona.ultimaVenta). En SQL se usa now() (timestamptz). DECISIÓN: se devuelve AMBOS para que
--   el front tenga total libertad:
--     · el STRING "hace N min" / "hace Nh" YA calculado contra now()  → paridad 1:1 con el GAS.
--     · el timestamp ISO-Z del evento (vía mos._iso_z) en un campo paralelo *Ts → el front
--       puede recalcular el relativo contra su propio reloj si lo prefiere.
--   La fórmula del string replica exacto al GAS: diffMin=round((now-ts)/60000);
--   diffMin<60 ? 'hace '+diffMin+' min' : 'hace '+round(diffMin/60)+'h'.
--
-- ── GATE + ENVOLTORIO (igual que 113/119) ────────────────────────────────────────────────────
--   mos._claim_ok()        (74)  — service_role/GAS o claim app='MOS'; otro → APP_NO_AUTORIZADA.
--   mos._frescura_sombra() (94)  — agrega _heartbeat/_now/_ttl_min/_fresh al envoltorio.
--   mos._iso_z(ts)               — timestamptz → 'YYYY-MM-DDTHH:MI:SSZ' (UTC).
--   TZ America/Lima en todos los cortes de fecha/hora. camelCase paritario. revoke public +
--   grant service_role+authenticated. stable, security definer, set search_path=''.
--
-- ── SHAPE DE RETORNO (paritario EXACTO con getEcoStatus.data) ────────────────────────────────
--   { ok:true,
--     data:{
--       ok:true,                                  -- (el GAS pone ok dentro de data también)
--       me:{ color, ventasHoy, totalHoy, ultimaVenta, ultimaVentaTs,
--            zonas:[{zona, ventas, total, ultimaVenta, ultimaVentaTs}],
--            personal:[{nombre, estacion, zona, estado, desde, hasta}],
--            error:null },
--       wh:{ color, entradasHoy, salidasHoy, ultimaGuia, ultimaGuiaTs,
--            sesionActiva:{usuario, rol, desde}|null, stockCritico, error:null }
--     }
--   } || mos._frescura_sombra()
--   (*Ts = extensiones aditivas para recálculo en cliente; no rompen lectores que ignoran claves extra.)
--
-- ── GAPS / DIFERENCIAS vs el GAS (honestidad 40x · ver bloque NOTAS al final) ────────────────
--   G1) wh.sesiones NO tiene columnas usuario/rol/entrada (la hoja SESIONES sí). La sombra trae
--       id_personal + hora_inicio(text "HH:MM:SS") + fecha_inicio. Se resuelve usuario/rol vía
--       JOIN a mos.personal por id_personal (usuario = nombre+apellido). Es la mejor fidelidad
--       posible; si un id_personal no existe en mos.personal, usuario cae al id crudo. Ver NOTA G1.
--   G2) stockCritico: el GAS lo toma de getStockWarehouse().filter(alertaMinimo). Aquí se computa
--       igual que mos.rotacion_productos (113): cuenta filas de wh.stock con cantidad < stock_minimo
--       resuelto desde mos.productos (por cod_producto = id/sku/cb). Paridad con alertaMinimo.
--   G3) error MosExpress/WH: el GAS captura excepciones por app y devuelve {color:'red',error:msg}.
--       Aquí, al ser una sola query SQL transaccional, no hay fallo parcial por app; error queda
--       null salvo que la RPC entera falle (entonces el envoltorio devuelve ok:false). Ver NOTA G3.
-- ============================================================

create schema if not exists mos;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.eco_status(p jsonb) — p = {} (sin parámetros; el día es "hoy" en TZ America/Lima como el GAS)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.eco_status(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_now  timestamptz := now();
  v_hoy  date         := (v_now at time zone 'America/Lima')::date;
  v_me   jsonb;
  v_wh   jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- helper inline para "hace N min / Nh" (replica exacto la fórmula del GAS contra v_now)
  -- diffMin = round((now - ts)/60000ms);  <60 → 'hace N min'  ; else → 'hace round(N/60)h'
  --   (se usa abajo vía expresión repetida porque plpgsql no permite función anidada).

  -- ── ZONAS_CONFIG derivado (mapas serie→zona y estacion(nombre)→zona) ──────────────────────
  with
  serie_zona as (
    -- distinct-on(serie): primera (id_estacion menor) gana, igual semántica que "primera fila de la hoja gana"
    select distinct on (sd.serie)
           btrim(sd.serie) as serie, sd.id_zona as zona
    from mos.series_documentales sd
    where coalesce(sd.activo, false) = true
      and nullif(btrim(sd.serie), '') is not null
      and nullif(btrim(sd.id_zona), '') is not null
    order by sd.serie, sd.id_estacion
  ),
  est_zona as (
    -- estZonaMap[Estacion_Nombre] → Zona_ID ; primera (id_estacion menor) gana
    select distinct on (btrim(e.nombre))
           btrim(e.nombre) as nombre, e.id_zona as zona
    from mos.estaciones e
    where nullif(btrim(e.nombre), '') is not null
      and nullif(btrim(e.id_zona), '') is not null
    order by btrim(e.nombre), e.id_estacion
  ),

  -- ════════════════════ MosExpress ════════════════════
  -- Ventas de HOY no anuladas (GAS: estado === 'ANULADO' se salta; comparación case-sensitive exacta).
  ventas_hoy as (
    select
      v.total,
      v.fecha,
      -- zona: primero por correlativo (split('-')[0] → serie → zona), luego estZonaMap[estacion], luego 'Sin zona'
      coalesce(
        (select sz.zona from serie_zona sz
          where sz.serie = btrim(split_part(coalesce(v.correlativo,''), '-', 1))
            and nullif(btrim(coalesce(v.correlativo,'')), '') is not null),
        (select ez.zona from est_zona ez where ez.nombre = btrim(coalesce(v.estacion,''))),
        'Sin zona'
      ) as zona
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date = v_hoy
      and coalesce(v.estado_envio,'') <> 'ANULADO'
  ),
  ventas_tot as (
    select
      count(*)                         as ventas_hoy,
      coalesce(sum(total), 0)          as total_hoy,
      max(fecha)                       as ultima_venta
    from ventas_hoy
  ),
  -- agregado por zona (ordenado por total desc como el GAS)
  zonas_agg as (
    select
      zona,
      count(*)                         as ventas,
      round(coalesce(sum(total),0), 2) as total,
      max(fecha)                       as ultima_venta
    from ventas_hoy
    group by zona
  ),
  zonas_arr as (
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'zona',        za.zona,
               'ventas',      za.ventas,
               'total',       za.total,
               'ultimaVenta',
                 case when za.ultima_venta is null then 'Sin ventas'
                      when round(extract(epoch from (v_now - za.ultima_venta))/60.0) < 60
                        then 'hace ' || round(extract(epoch from (v_now - za.ultima_venta))/60.0)::int || ' min'
                      else 'hace ' || round(round(extract(epoch from (v_now - za.ultima_venta))/60.0)/60.0)::int || 'h'
                 end,
               'ultimaVentaTs', mos._iso_z(za.ultima_venta)
             )
             order by za.total desc
           ), '[]'::jsonb) as arr
    from zonas_agg za
  ),
  -- Personal del día = todas las cajas abiertas hoy (por fecha_apertura en Lima).
  -- estado: ABIERTA → 'activo', resto → 'cerrado'. desde=HH:mm apertura, hasta=HH:mm cierre (o '').
  -- zona: zona_id directa → estZonaMap[estacion] → '—'. Orden: activos primero, luego por 'desde' asc.
  personal_rows as (
    select
      coalesce(nullif(btrim(c.vendedor),''), '—')                        as nombre,
      btrim(coalesce(c.estacion,''))                                     as estacion,
      coalesce(
        nullif(btrim(coalesce(c.zona_id,'')), ''),
        (select ez.zona from est_zona ez where ez.nombre = btrim(coalesce(c.estacion,''))),
        '—'
      )                                                                  as zona,
      case when upper(coalesce(c.estado,'')) = 'ABIERTA' then 'activo' else 'cerrado' end as estado,
      to_char(c.fecha_apertura at time zone 'America/Lima', 'HH24:MI')   as desde,
      case when c.fecha_cierre is not null
           then to_char(c.fecha_cierre at time zone 'America/Lima', 'HH24:MI')
           else '' end                                                   as hasta
    from me.cajas c
    where c.fecha_apertura is not null
      and (c.fecha_apertura at time zone 'America/Lima')::date = v_hoy
  ),
  personal_arr as (
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'nombre',   pr.nombre,
               'estacion', pr.estacion,
               'zona',     pr.zona,
               'estado',   pr.estado,
               'desde',    pr.desde,
               'hasta',    pr.hasta
             )
             order by (case when pr.estado = 'activo' then 0 else 1 end), pr.desde
           ), '[]'::jsonb) as arr,
           bool_or(pr.estado = 'activo') as algun_activo
    from personal_rows pr
  ),

  -- ════════════════════ warehouseMos ════════════════════
  -- Guías de HOY: tipo contiene ENTRADA o INGRESO → entradasHoy; resto → salidasHoy.
  guias_hoy as (
    select
      (upper(coalesce(g.tipo,'')) like '%ENTRADA%' or upper(coalesce(g.tipo,'')) like '%INGRESO%') as es_entrada,
      g.fecha
    from wh.guias g
    where g.fecha is not null
      and (g.fecha at time zone 'America/Lima')::date = v_hoy
  ),
  guias_tot as (
    select
      count(*) filter (where es_entrada)        as entradas_hoy,
      count(*) filter (where not es_entrada)    as salidas_hoy,
      max(fecha)                                as ultima_guia
    from guias_hoy
  ),
  -- Sesión ACTIVA (GAS toma la primera ACTIVA recorriendo de abajo hacia arriba → la última fila ACTIVA).
  -- Resolvemos usuario/rol vía mos.personal (la sombra no trae usuario/rol/entrada). Ver GAP G1.
  sesion_act as (
    select
      coalesce(
        nullif(btrim(concat_ws(' ', pe.nombre, pe.apellido)), ''),
        s.id_personal
      )                                          as usuario,
      coalesce(pe.rol, '')                       as rol,
      coalesce(substr(btrim(s.hora_inicio), 1, 5), '--:--') as desde
    from wh.sesiones s
    left join mos.personal pe on pe.id_personal = s.id_personal
    where upper(coalesce(s.estado,'')) = 'ACTIVA'
    order by s.fecha_inicio desc nulls last, s.id_sesion desc
    limit 1
  ),
  -- stockCritico: filas de wh.stock con cantidad < stock_minimo (resuelto desde mos.productos). Paridad alertaMinimo (113).
  prod_by_id as (
    select pr.id_producto as k, pr.stock_minimo from mos.productos pr
  ),
  prod_by_sku as (
    select distinct on (pr.sku_base) pr.sku_base as k, pr.stock_minimo
    from mos.productos pr where nullif(btrim(pr.sku_base),'') is not null
    order by pr.sku_base, pr.id_producto
  ),
  prod_by_cb as (
    select distinct on (pr.codigo_barra) pr.codigo_barra as k, pr.stock_minimo
    from mos.productos pr where nullif(btrim(pr.codigo_barra),'') is not null
    order by pr.codigo_barra, pr.id_producto
  ),
  stock_crit as (
    select count(*) as n
    from wh.stock s
    left join prod_by_id  pid on pid.k = s.cod_producto
    left join prod_by_sku psk on psk.k = s.cod_producto
    left join prod_by_cb  pcb on pcb.k = s.cod_producto
    where coalesce(s.cantidad_disponible, 0)
          < coalesce(pid.stock_minimo, psk.stock_minimo, pcb.stock_minimo, 0)
  )

  -- ── ARMADO FINAL ──────────────────────────────────────────────────────────────────────────
  select
    jsonb_build_object(
      'color',
        case when vt.ventas_hoy > 0 or pa.algun_activo then 'green' else 'yellow' end,
      'ventasHoy',   vt.ventas_hoy,
      'totalHoy',    round(vt.total_hoy, 2),
      'ultimaVenta',
        case when vt.ultima_venta is not null then
               case when round(extract(epoch from (v_now - vt.ultima_venta))/60.0) < 60
                      then 'hace ' || round(extract(epoch from (v_now - vt.ultima_venta))/60.0)::int || ' min'
                    else 'hace ' || round(round(extract(epoch from (v_now - vt.ultima_venta))/60.0)/60.0)::int || 'h'
               end
             when vt.ventas_hoy > 0 then 'hoy'
             else 'Sin ventas hoy' end,
      'ultimaVentaTs', mos._iso_z(vt.ultima_venta),
      'zonas',       za.arr,
      'personal',    pa.arr,
      'error',       null
    ) as me,
    jsonb_build_object(
      'color',
        case when gt.entradas_hoy > 0 or gt.salidas_hoy > 0 or sa.usuario is not null
             then 'green' else 'yellow' end,
      'entradasHoy', gt.entradas_hoy,
      'salidasHoy',  gt.salidas_hoy,
      'ultimaGuia',
        case when gt.ultima_guia is not null then
               case when round(extract(epoch from (v_now - gt.ultima_guia))/60.0) < 60
                      then 'hace ' || round(extract(epoch from (v_now - gt.ultima_guia))/60.0)::int || ' min'
                    else 'hace ' || round(round(extract(epoch from (v_now - gt.ultima_guia))/60.0)/60.0)::int || 'h'
               end
             when (gt.entradas_hoy + gt.salidas_hoy) > 0 then 'hoy'
             else 'Sin guías hoy' end,
      'ultimaGuiaTs', mos._iso_z(gt.ultima_guia),
      'sesionActiva',
        case when sa.usuario is null then null
             else jsonb_build_object('usuario', sa.usuario, 'rol', sa.rol, 'desde', sa.desde) end,
      'stockCritico', sc.n,
      'error',        null
    ) as wh
  into v_me, v_wh
  from ventas_tot vt
  cross join zonas_arr za
  cross join personal_arr pa
  cross join guias_tot gt
  cross join stock_crit sc
  left join lateral (select * from sesion_act) sa on true;

  return jsonb_build_object(
           'ok', true,
           'data', jsonb_build_object(
             'ok', true,
             'me', v_me,
             'wh', v_wh
           )
         ) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.eco_status(jsonb) from public;
grant execute on function mos.eco_status(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS (honestidad 40x)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- G1) SESIÓN ACTIVA — usuario/rol resueltos vía mos.personal (la sombra wh.sesiones NO trae esas columnas).
--     Estructura real verificada (information_schema):
--       wh.sesiones: id_sesion, id_personal, fecha_inicio(tstz), hora_inicio(text "HH:MM:SS"),
--                    fecha_fin, hora_fin, minutos_activos, estado.
--     El GAS leía de la HOJA SESIONES columnas 'usuario'/'rol'/'entrada' (que la hoja sí tiene) — la
--     sombra normalizó esos campos a id_personal. Resolución: JOIN a mos.personal → usuario = nombre+' '+
--     apellido, rol = personal.rol, desde = substr(hora_inicio,1,5)="HH:MM". Si el id_personal no existe en
--     mos.personal, usuario cae al id crudo y rol=''. Diferencia: el GAS mostraría el string EXACTO de la
--     hoja (que casi siempre ya es el nombre); aquí mostramos nombre+apellido del maestro. Misma persona,
--     formato potencialmente distinto. Selección de "la sesión ACTIVA": el GAS toma la ÚLTIMA fila ACTIVA
--     (recorre de abajo arriba y rompe en la primera) ⇒ aquí order by fecha_inicio desc, id_sesion desc.
--
-- G2) stockCritico — paridad con getStockWarehouse().filter(alertaMinimo). Se computa idéntico a
--     mos.rotacion_productos (113): cantidad_disponible < stock_minimo, con stock_minimo resuelto desde
--     mos.productos probando cod_producto contra id_producto → sku_base → codigo_barra (primera gana).
--     Si el cod_producto no resuelve en catálogo, stock_minimo=0 ⇒ no cuenta como crítico (cantidad<0 falso),
--     igual que el GAS (p.stock_minimo undefined → comparación con 0).
--
-- G3) ERRORES POR APP — el GAS envuelve ME y WH en try/catch SEPARADOS y, ante excepción, devuelve
--     {color:'red', error:<msg>} para esa app dejando la otra intacta. Esta RPC es UNA sola consulta SQL;
--     no hay fallo parcial por app. Si TODO falla, el caller recibe el error de pg (y la capa api.js debe
--     mapearlo a ok:false). Los campos 'error' de me/wh quedan en null en el camino feliz, igual que el GAS
--     cuando no hay excepción. Diferencia: no se modela el escenario "ME ok, WH red" (o viceversa) porque en
--     Supabase las dos sombras viven en la misma DB y se leen en la misma transacción.
--
-- T)  TIEMPO RELATIVO — se devuelven los strings "hace N min/Nh" (paridad 1:1 con el GAS, calculados contra
--     now()) Y los timestamps ISO-Z (*Ts) para recálculo en cliente. El front puede usar cualquiera. La
--     fórmula del string es idéntica: round((now-ts)/60000); <60→min, else→round(/60)h. NOTA: el GAS usa
--     Math.round; SQL usa round() (half-up) — equivalentes para enteros positivos de minutos.
--
-- Z)  ZONAS_CONFIG — reconstruido como CTE (serie_zona + est_zona) en vez de tabla/vista persistente, para
--     mantener el archivo autocontenido e inerte. Si una sesión futura quiere materializarlo como VISTA
--     reusable (otros getters lo pedían), extraer las dos CTE a `create view mos.zonas_config_map as ...`.
--     Fuente: mos.series_documentales (serie/id_zona/id_estacion/activo) + mos.estaciones (nombre/id_zona).
--     COBERTURA: todas las columnas que el GAS necesitaba (Serie_*, Estacion_Nombre, Zona_ID) existen en las
--     sombras → NO falta ninguna columna. El mapa es derivable con fidelidad completa.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
