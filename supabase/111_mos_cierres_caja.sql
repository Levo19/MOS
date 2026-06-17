-- ============================================================
-- 111_mos_cierres_caja.sql — [MIGRACIÓN MOS · FASE 2 · DINERO/CAJA · INERTE]
-- Porta CROSS-APP la función GAS gas/Cajas.gs::getCierresCaja (línea 23) a una RPC Supabase.
--
-- getCierresCaja lee DIRECTO el SS de MosExpress (vía ME_SS_ID) las hojas:
--   CAJAS · VENTAS_CABECERA · MOVIMIENTOS_EXTRA
-- Esas hojas YA están migradas a Supabase como me.cajas / me.ventas / me.movimientos_extra
-- (ver 02_schema_me.sql). Esta RPC es SECURITY DEFINER → puede leer cross-schema me.* sin grants
-- directos a authenticated (RLS de me.* la bypassa el definer = postgres/owner).
--
-- ⚠️ INERTE por diseño (igual que 93/108/110): gate mos._claim_ok() + grant authenticated/service_role,
--   pero NADIE la llama todavía. MOS sigue 100% por GAS. Este archivo NO toca flags ni cablea js/api.js.
--
-- ── SHAPE EXACTO (paridad 1:1 con getCierresCaja, leído entero) ──────────────────────────────────────
--   return { ok:true, data:{ kpis, kpisTickets, abiertas:[caja...], cerradas:[caja...], todosTickets:[tk...],
--                            generadoEn } } || _frescura_sombra()  →  + _fresh/_heartbeat/_now/_ttl_min
--
--   caja = { idCaja, vendedor, estacion, zona, estado, fechaApertura, fechaCierre, montoInicial, montoFinal,
--            totalVentas, tickets, efectivo, otros, anulados, sinCobrar, byMetodo{metodo:total},
--            byDoc{tipoDoc:total}, entradas, salidas, efectivoEsperado, diferencia(null si ABIERTA),
--            ticketsList:[tk...] (orden inverso al de inserción), extrasList:[ex...], urlReporte }
--
--   tk   = { idVenta, fecha(YYYY-MM-DD), hora(HH:mm), correlativo, clienteDoc, clienteNom, total, tipoDoc,
--            tipo(NV|B|F), metodo, estado(COMPLETADO|ANULADO|POR_COBRAR|CREDITO), obs, idCaja, vendedor, zona }
--
--   ex   = { idExtra, tipo, monto, concepto, hora(HH:mm) }
--
--   kpis = { cajasAbiertas, cajasCerradas, totalDia, ticketsDia, anuladosDia, sinCobrarDia }   (solo HOY Lima)
--   kpisTickets = { hoy:{total,NV,B,F,anulados}, mes:{total,NV,B,F,anulados} }                  (mes = ventana 30d)
--
-- ── REGLAS REPLICADAS (1:1 contra el GAS) ────────────────────────────────────────────────────────────
--   · TZ: Session.getScriptTimeZone() del GAS = America/Lima. fecha/hora/agrupación → AT TIME ZONE 'America/Lima'.
--   · hoy   = (now() at tz Lima)::date.   limite = now() - 30 días (timestamptz, comparación contra fecha cruda).
--   · ESTADO derivado de FormaPago (forma_pago), NO de estado_envio (regla en piedra del ecosistema MOS):
--       'ANULADO'|'CREDITO' → ese mismo valor ; 'POR_COBRAR' → 'POR_COBRAR' ; resto → 'COMPLETADO'.
--   · metodo = forma_pago crudo (para byMetodo y tk.metodo).
--   · Acumulados por caja (solo de ventas COBRADAS = no ANULADO/no POR_COBRAR):
--       total += total ; tickets++ ;
--       EFECTIVO → efectivo += total ;
--       MIXTO*   → parsea "EFE:x" / "VIR:y" (regex i); efectivo += efe ; otros += (vir || total-efe) ;
--       resto    → otros += total ;
--       byMetodo[metodo] += total ; byDoc[tipoDoc] += total.
--       ANULADO → anulados++ (NO suma) ; POR_COBRAR → sinCobrar++ y tickets++ (NO suma a total/efectivo/otros).
--   · Ventana 30d en ventas: el GAS hace `if (fRaw instanceof Date && fRaw < limite) continue` → solo descarta
--     filas con FECHA Date y < limite. Filas sin fecha parseable PASAN. Aquí fecha es timestamptz: descartamos
--     v.fecha < limite SOLO cuando v.fecha is not null (NULL pasa, = paridad: una fecha no-Date no se descartaba).
--   · tipo corto (_tipoCorto): BOLETA→B, FACTURA→F, resto→NV (NOTA_DE_VENTA u otros).
--   · cajaMap (vendedor/zona del ticket): vendedor = me.cajas.vendedor ; zona = zona_id || estacion (GAS:
--       row[8] || row[2]). En la hoja col8=zona, col2=estacion → aquí zona_id || estacion.
--   · todosTickets: orden MÁS RECIENTE primero (por fecha+hora desc).
--   · ticketsList por caja: push en orden de escaneo, luego .slice().reverse() → orden inverso al de inserción.
--       Como el escaneo GAS recorre la hoja en orden de fila (no garantizado por fecha), aquí lo replicamos
--       ordenando por created_at de la fila (proxy del orden de inserción en la hoja) y luego invirtiendo.
--   · extrasList por caja: orden de escaneo (created_at asc), sin reverse.
--   · CAJAS incluidas: se SALTA si (estado='CERRADA' AND fecha_cierre < limite) o (estado='CERRADA' AND
--       fecha_cierre IS NULL). ABIERTA siempre entra. CERRADA con cierre >= limite entra.
--   · efectivoEsperado = montoInicial + efectivo(cobrado) + entradas - salidas   (entradas/salidas = INGRESO/EGRESO
--       reales; los _VIRTUAL NO entran en este cálculo, igual que el GAS que solo lee ext.entradas/ext.salidas).
--   · diferencia = CERRADA ? round(montoFinal - efectivoEsperado, 2) : null.
--   · obj.estacion = me.cajas.estacion (col2) ; obj.zona = me.cajas.zona_id (col8).
--   · abiertas: estado='ABIERTA'. cerradas: el resto (incl. CERRADA_AUTO). cerradas.reverse() al final.
--   · kpis (solo HOY): cajasHoy = abiertas ∪ cerradas-cuyo-apertura-O-cierre-empieza-con-hoy.
--       totalDia=Σ totalVentas ; ticketsDia=Σ tickets ; anuladosDia=Σ anulados ; sinCobrarDia=Σ sinCobrar.
--   · kpisTickets: por cada ticket NO descartado por 30d → mes siempre cuenta; hoy cuenta si fecha==hoy.
--       anulado → bucket .anulados++ ; si no → .total++ y .[tipo]++ (NV/B/F).
--   · generadoEn = now() en Lima 'YYYY-MM-DD HH24:MI:SS'.
--
-- ── GAPS / DIVERGENCIAS HONESTAS (es DINERO/CAJA — marcadas explícitas) ───────────────────────────────
--   [GAP-1] urlReporte: el GAS la arma con _getProp('ME_GAS_URL') (Script Property de GAS, NO migrada a
--           mos.config). Aquí se lee mos.config['ME_GAS_URL'] con fallback '' → si no se siembra esa clave,
--           urlReporte = '' (paridad con el GAS cuando ME_GAS_URL no está configurado). Para paridad TOTAL
--           hay que sembrar mos.config('ME_GAS_URL', <url del deployment ME>). NO se siembra aquí.
--   [GAP-2] Orden de ticketsList / extrasList: el GAS depende del ORDEN FÍSICO de filas en la hoja (orden de
--           inserción). En Supabase no hay "orden de fila"; se usa created_at como proxy. Para filas backfilled
--           con created_at idéntico (mismo batch) el desempate cae a id (id_venta/id_extra) — orden ESTABLE pero
--           NO necesariamente idéntico al de la hoja histórica. Funcionalmente equivalente (mismo conjunto,
--           orden cronológico). Riesgo de paridad BAJO (es presentación, no monto).
--   [GAP-3] me.ventas.fecha es timestamptz NOT NULL-able pero puede ser NULL. El GAS, ante fecha no-Date,
--           usaba String(fRaw).substring(0,10) para `fecha` y hora=''. Aquí, fecha NULL → fecha='' , hora=''
--           (no hay string crudo que cortar). Ventas con fecha NULL son borde; en datos reales fecha siempre existe.
--   [GAP-4] La señal _fresh es la frescura de la SOMBRA MOS (MOS_SYNC_HEARTBEAT). PERO esta RPC lee me.* (ME),
--           cuyo sync es INDEPENDIENTE del de MOS. _frescura_sombra() NO mide la frescura de la sombra de ME.
--           Se incluye igual porque el requisito lo pide y porque el FRONT usa _fresh como gate de cutover MOS.
--           ⚠️ Si la sombra de ME se congela, _fresh puede seguir =true (mide MOS) → el front no caería a GAS por
--           datos ME viejos. Para un gate real de ME haría falta un heartbeat de ME (no existe hoy). Documentado.
--
-- ── SEGURIDAD ─────────────────────────────────────────────────────────────────────────────────────────
--   security definer + search_path='' (todo schema-qualified) + gate mos._claim_ok() (claim app='MOS' o
--   service_role/GAS) + revoke public + grant service_role,authenticated. No expone PII fuera de lo que
--   getCierresCaja ya devolvía (cliente_doc/cliente_nombre van en el ticket, igual que el GAS).
-- ============================================================

create schema if not exists mos;

-- helper de URL-encode mínimo (encodeURIComponent del GAS para el id_caja en urlReporte).
-- Definido ANTES de cierres_caja porque check_function_bodies (on en Supabase) valida el cuerpo
-- de cierres_caja al crearla y allí se referencia mos._urlenc(...).
create or replace function mos._urlenc(p text)
returns text
language sql
immutable
set search_path = ''
as $fn$
  -- encodeURIComponent: deja sin tocar los "unreserved" RFC3986 (A-Za-z0-9-_.~);
  -- el resto se percent-encodea byte a byte (UTF-8). Para ids ASCII seguros → identidad.
  select coalesce(string_agg(
    case when c ~ '^[A-Za-z0-9._~-]$' then c
         else (
           select string_agg('%' || upper(b.hx), '')
           from (
             select substring(h from i for 2) as hx
             from (select encode(convert_to(c,'UTF8'),'hex') as h) hh,
                  generate_series(1, length(hh.h), 2) as i
           ) b
         )
    end, ''
  ), '')
  from regexp_split_to_table(coalesce(p,''), '') as c;
$fn$;
revoke all on function mos._urlenc(text)   from public;
grant execute on function mos._urlenc(text) to service_role, authenticated;

create or replace function mos.cierres_caja(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
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
      v.created_at
    from me.ventas v
    -- ventana 30d: descarta SOLO si fecha presente y < limite (NULL pasa, = paridad GAS "instanceof Date").
    where v.fecha is null or v.fecha >= v_limite
  ),
  ventas as (
    select vr.*,
      -- estado derivado de forma_pago (regla en piedra)
      case
        when upper(vr.forma_pago) in ('ANULADO','CREDITO') then upper(vr.forma_pago)
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
  -- desglose efectivo/otros por venta cobrada (MIXTO parsea EFE:/VIR:)
  ventas_calc as (
    select vt.*,
      cm.vendedor as cm_vendedor,
      coalesce(cm.zona,'') as cm_zona,
      -- efe/vir solo importan para estado COMPLETADO
      case
        when vt.estado <> 'COMPLETADO' then 0
        when upper(vt.forma_pago) = 'EFECTIVO' then vt.total
        when upper(vt.forma_pago) like 'MIXTO%' then
          coalesce((substring(vt.forma_pago from 'EFE:([0-9.]+)'))::numeric, 0)
        else 0
      end                                                   as efe,
      case
        when vt.estado <> 'COMPLETADO' then 0
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
        'vendedor',    coalesce(vc.cm_vendedor,''),
        'zona',        vc.cm_zona
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
  select jsonb_build_object(
    'hoy', jsonb_build_object(
      'total',    count(*) filter (where fecha = to_char(v_hoy,'YYYY-MM-DD') and estado<>'ANULADO'),
      'NV',       count(*) filter (where fecha = to_char(v_hoy,'YYYY-MM-DD') and estado<>'ANULADO' and tipo='NV'),
      'B',        count(*) filter (where fecha = to_char(v_hoy,'YYYY-MM-DD') and estado<>'ANULADO' and tipo='B'),
      'F',        count(*) filter (where fecha = to_char(v_hoy,'YYYY-MM-DD') and estado<>'ANULADO' and tipo='F'),
      'anulados', count(*) filter (where fecha = to_char(v_hoy,'YYYY-MM-DD') and estado='ANULADO')
    ),
    'mes', jsonb_build_object(
      'total',    count(*) filter (where estado<>'ANULADO'),
      'NV',       count(*) filter (where estado<>'ANULADO' and tipo='NV'),
      'B',        count(*) filter (where estado<>'ANULADO' and tipo='B'),
      'F',        count(*) filter (where estado<>'ANULADO' and tipo='F'),
      'anulados', count(*) filter (where estado='ANULADO')
    )
  ) into v_kt
  from (
    -- recomputar ventana 30d + estado/tipo/fecha (mismas reglas que arriba), independiente de id_caja.
    select
      case
        when upper(coalesce(v.forma_pago,'EFECTIVO')) in ('ANULADO','CREDITO') then upper(v.forma_pago)
        when upper(coalesce(v.forma_pago,'EFECTIVO')) = 'POR_COBRAR'           then 'POR_COBRAR'
        else 'COMPLETADO'
      end as estado,
      case upper(coalesce(v.tipo_doc,'NOTA_DE_VENTA'))
        when 'BOLETA' then 'B' when 'FACTURA' then 'F' else 'NV' end as tipo,
      case when v.fecha is not null then to_char(v.fecha at time zone v_tz,'YYYY-MM-DD') else '' end as fecha
    from me.ventas v
    where v.fecha is null or v.fecha >= v_limite
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
    'cajasCerradas', jsonb_array_length(v_cerradas),
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
  ) || mos._frescura_sombra();   -- [GAP-4] frescura de la sombra MOS (no de ME); + _heartbeat/_now/_ttl_min/_fresh

  return v_out;
end;
$fn$;

revoke all on function mos.cierres_caja(jsonb)     from public;
grant execute on function mos.cierres_caja(jsonb)  to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTA _urlenc: el percent-encoding byte a byte de arriba es aproximado. Como los id_caja del ecosistema
-- son ASCII seguros ([A-Za-z0-9-] típicamente 'CAJA-AAAA...'), encodeURIComponent del GAS los devuelve TAL
-- CUAL. Para esos ids, _urlenc(id)=id → paridad exacta de urlReporte. Si algún id trajera caracteres raros,
-- el escape es best-effort. [GAP-1] sigue siendo el factor dominante (ME_GAS_URL casi siempre '').
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
