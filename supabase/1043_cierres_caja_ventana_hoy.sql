-- 1043 · mos.cierres_caja: parámetro opcional p->>'ventana'='hoy' (2026-10-09)
-- Problema: la vista Cajas del panel MOS es el mayor consumo de CPU de la BD. _cajasRefreshSilencioso llamaba
-- cierres_caja (30 días completos: ~10k tickets, ~7,7 MB de JSON, ~1 s) en cada venta por realtime (coalesce 8 s)
-- y en el poll de 60 s.
-- Cambio:
--   · p->>'ventana'='hoy' → solo las cajas del día (ABIERTA aunque venga de ayer ∪ cerradas con apertura o cierre
--     hoy en Lima), con sus tickets/extras COMPLETOS, + tickets fechados hoy. KPIs (kpis + kpisTickets) se
--     devuelven IGUALES al modo completo (cajasCerradas = conteo 30d; kpisTickets.mes = 30d). Agrega data.ventana='hoy'.
--   · Sin el parámetro: salida IDÉNTICA a la anterior (verificado byte a byte contra la versión viva, sin generadoEn).
--   · kpisTickets reescrito barato (mismo resultado): el subquery aplanado re-evaluaba upper()/to_char(at tz) en
--     cada uno de los 10 count filter (~170 ms). También acelera el modo completo.
--   · SET plan_cache_mode=force_custom_plan: los predicados "not v_modo_hoy or …" se resuelven por llamada
--     (con plan genérico no se podarían y el modo hoy perdería el BitmapOr fecha ∪ id_caja).
-- Medición (arnés DO en transacción read only, 3 corridas, ms de ejecución en servidor):
--   versión viva ~1000 ms · nueva completa ~850 ms · nueva 'hoy' ~51 ms (248 KB vs 7,7 MB).
-- Índices: modo hoy usa ix_me_ventas_fecha(_zona) (fecha >= 00:00 Lima) ∪ ix_me_ventas_caja (id_caja = any(cajas del día)).
-- getCierresDia (historial) manda {fecha} sin ventana → modo completo, sin cambios.
begin;
CREATE OR REPLACE FUNCTION mos.cierres_caja(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
 SET work_mem TO '32MB'
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
declare
  v_tz        text := 'America/Lima';
  v_hoy       date := (now() at time zone v_tz)::date;
  v_limite    timestamptz := now() - interval '30 days';
  v_me_url    text;
  v_out       jsonb;
  -- KPIs tickets (mes = ventana 30d; hoy = día Lima)
  v_kt        jsonb;
  v_kpis      jsonb;
  v_abiertas  jsonb;
  v_cerradas  jsonb;
  v_todos     jsonb;
  -- [1043] ventana 'hoy': el refresco automático del panel (realtime/poll/post-acciones) solo necesita lo de
  -- HOY. Sin el parámetro el comportamiento es IDÉNTICO al anterior (30 días completos).
  v_modo_hoy  boolean := coalesce(p->>'ventana','') = 'hoy';
  v_ini_hoy   timestamptz := (v_hoy::timestamp at time zone v_tz);         -- 00:00 Lima de hoy
  v_fin_hoy   timestamptz := ((v_hoy + 1)::timestamp at time zone v_tz);  -- 00:00 Lima de mañana
  v_cajas_sel text[];        -- modo hoy: cajas del día (abiertas ∪ apertura/cierre hoy). NULL en modo completo.
  v_n_cerr    int;           -- modo hoy: conteo de cerradas de la ventana 30d (kpis.cajasCerradas sin cambiar)
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- [GAP-1] ME_GAS_URL: Script Property en GAS → se intenta leer de mos.config; fallback '' (= GAS sin config).
  begin
    select valor into v_me_url from mos.config where clave = 'ME_GAS_URL' limit 1;
  exception when others then v_me_url := null;
  end;
  v_me_url := coalesce(v_me_url, '');

  -- [1043] Modo hoy: fija el conjunto de cajas = el mismo "cajasHoy" que arma el kpi de abajo (y el cliente):
  -- ABIERTA (aunque venga de un día anterior: turno que cruza medianoche) ∪ cerradas cuya apertura o cierre
  -- (en Lima) es hoy, respetando el filtro de inclusión 30d. Sus tickets/extras se traen COMPLETOS (toda la
  -- ventana 30d de esa caja) → los objetos de caja salen byte-iguales a los del modo completo.
  if v_modo_hoy then
    select coalesce(array_agg(c.id_caja), '{}'::text[])
      into v_cajas_sel
      from me.cajas c
     where not (coalesce(c.estado,'')='CERRADA' and (c.fecha_cierre is null or c.fecha_cierre < v_limite))
       and (   coalesce(c.estado,'') = 'ABIERTA'
            or (c.fecha_apertura at time zone v_tz)::date = v_hoy
            or (c.fecha_cierre   at time zone v_tz)::date = v_hoy);
    -- kpis.cajasCerradas en modo completo = largo de la lista 30d; se conserva el mismo número (me.cajas es chica).
    select count(*)::int into v_n_cerr
      from me.cajas c
     where not (coalesce(c.estado,'')='CERRADA' and (c.fecha_cierre is null or c.fecha_cierre < v_limite))
       and coalesce(c.estado,'') <> 'ABIERTA';
  end if;

  -- ════════════════════════════════════════════════════════════════════════════════════════════════════
  -- CTE base: VENTAS dentro de ventana 30d, con estado derivado de forma_pago + desglose efectivo/otros.
  -- ════════════════════════════════════════════════════════════════════════════════════════════════════
  with
  cajas_map as (
    -- vendedor/zona del TICKET (cajaMap del GAS): zona = zona_id || estacion.
    select c.id_caja,
           coalesce(c.vendedor,'')                          as vendedor,
           coalesce(nullif(c.zona_id,''), coalesce(c.estacion,'')) as zona
    from me.cajas c
  ),
  ventas_raw as (
    select
      coalesce(v.id_caja,'')                                as id_caja,
      coalesce(v.forma_pago,'EFECTIVO')                     as forma_pago,
      coalesce(v.tipo_doc,'NOTA_DE_VENTA')                  as tipo_doc,
      coalesce(v.total,0)::numeric                          as total,
      v.fecha                                               as fecha_ts,
      v.id_venta, v.correlativo, v.cliente_doc, v.cliente_nombre, v.obs,
      -- [v2.43.388] vendedor REAL del ticket (antes el ticket heredaba el vendedor de la
      -- CAJA → los tickets de un 2.º vendedor en la misma caja salían como el dueño, p.ej.
      -- las 5 ventas de Fernando en la caja de Sergio aparecían como "Sergio").
      coalesce(nullif(btrim(v.vendedor),''),'')             as vendedor,
      v.created_at
    from me.ventas v
    -- ventana 30d: descarta SOLO si fecha presente y < limite (NULL pasa, = paridad GAS "instanceof Date").
    where (v.fecha is null or v.fecha >= v_limite)
      -- [1043] modo hoy: tickets de hoy (ix_me_ventas_fecha) ∪ TODOS los de las cajas del día (ix_me_ventas_caja).
      and (not v_modo_hoy or v.fecha >= v_ini_hoy or v.id_caja = any(v_cajas_sel))
  ),
  ventas as (
    select vr.*,
      -- estado derivado de forma_pago (regla en piedra)
      case
        -- [100x] prefix-match ANULADO% para capturar ANULADO_CONVERSION (NV→CPE) igual que GAS y que
        -- 311/312. Con exact-match un ANULADO_CONVERSION caía en COMPLETADO y se SUMABA al total (doble-conteo).
        when upper(vr.forma_pago) like 'ANULADO%'          then 'ANULADO'
        when upper(vr.forma_pago) = 'CREDITO'              then 'CREDITO'
        when upper(vr.forma_pago) = 'POR_COBRAR'           then 'POR_COBRAR'
        else 'COMPLETADO'
      end                                                   as estado,
      -- tipo corto
      case upper(vr.tipo_doc)
        when 'BOLETA'  then 'B'
        when 'FACTURA' then 'F'
        else 'NV'
      end                                                   as tipo,
      case when vr.fecha_ts is not null
           then to_char(vr.fecha_ts at time zone v_tz, 'YYYY-MM-DD') else '' end as fecha,
      case when vr.fecha_ts is not null
           then to_char(vr.fecha_ts at time zone v_tz, 'HH24:MI')    else '' end as hora
    from ventas_raw vr
  ),
  -- [fix doble-conteo] idVentas cuya deuda se cobró vía cobro (asignado/directo): dejan un movimiento
  -- 'Abono deuda' con el idVenta en la obs. Su plata es el INGRESO (contado en entradas), NO el efectivo
  -- de la venta → se pone efe=0 (si no, efectivoEsperado los cuenta 2x: venta EFECTIVO + INGRESO).
  cobradas as (
    select distinct nullif(btrim(substring(m.obs from 'ticket ([^ ]+)')),'') as id_venta
    from me.movimientos_extra m
    where m.concepto = 'Abono deuda' and coalesce(m.obs,'') <> ''
  ),
  -- desglose efectivo/otros por venta cobrada (MIXTO parsea EFE:/VIR:)
  ventas_calc as (
    select vt.*,
      cm.vendedor as cm_vendedor,
      coalesce(cm.zona,'') as cm_zona,
      -- efe/vir solo importan para estado COMPLETADO. [fix doble-conteo] las ventas cobradas vía cobro
      -- aportan 0 acá (su plata es el INGRESO/INGRESO_VIRTUAL, contado en entradas).
      case
        when vt.estado <> 'COMPLETADO' then 0
        when vt.id_venta in (select id_venta from cobradas) then 0
        when upper(vt.forma_pago) = 'EFECTIVO' then vt.total
        when upper(vt.forma_pago) like 'MIXTO%' then
          coalesce((substring(vt.forma_pago from 'EFE:([0-9.]+)'))::numeric, 0)
        else 0
      end                                                   as efe,
      case
        when vt.estado <> 'COMPLETADO' then 0
        when vt.id_venta in (select id_venta from cobradas) then 0
        when upper(vt.forma_pago) = 'EFECTIVO' then 0
        when upper(vt.forma_pago) like 'MIXTO%' then
          coalesce(
            (substring(vt.forma_pago from 'VIR:([0-9.]+)'))::numeric,
            vt.total - coalesce((substring(vt.forma_pago from 'EFE:([0-9.]+)'))::numeric, 0)
          )
        else vt.total
      end                                                   as vir
    from ventas vt
    left join cajas_map cm on cm.id_caja = vt.id_caja
  ),
  -- agregados por caja (solo de ventas con id_caja != '')
  vpc as (
    select id_caja,
      round(sum(case when estado='COMPLETADO' then total else 0 end), 2) as total,
      sum(case when estado in ('COMPLETADO','POR_COBRAR') then 1 else 0 end) as tickets,
      round(sum(efe), 2)                                                  as efectivo,
      round(sum(vir), 2)                                                  as otros,
      sum(case when estado='ANULADO'     then 1 else 0 end)               as anulados,
      sum(case when estado='POR_COBRAR'  then 1 else 0 end)               as sin_cobrar
    from ventas_calc
    where id_caja <> ''
    group by id_caja
  ),
  -- byMetodo: {forma_pago: Σtotal} solo COMPLETADO
  vpc_metodo as (
    select id_caja, jsonb_object_agg(forma_pago, t) as by_metodo
    from (
      select id_caja, forma_pago, round(sum(total),2) as t
      from ventas_calc where id_caja <> '' and estado='COMPLETADO'
      group by id_caja, forma_pago
    ) m group by id_caja
  ),
  -- byDoc: {tipo_doc: Σtotal} solo COMPLETADO
  vpc_doc as (
    select id_caja, jsonb_object_agg(tipo_doc, t) as by_doc
    from (
      select id_caja, tipo_doc, round(sum(total),2) as t
      from ventas_calc where id_caja <> '' and estado='COMPLETADO'
      group by id_caja, tipo_doc
    ) d group by id_caja
  ),
  -- ticket individual (objeto) + clave de orden (created_at, id_venta) para reproducir orden de hoja
  tk as (
    select vc.id_caja, vc.fecha, vc.hora, vc.created_at, vc.id_venta,
      jsonb_build_object(
        'idVenta',     coalesce(vc.id_venta,''),
        'fecha',       vc.fecha,
        'hora',        vc.hora,
        'correlativo', coalesce(vc.correlativo,''),
        'clienteDoc',  coalesce(vc.cliente_doc,''),
        'clienteNom',  coalesce(vc.cliente_nombre,''),
        'total',       vc.total,
        'tipoDoc',     vc.tipo_doc,
        'tipo',        vc.tipo,
        'metodo',      vc.forma_pago,
        'estado',      vc.estado,
        'obs',         coalesce(vc.obs,''),
        'idCaja',      vc.id_caja,
        -- [v2.43.388] vendedor del ticket = el REAL (me.ventas.vendedor); si el ticket no
        -- trae vendedor, cae al de la caja (cm_vendedor) para no quedar vacío.
        'vendedor',    coalesce(nullif(btrim(vc.vendedor),''), vc.cm_vendedor, ''),
        'zona',        vc.cm_zona,
        -- [877] Yape que verifica este ticket (null = sin verificar / no aplica)
        'yape',        (select jsonb_build_object('pagador', coalesce(y.pagador,''), 'monto', y.monto,
                                                   'hora', to_char(y.ts_notificacion at time zone v_tz,'HH24:MI'))
                          from mos.yapes_entrantes y
                         where y.id_venta = vc.id_venta and y.estado = 'MATCHEADO' limit 1)
      ) as obj
    from ventas_calc vc
  ),
  -- ticketsList por caja: GAS hace push (orden hoja) y luego .reverse() → DESC por (created_at, id_venta).
  --   [GAP-2] created_at = proxy del orden de fila.
  tlist as (
    select id_caja,
      coalesce(jsonb_agg(obj order by created_at desc nulls last, id_venta desc), '[]'::jsonb) as tickets_list
    from tk where id_caja <> ''
    group by id_caja
  ),
  -- todosTickets: más reciente primero (por fecha+hora desc, como el sort GAS de string concatenado).
  todos as (
    select coalesce(jsonb_agg(obj order by (fecha||hora) desc, id_venta desc), '[]'::jsonb) as arr
    from tk
  ),
  -- ════════════════════════════════════════════════════════════════════════════════════════════════════
  -- MOVIMIENTOS_EXTRA: entradas/salidas (reales) + listas por caja.
  -- ════════════════════════════════════════════════════════════════════════════════════════════════════
  ext_raw as (
    select coalesce(e.id_caja,'')        as id_caja,
           coalesce(e.tipo,'EGRESO')     as tipo,
           coalesce(e.monto,0)::numeric  as monto,
           coalesce(e.concepto,'')       as concepto,
           e.ts, e.id_extra, e.created_at
    from me.movimientos_extra e
    where coalesce(e.id_caja,'') <> ''
      and (not v_modo_hoy or e.id_caja = any(v_cajas_sel))   -- [1043] modo hoy: solo extras de las cajas del día
  ),
  epc as (
    select id_caja,
      sum(case when tipo='INGRESO' then monto else 0 end) as entradas,
      sum(case when tipo='EGRESO'  then monto else 0 end) as salidas
    from ext_raw group by id_caja
  ),
  elist as (
    select id_caja,
      coalesce(jsonb_agg(
        jsonb_build_object(
          'idExtra',  coalesce(id_extra,''),
          'tipo',     tipo,
          'monto',    monto,
          'concepto', concepto,
          'hora',     case when ts is not null then to_char(ts at time zone v_tz,'HH24:MI') else '' end
        ) order by created_at asc nulls last, id_extra asc
      ), '[]'::jsonb) as extras_list
    from ext_raw group by id_caja
  ),
  -- ════════════════════════════════════════════════════════════════════════════════════════════════════
  -- CAJAS (objeto por caja). Filtro de inclusión replicado del GAS.
  -- ════════════════════════════════════════════════════════════════════════════════════════════════════
  cajas_obj as (
    select
      c.id_caja,
      coalesce(c.estado,'')                                 as estado,
      c.fecha_apertura, c.fecha_cierre,
      coalesce(c.monto_inicial,0)::numeric                  as monto_inicial,
      coalesce(c.monto_final,0)::numeric                    as monto_final,
      coalesce(vpc.total,0)::numeric                        as v_total,
      coalesce(vpc.tickets,0)::int                          as v_tickets,
      coalesce(vpc.efectivo,0)::numeric                     as v_efectivo,
      coalesce(vpc.otros,0)::numeric                        as v_otros,
      coalesce(vpc.anulados,0)::int                         as v_anulados,
      coalesce(vpc.sin_cobrar,0)::int                       as v_sin_cobrar,
      coalesce(vm.by_metodo, '{}'::jsonb)                   as by_metodo,
      coalesce(vd.by_doc, '{}'::jsonb)                       as by_doc,
      coalesce(epc.entradas,0)::numeric                     as entradas,
      coalesce(epc.salidas,0)::numeric                      as salidas,
      coalesce(tl.tickets_list,'[]'::jsonb)                 as tickets_list,
      coalesce(el.extras_list,'[]'::jsonb)                  as extras_list,
      coalesce(c.vendedor,'')                               as vendedor,
      coalesce(c.estacion,'')                               as estacion,
      coalesce(c.zona_id,'')                                as zona
    from me.cajas c
    left join vpc        on vpc.id_caja = c.id_caja
    left join vpc_metodo vm on vm.id_caja = c.id_caja
    left join vpc_doc    vd on vd.id_caja = c.id_caja
    left join epc        on epc.id_caja = c.id_caja
    left join tlist      tl on tl.id_caja = c.id_caja
    left join elist      el on el.id_caja = c.id_caja
    -- filtro de inclusión: salta CERRADA con cierre < limite, y CERRADA sin cierre.
    where not (coalesce(c.estado,'')='CERRADA' and (c.fecha_cierre is null or c.fecha_cierre < v_limite))
      and (not v_modo_hoy or c.id_caja = any(v_cajas_sel))   -- [1043] modo hoy: solo cajas del día
  ),
  cajas_full as (
    select
      co.*,
      round(co.monto_inicial + co.v_efectivo + co.entradas - co.salidas, 2) as efectivo_esperado,
      case when co.estado='CERRADA'
           then round(co.monto_final - (co.monto_inicial + co.v_efectivo + co.entradas - co.salidas), 2)
           else null end                                                    as diferencia,
      case when co.fecha_apertura is not null
           then to_char(co.fecha_apertura at time zone v_tz,'YYYY-MM-DD HH24:MI') else '' end as f_apert,
      case when co.fecha_cierre is not null
           then to_char(co.fecha_cierre   at time zone v_tz,'YYYY-MM-DD HH24:MI') else '' end as f_cierr
    from cajas_obj co
  ),
  cajas_json as (
    select cf.*,
      jsonb_build_object(
        'idCaja',           cf.id_caja,
        'vendedor',         cf.vendedor,
        'estacion',         cf.estacion,
        'zona',             cf.zona,
        'estado',           cf.estado,
        'fechaApertura',    cf.f_apert,
        'fechaCierre',      cf.f_cierr,
        'montoInicial',     cf.monto_inicial,
        'montoFinal',       cf.monto_final,
        'totalVentas',      round(cf.v_total,2),
        'tickets',          cf.v_tickets,
        'efectivo',         round(cf.v_efectivo,2),
        'otros',            round(cf.v_otros,2),
        'anulados',         cf.v_anulados,
        'sinCobrar',        cf.v_sin_cobrar,
        'byMetodo',         cf.by_metodo,
        'byDoc',            cf.by_doc,
        'entradas',         cf.entradas,
        'salidas',          cf.salidas,
        'efectivoEsperado', cf.efectivo_esperado,
        'diferencia',       cf.diferencia,
        'ticketsList',      cf.tickets_list,
        'extrasList',       cf.extras_list,
        'urlReporte',       case when v_me_url <> ''
                                 then v_me_url || '?accion=ver_cierre&id_caja=' || mos._urlenc(cf.id_caja)
                                 else '' end
      ) as obj
    from cajas_full cf
  )
  -- ── ensamble final ──────────────────────────────────────────────────────────────────────────────────
  select
    -- abiertas: estado='ABIERTA' (orden: tal como salen; GAS las apila en orden de fila → created_at no
    --           es relevante para abiertas en el GAS, se dejan en orden de id_caja estable).
    coalesce((select jsonb_agg(obj order by id_caja)
                from cajas_json where estado='ABIERTA'), '[]'::jsonb),
    -- cerradas: el resto. GAS hace cerradas.reverse() tras apilar en orden de fila → DESC por apertura.
    --   [GAP-2] proxy de orden de fila = fecha_apertura desc (cierre/creación equivalente cronológico).
    coalesce((select jsonb_agg(obj order by fecha_apertura desc nulls last, id_caja desc)
                from cajas_json where estado<>'ABIERTA'), '[]'::jsonb),
    (select arr from todos)
  into v_abiertas, v_cerradas, v_todos;

  -- ── kpisTickets (mes = todos los del 30d; hoy = fecha==hoy) ──────────────────────────────────────────
  -- [1043] Misma regla y mismo resultado que antes, pero barato: el subquery se aplanaba y cada uno de los 10
  -- count(*) filter re-evaluaba upper()/to_char(at time zone) por fila (~170 ms de los ~200 ms del modo hoy).
  -- Ahora cada fila calcula UNA vez 3 columnas simples (offset 0 = barrera de aplanado):
  --   · anulado: prefix-match ANULADO% (= estado 'ANULADO'; CREDITO/POR_COBRAR/COMPLETADO cuentan como no anulado)
  --   · es_hoy : rango [00:00, 24:00) Lima de hoy (= to_char(fecha at tz)=hoy; fecha NULL → null → no cuenta)
  select jsonb_build_object(
    'hoy', jsonb_build_object(
      'total',    count(*) filter (where es_hoy and not anulado),
      'NV',       count(*) filter (where es_hoy and not anulado and tipo='NV'),
      'B',        count(*) filter (where es_hoy and not anulado and tipo='B'),
      'F',        count(*) filter (where es_hoy and not anulado and tipo='F'),
      'anulados', count(*) filter (where es_hoy and anulado)
    ),
    'mes', jsonb_build_object(
      'total',    count(*) filter (where not anulado),
      'NV',       count(*) filter (where not anulado and tipo='NV'),
      'B',        count(*) filter (where not anulado and tipo='B'),
      'F',        count(*) filter (where not anulado and tipo='F'),
      'anulados', count(*) filter (where anulado)
    )
  ) into v_kt
  from (
    -- recomputar ventana 30d + estado/tipo/fecha (mismas reglas que arriba), independiente de id_caja.
    select
      -- [500x] prefix-match ANULADO% igual que el cuerpo principal y 311/312, para que kpisTickets no
      -- discrepe (un ANULADO_CONVERSION caería en COMPLETADO y se contaría en el total).
      upper(coalesce(v.forma_pago,'EFECTIVO')) like 'ANULADO%'                    as anulado,
      case upper(coalesce(v.tipo_doc,'NOTA_DE_VENTA'))
        when 'BOLETA' then 'B' when 'FACTURA' then 'F' else 'NV' end            as tipo,
      (v.fecha >= v_ini_hoy and v.fecha < v_fin_hoy)                             as es_hoy
    from me.ventas v
    where v.fecha is null or v.fecha >= v_limite
    offset 0
  ) ktv;

  -- ── kpis (solo HOY): cajasHoy = abiertas ∪ cerradas con apertura O cierre que EMPIEZA con hoy ─────────
  -- Operamos sobre los objetos ya construidos (v_abiertas / v_cerradas) para paridad EXACTA con el GAS,
  -- que reduce sobre los mismos objetos de caja (totalVentas/tickets/anulados/sinCobrar ya redondeados).
  with caja_elem as (
    select e as obj, true as es_abierta from jsonb_array_elements(v_abiertas) e
    union all
    select e as obj, false from jsonb_array_elements(v_cerradas) e
  ),
  caja_hoy as (
    select obj from caja_elem
    where es_abierta
       or left(coalesce(obj->>'fechaApertura',''), 10) = to_char(v_hoy,'YYYY-MM-DD')
       or left(coalesce(obj->>'fechaCierre','') , 10) = to_char(v_hoy,'YYYY-MM-DD')
  )
  select jsonb_build_object(
    'cajasAbiertas', jsonb_array_length(v_abiertas),
    -- [1043] en modo hoy v_cerradas trae solo las del día → se usa el conteo 30d precalculado (mismo número).
    'cajasCerradas', case when v_modo_hoy then v_n_cerr else jsonb_array_length(v_cerradas) end,
    'totalDia',      round(coalesce(sum((obj->>'totalVentas')::numeric),0), 2),
    'ticketsDia',    coalesce(sum((obj->>'tickets')::int), 0),
    'anuladosDia',   coalesce(sum((obj->>'anulados')::int), 0),
    'sinCobrarDia',  coalesce(sum((obj->>'sinCobrar')::int), 0)
  ) into v_kpis
  from caja_hoy;

  v_out := jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'kpis',         v_kpis,
      'kpisTickets',  v_kt,
      'abiertas',     v_abiertas,
      'cerradas',     v_cerradas,
      'todosTickets', v_todos,
      'generadoEn',   to_char(now() at time zone v_tz, 'YYYY-MM-DD HH24:MI:SS')
    )
    -- [1043] marca de ventana parcial: el cliente FUSIONA (no reemplaza) cuando la ve. Modo completo: sin clave.
    || case when v_modo_hoy then jsonb_build_object('ventana', 'hoy') else '{}'::jsonb end
  -- [fix GAP-4] me.cajas/me.ventas/me.movimientos_extra son tablas VIVAS (ME_ESCRITURA_DIRECTA/APERTURA/
  -- CIERRE/COBRO_DIRECTO=1, ME escribe todo directo). _frescura_sombra() medía el heartbeat MUERTO del sync
  -- GAS → _fresh:false intermitente → toda la vista de Cajas caía a GAS stale (lags, "se cruza", cobros
  -- directos invisibles). _fresh:true SIEMPRE: la lectura directa de las tablas vivas manda.
  ) || jsonb_build_object('_fresh', true);

  return v_out;
end;
$function$
;
commit;

-- ROLLBACK: ejecutar supabase/live_mos_cierres_caja_pre1043.sql (definición viva previa, create or replace).
