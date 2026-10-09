-- 1037 · ME: tickets que llegan TARDE + red de seguridad de la cola offline   (2026-10-08)
--
-- Incidente 07-oct: caída Supabase 16:32→17:59 Lima. La PC de Estación 02 (Liliana, ZONA-01) emitió 5 NV offline
-- (S/ 28) y se apagó antes de reconectar. El 08-oct 07:09 la cola subió; la caja original (Josué, 07-oct) estaba
-- CERRADA → el rescate 1007 los metió POR_COBRAR en la caja de HOY → el cierre de hoy los ANULÓ.
--
-- Decisión del dueño (08-oct): el ticket de un día anterior queda en SU caja y SU día, con su correlativo,
-- APARTE del cuadre ya cerrado (POR_COBRAR: estado_cajas/datos_turno ya excluyen POR_COBRAR del efectivo) hasta
-- confirmar si se cobró; el STOCK se descuenta al llegar (por ticket, idempotente).
--
--  1. crear_venta_directa / crear_cpe_directo (partidos de pg_get_functiondef VIVO 08-oct):
--     · p.fecha_local = hora de emisión del equipo (validada: no futura >2 min, no >7 días).
--     · TARDÍO: rescate con caja original de un DÍA ANTERIOR y emisión (si se conoce) también anterior → queda en
--       la caja original, fecha acotada a [apertura, cierre], forma_pago POR_COBRAR, obs '⏰TARDÍO…'.
--     · Camino normal y rescate del mismo día: IDÉNTICOS (QA verificó el diff).
--  2. mos.ventas_tardias (log) + mos._venta_tardia_registrar (log, descuento de stock si TARDIO, push MASTER
--     con anti-spam 10 min por equipo) + mos._venta_tardia_descontar (kardex por ticket, ref VENTA-TARDIA:<id>:<cod>).
--  3. me.cola_reportar + cron me-cola-vigilar (push si un equipo con tickets sin subir deja de reportar >10 min
--     o lleva >30 min atascado).
--  4. Corrección de los 5 tickets NVM1-017171..175.
-- Nota CPE: la Edge emitir-cpe arma fecha_de_emision con la fecha de HOY (no lee me.ventas.fecha). Una boleta
-- tardía queda con el día original en caja/reportes y el de llegada en SUNAT (legal para boleta). Pendiente alinear.
-- Nota anulación: si luego se ANULA un tardío (no se cobró), su stock NO se devuelve solo (ver mos.ventas_tardias.stock).
begin;

create table if not exists mos.ventas_tardias (
  id_venta       text primary key,
  ref_local      text,
  correlativo    text,
  dispositivo_id text,
  equipo         text,
  vendedor       text,
  zona_id        text,
  id_caja        text,
  caja_original  text,
  tipo           text not null,          -- TARDIO (caja de día anterior) | RESCATE (caja cerrada, mismo día) | DEMORA (>5 min tarde)
  total          numeric,
  forma_pago     text,
  fecha_local    timestamptz,            -- hora de emisión según el equipo (null = desconocida)
  llego_ts       timestamptz not null default now(),
  stock          jsonb,                  -- resultado del descuento (solo TARDIO)
  nota           text
);
create index if not exists ix_ventas_tardias_llego on mos.ventas_tardias (llego_ts desc);
alter table mos.ventas_tardias enable row level security;   -- sin policies: solo funciones definer / service_role

-- Descuento de stock de UN ticket tardío (su caja ya cerró → el descuento por caja no lo cubre).
-- Idempotente por refId VENTA-TARDIA:<id_venta>:<cod>. Si hubo un conteo del producto en la zona DESPUÉS de la
-- venta, el número contado ya la refleja → no se descuenta (mismo criterio que el reconciliador F2).
create or replace function mos._venta_tardia_descontar(p_id text)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare
  v me.ventas%rowtype;
  r record; v_k jsonb; v_adj timestamptz; v_prev text;
  v_out jsonb := '[]'::jsonb; v_zona text;
begin
  select * into v from me.ventas where id_venta = p_id;
  if not found then return jsonb_build_object('ok',false,'error','VENTA_NO_ENCONTRADA'); end if;
  if upper(coalesce(v.forma_pago,'')) like 'ANULADO%' then return jsonb_build_object('ok',true,'omitido','ANULADO'); end if;
  v_zona := upper(btrim(coalesce(v.zona_id,'')));
  if v_zona = '' then return jsonb_build_object('ok',false,'error','SIN_ZONA'); end if;
  v_prev := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', jsonb_build_object('app','MOS','role','authenticated')::text, true);
  for r in
    select cv.canon_cod as cb, sum(cv.cant) as cant
      from me.ventas_detalle vd
      cross join lateral mos._venta_canonico(vd.cod_barras, vd.cantidad::numeric, vd.unidad_medida) cv
     where vd.id_venta = p_id and coalesce(nullif(btrim(cv.canon_cod),''),'') <> '' and cv.cant > 0
     group by cv.canon_cod
  loop
    select max(ts) into v_adj from me.zona_ajuste_log where upper(btrim(zona_id)) = v_zona and btrim(cod_barras) = r.cb;
    if v_adj is not null and v_adj > v.fecha then
      v_out := v_out || jsonb_build_object('codBarra', r.cb, 'cantidad', r.cant, 'aplicado', false, 'motivo', 'conteo posterior');
      continue;
    end if;
    v_k := me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', r.cb, 'tipo', 'SALIDA_VENTA', 'delta', (-r.cant),
      'refTipo', 'VENTA', 'refId', 'VENTA-TARDIA:'||p_id||':'||r.cb, 'usuario', coalesce(v.vendedor,''), 'origen', 'TARDIO'));
    if coalesce((v_k->>'ok')::boolean, true) and not coalesce((v_k->>'dedup')::boolean, false) then
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (r.cb, v_zona, -r.cant, coalesce(v.vendedor,''), now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) - r.cant, usuario = excluded.usuario, fecha_ultimo_registro = now();
    end if;
    v_out := v_out || jsonb_build_object('codBarra', r.cb, 'cantidad', r.cant, 'kardex', v_k);
  end loop;
  perform set_config('request.jwt.claims', coalesce(v_prev,''), true);
  return jsonb_build_object('ok', true, 'detalle', v_out);
end $f$;
revoke all on function mos._venta_tardia_descontar(text) from public, anon, authenticated;

create or replace function mos._venta_tardia_registrar(p_id text, p_fl timestamptz, p_tardio boolean, p_resc boolean, p_caja_orig text)
returns void language plpgsql security definer set search_path to '' as $f$
declare
  v me.ventas%rowtype; v_eq text; v_reciente boolean; v_stock jsonb;
  v_tipo text := case when p_tardio then 'TARDIO' when p_resc then 'RESCATE' else 'DEMORA' end;
begin
  select * into v from me.ventas where id_venta = p_id;
  if not found then return; end if;
  select nombre_equipo into v_eq from mos.dispositivos where id_dispositivo = v.dispositivo_id limit 1;
  select exists (select 1 from mos.ventas_tardias t where t.dispositivo_id = v.dispositivo_id
                  and t.tipo in ('TARDIO','RESCATE') and t.llego_ts > now() - interval '10 minutes') into v_reciente;
  if v_tipo = 'TARDIO' then
    begin v_stock := mos._venta_tardia_descontar(p_id);
    exception when others then v_stock := jsonb_build_object('ok',false,'error',sqlerrm); end;
  end if;
  insert into mos.ventas_tardias (id_venta, ref_local, correlativo, dispositivo_id, equipo, vendedor, zona_id, id_caja,
                                  caja_original, tipo, total, forma_pago, fecha_local, stock)
  values (v.id_venta, v.ref_local, v.correlativo, v.dispositivo_id, v_eq, v.vendedor, v.zona_id, v.id_caja,
          p_caja_orig, v_tipo, v.total, v.forma_pago, p_fl, v_stock)
  on conflict (id_venta) do nothing;
  if v_tipo in ('TARDIO','RESCATE') and not v_reciente then
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
        'titulo', '⏰ Tickets que llegaron tarde',
        'cuerpo', coalesce(v_eq,'Un equipo') || ' (' || coalesce(nullif(v.vendedor,''),'?') || ' · ' || coalesce(nullif(v.zona_id,''),'?')
                  || ') subió tickets emitidos sin conexión con la caja ya cerrada'
                  || case when v_tipo = 'TARDIO' then '. Quedaron en su día original como POR_COBRAR: confirma con el cajero si se cobraron.'
                          else '. Entraron POR_COBRAR a la caja abierta.' end,
        'data', jsonb_build_object('tipo','ventas_tardias','equipo',coalesce(v_eq,''))));
    exception when others then raise warning '[1037] push tardío: %', sqlerrm;
    end;
  end if;
end $f$;
revoke all on function mos._venta_tardia_registrar(text, timestamptz, boolean, boolean, text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION me.crear_venta_directa(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_chk1029 jsonb;
  v_app   text := me.jwt_app();
  v_sub   text := me.jwt_sub();
  v_ref   text := nullif(btrim(coalesce(p->>'ref_local','')), '');
  v_serie text := nullif(btrim(coalesce(p->>'serie','')), '');
  v_tipo  text := upper(coalesce(p->>'tipo_doc',''));
  v_caja  text := coalesce(p->>'id_caja','');
  v_caja_ok boolean;
  v_zona  text;
  v_est   text := nullif(btrim(coalesce(p->>'estacion','')), '');   -- [MED16 500x-2]
  v_serie_sd text;                                                  -- [MED16 500x-2]
  v_total numeric := coalesce((p->>'total')::numeric, 0);
  v_suma  numeric;
  v_nit   int;
  v_ex    me.ventas%rowtype;
  v_num   bigint;
  v_corr  text;
  v_id    text;
  v_item  jsonb;
  v_linea int := 0;
  v_ins   int;
  v_resc  boolean := false;                                         -- [1007]
  v_caja_orig text;                                                 -- [1007]
  v_fl        timestamptz;                                          -- [1037] hora real de emisión (reloj del equipo)
  v_tardio    boolean := false;                                     -- [1037] caja original de un DÍA ANTERIOR
  v_cierre    timestamptz;                                          -- [1037]
  v_apert     timestamptz;                                          -- [QA 1037]
  v_fecha     timestamptz := now();                                 -- [1037]
begin
  -- [1037] fecha_local = hora en que el equipo EMITIÓ el ticket (cola offline la conserva). Solo se acepta
  -- si es razonable: no futura (>2 min) ni de hace más de 7 días.
  begin
    v_fl := nullif(btrim(coalesce(p->>'fecha_local','')),'')::timestamptz;
  exception when others then v_fl := null; end;
  if v_fl is not null and (v_fl > now() + interval '2 minutes' or v_fl < now() - interval '7 days') then v_fl := null; end if;
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if v_ref   is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  if v_tipo not in ('NOTA_DE_VENTA','NV','') then return jsonb_build_object('status','error','error','SOLO_NV_DIRECTO'); end if;

  -- idempotencia PRIMERO (reintento → misma venta, sin re-validar)
  select * into v_ex from me.ventas where ref_local = v_ref limit 1;
  if found then
    return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo);
  end if;

  -- [1029 R1/R3] crédito a personal fijo de WH: solo con sesión WH hoy y día no liquidado
  if upper(coalesce(p->>'forma_pago','')) = 'CREDITO' then
    v_chk1029 := mos._credito_personal_check(p->>'cliente_doc', null);
    if not coalesce((v_chk1029->>'ok')::boolean, true) then
      return jsonb_build_object('status','error','error',v_chk1029->>'error','mensaje',v_chk1029->>'mensaje');
    end if;
  end if;

  -- total == Σ(items.subtotal)
  select coalesce(sum((it->>'subtotal')::numeric), 0), count(*)
    into v_suma, v_nit
  from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it;
  if v_nit > 0 and abs(v_total - v_suma) > 0.01 then
    return jsonb_build_object('status','error','error','TOTAL_NO_CUADRA',
                              'detalle', 'total='||v_total||' suma_items='||v_suma);
  end if;
  -- [500x-2b] sin items NO se mintea correlativo (un comprobante sin líneas no es auditable)
  if v_nit = 0 then return jsonb_build_object('status','error','error','SIN_ITEMS'); end if;

  -- caja ABIERTA + zona de la caja
  select (estado = 'ABIERTA'), zona_id into v_caja_ok, v_zona
  from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then
    -- [1007 RESCATE] ticket cobrado del replay de la cola: derivarlo a la caja ABIERTA de la zona.
    if coalesce(p->>'rescate','') = '1' then
      v_caja_orig := v_caja;
      -- [1037 TARDÍO] Si la caja original es de un DÍA ANTERIOR, el ticket se queda en SU caja/día (con su
      -- correlativo normal) en vez de entrar POR_COBRAR a la caja de hoy (donde el cierre lo anulaba).
      -- [QA 1037] tardío solo si la hora de emisión (si se conoce) también es de un día anterior; la fecha
      -- se acota a la vida de la caja (apertura..cierre) para que un reloj mal puesto no la saque de su día.
      select c.fecha_cierre, c.fecha_apertura into v_cierre, v_apert from me.cajas c
       where c.id_caja = v_caja_orig
         and (c.fecha_apertura at time zone 'America/Lima')::date < (now() at time zone 'America/Lima')::date
       limit 1;
      if found and (v_fl is null or (v_fl at time zone 'America/Lima')::date < (now() at time zone 'America/Lima')::date) then
        v_tardio := true;
        v_fecha  := least(greatest(coalesce(v_fl, v_cierre, v_apert), v_apert), coalesce(v_cierre, now()));
      end if;
      if v_zona is null or btrim(v_zona) = '' then v_zona := nullif(btrim(coalesce(p->>'zona','')),''); end if;
      if (v_zona is null or btrim(v_zona) = '') and v_est is not null then
        select nullif(btrim(coalesce(id_zona,'')),'') into v_zona from mos.series_documentales
         where activo and id_estacion = v_est limit 1;
      end if;
      if not v_tardio and v_zona is not null and btrim(v_zona) <> '' then
        select c.id_caja into v_caja from me.cajas c
         where upper(coalesce(c.estado,'')) = 'ABIERTA' and c.zona_id = btrim(v_zona)
           and (c.fecha_apertura at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
         order by c.fecha_apertura desc nulls last limit 1;
        if v_caja is not null and v_caja <> v_caja_orig then v_resc := true; end if;
      end if;
    end if;
    if not v_resc and not v_tardio then
      return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA');
    end if;
  end if;

  -- [MED16 · 500x-2] SERIE NV autoritativa desde Supabase (mos.series_documentales): estación primero,
  -- luego zona. OJO: el front manda tipo_doc='NOTA_DE_VENTA' pero la tabla guarda 'NOTA_VENTA' → match IN.
  -- Si no hay fila, cae al serie del front (compat). Resiste el drift de la Hoja stale (SQL 269).
  -- [500x-2b] serie SOLO de la zona de la caja (la estación user-supplied no debe cruzar zonas);
  -- dentro de la zona, prefiere la fila de la estación enviada.
  select serie into v_serie_sd from mos.series_documentales
   where activo and upper(tipo_documento) in ('NOTA_VENTA','NOTA_DE_VENTA','NV')
     and ( v_zona is null or v_zona = '' or id_zona = v_zona )
   order by (v_est is not null and id_estacion = v_est) desc, id_serie asc
   limit 1;
  if v_serie_sd is not null and btrim(v_serie_sd) <> '' then v_serie := btrim(v_serie_sd); end if;
  if v_serie is null then return jsonb_build_object('status','error','error','SERIE_REQUERIDA'); end if;

  -- correlativo atómico (idempotente por ref_local)
  v_num  := me.siguiente_correlativo(v_serie, v_ref);
  v_corr := v_serie || '-' || lpad(v_num::text, 6, '0');
  v_id   := 'V-' || (floor(extract(epoch from clock_timestamp()) * 1000))::bigint::text
                 || '-' || substr(md5(random()::text || clock_timestamp()::text || v_ref), 1, 8);

  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
                         tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio,
                         ref_local, obs, tipo_doc_cliente, zona_id)
  values (v_id, v_fecha, p->>'vendedor', p->>'estacion', coalesce(p->>'cliente_doc',''), coalesce(p->>'cliente_nombre',''),
          v_total, coalesce(nullif(v_tipo,''),'NOTA_DE_VENTA'),
          case when v_resc or v_tardio then 'POR_COBRAR' else coalesce(p->>'forma_pago','EFECTIVO') end,   -- [1007] + [1037] tardío aparte del cuadre
          v_corr, v_caja,
          coalesce(nullif(v_sub,''), p->>'dispositivo_id', ''), 'COMPLETADO', v_ref,
          case when v_tardio then '⏰TARDÍO (emitido sin conexión'||coalesce(' a las '||to_char(v_fl at time zone 'America/Lima','DD/MM HH24:MI'),'')
                                ||'; llegó '||to_char(now() at time zone 'America/Lima','DD/MM HH24:MI')||' con la caja ya cerrada) · '||coalesce(p->>'obs','')
               when v_resc then '🛟RESCATE (caja original '||coalesce(v_caja_orig,'?')||' cerrada) · '||coalesce(p->>'obs','')
               else coalesce(p->>'obs','') end,                                                 -- [1007]
          coalesce((p->>'tipo_doc_cliente')::int, 0), coalesce(v_zona,''))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;
  get diagnostics v_ins = row_count;

  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_ref limit 1;
    if found then return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo); end if;
    return jsonb_build_object('status','error','error','INSERT_INCONSISTENTE');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_linea := v_linea + 1;
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
                                   cod_barras, valor_unitario, tipo_igv, unidad_medida,
                                   segmento_id, segmento_nombre, segmento_pct)
    values (v_id, v_linea, v_item->>'sku', v_item->>'nombre', coalesce((v_item->>'cantidad')::numeric,0),
            coalesce((v_item->>'precio')::numeric,0), coalesce((v_item->>'subtotal')::numeric,0),
            coalesce(v_item->>'cod_barras',''), coalesce((v_item->>'valor_unitario')::numeric,0),
            coalesce((v_item->>'tipo_igv')::int,1), coalesce(v_item->>'unidad_medida','NIU'),
            nullif(btrim(coalesce(v_item->>'segmento_id','')),''),
            nullif(btrim(coalesce(v_item->>'segmento_nombre','')),''),
            nullif(v_item->>'segmento_pct','')::numeric)
    on conflict (id_venta, linea) do nothing;
  end loop;

  -- [1037] Registro de llegadas tardías (para el informe y la alerta). Nunca rompe la venta.
  if v_tardio or v_resc or (v_fl is not null and now() - v_fl > interval '5 minutes') then
    begin
      perform mos._venta_tardia_registrar(v_id, v_fl, v_tardio, v_resc, v_caja_orig);
    exception when others then raise warning '[1037] venta tardía % no registrada: %', v_id, sqlerrm; end;
  end if;

  return jsonb_build_object('status','success','dedup',false,'id_venta',v_id,'correlativo',v_corr,'numero',v_num,
                            'rescatada', v_resc, 'tardio', v_tardio, 'idCaja', v_caja);                             -- [1007]
end;
$function$;

CREATE OR REPLACE FUNCTION me.crear_cpe_directo(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_chk1029 jsonb;
  v_app     text := me.jwt_app();
  v_sub     text := me.jwt_sub();
  v_ref     text := nullif(btrim(coalesce(p->>'ref_local','')), '');
  v_serie   text := nullif(btrim(coalesce(p->>'serie','')), '');
  v_tipo    text := upper(coalesce(p->>'tipo_doc',''));
  v_caja    text := coalesce(p->>'id_caja','');
  v_caja_ok boolean;
  v_zona    text;
  v_est     text := nullif(btrim(coalesce(p->>'estacion','')), '');
  v_serie_sd text;
  v_total   numeric := coalesce((p->>'total')::numeric, 0);
  v_suma    numeric;
  v_nit     int;
  v_ex      me.ventas%rowtype;
  v_num     bigint; v_corr text; v_id text; v_item jsonb; v_linea int := 0; v_ins int;
  v_resc    boolean := false;                                       -- [1007]
  v_caja_orig text;                                                 -- [1007]
  v_fl        timestamptz;                                          -- [1037] hora real de emisión (reloj del equipo)
  v_tardio    boolean := false;                                     -- [1037] caja original de un DÍA ANTERIOR
  v_cierre    timestamptz;                                          -- [1037]
  v_apert     timestamptz;                                          -- [QA 1037]
  v_fecha     timestamptz := now();                                 -- [1037]
begin
  -- [1037] fecha_local = hora en que el equipo EMITIÓ el ticket (cola offline la conserva). Solo se acepta
  -- si es razonable: no futura (>2 min) ni de hace más de 7 días.
  begin
    v_fl := nullif(btrim(coalesce(p->>'fecha_local','')),'')::timestamptz;
  exception when others then v_fl := null; end;
  if v_fl is not null and (v_fl > now() + interval '2 minutes' or v_fl < now() - interval '7 days') then v_fl := null; end if;
  if v_app  <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not me._cpe_directo_on() then return jsonb_build_object('status','error','error','CPE_DIRECTO_DESACTIVADO'); end if;
  if v_ref  is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('status','error','error','SOLO_CPE_DIRECTO'); end if;

  select * into v_ex from me.ventas where ref_local = v_ref limit 1;
  if found then
    return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo,
                              'nf_estado',coalesce(v_ex.nf_estado,''),'nf_hash',coalesce(v_ex.nf_hash,''),'nf_enlace',coalesce(v_ex.nf_enlace,''));
  end if;

  -- [1029 R1/R3] crédito a personal fijo de WH: solo con sesión WH hoy y día no liquidado
  if upper(coalesce(p->>'forma_pago','')) = 'CREDITO' then
    v_chk1029 := mos._credito_personal_check(p->>'cliente_doc', null);
    if not coalesce((v_chk1029->>'ok')::boolean, true) then
      return jsonb_build_object('status','error','error',v_chk1029->>'error','mensaje',v_chk1029->>'mensaje');
    end if;
  end if;

  select coalesce(sum((it->>'subtotal')::numeric), 0), count(*) into v_suma, v_nit
    from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it;
  if v_nit > 0 and abs(v_total - v_suma) > 0.01 then
    return jsonb_build_object('status','error','error','TOTAL_NO_CUADRA','detalle','total='||v_total||' suma_items='||v_suma);
  end if;
  -- [500x-2b] CPE SIN items NO se emite (SUNAT exige >=1 línea; no quemar correlativo en comprobante vacío)
  if v_nit = 0 then return jsonb_build_object('status','error','error','SIN_ITEMS'); end if;

  select (estado = 'ABIERTA'), zona_id into v_caja_ok, v_zona from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then
    -- [1007 RESCATE] CPE ya cobrado del replay de la cola: derivarlo a la caja ABIERTA de la zona
    -- (forma_pago se conserva: el dinero ya entró; el comprobante DEBE emitirse).
    if coalesce(p->>'rescate','') = '1' then
      v_caja_orig := v_caja;
      -- [1037 TARDÍO] Si la caja original es de un DÍA ANTERIOR, el ticket se queda en SU caja/día (con su
      -- correlativo normal) en vez de entrar POR_COBRAR a la caja de hoy (donde el cierre lo anulaba).
      -- [QA 1037] tardío solo si la hora de emisión (si se conoce) también es de un día anterior; la fecha
      -- se acota a la vida de la caja (apertura..cierre) para que un reloj mal puesto no la saque de su día.
      select c.fecha_cierre, c.fecha_apertura into v_cierre, v_apert from me.cajas c
       where c.id_caja = v_caja_orig
         and (c.fecha_apertura at time zone 'America/Lima')::date < (now() at time zone 'America/Lima')::date
       limit 1;
      if found and (v_fl is null or (v_fl at time zone 'America/Lima')::date < (now() at time zone 'America/Lima')::date) then
        v_tardio := true;
        v_fecha  := least(greatest(coalesce(v_fl, v_cierre, v_apert), v_apert), coalesce(v_cierre, now()));
      end if;
      if v_zona is null or btrim(v_zona) = '' then v_zona := nullif(btrim(coalesce(p->>'zona','')),''); end if;
      if (v_zona is null or btrim(v_zona) = '') and v_est is not null then
        select nullif(btrim(coalesce(id_zona,'')),'') into v_zona from mos.series_documentales
         where activo and id_estacion = v_est limit 1;
      end if;
      if not v_tardio and v_zona is not null and btrim(v_zona) <> '' then
        select c.id_caja into v_caja from me.cajas c
         where upper(coalesce(c.estado,'')) = 'ABIERTA' and c.zona_id = btrim(v_zona)
           and (c.fecha_apertura at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
         order by c.fecha_apertura desc nulls last limit 1;
        if v_caja is not null and v_caja <> v_caja_orig then v_resc := true; end if;
      end if;
    end if;
    if not v_resc and not v_tardio then
      return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA');
    end if;
  end if;

  -- [270 #18 + LOW17/19 500x-2] SERIE autoritativa desde Supabase por ZONA de la caja.
  -- [585·H2] La zona vacía ya NO desactiva el filtro (eso defaulteaba a la 1ª serie = local
  -- equivocado). Si la caja no trae zona, derivarla de la estación; si no se resuelve → SERIE_REQUERIDA.
  if v_zona is null or btrim(v_zona) = '' then
    select nullif(btrim(coalesce(id_zona,'')),'') into v_zona from mos.series_documentales
     where activo and v_est is not null and id_estacion = v_est limit 1;
  end if;
  if v_zona is null or btrim(v_zona) = '' then
    return jsonb_build_object('status','error','error','SERIE_REQUERIDA','detalle','zona no resuelta (caja/estación)');
  end if;
  -- Tiebreaker determinístico `id_serie asc`; serie SOLO de la zona resuelta (estación no cruza zonas).
  select serie into v_serie_sd from mos.series_documentales
   where activo and upper(tipo_documento) = v_tipo and id_zona = btrim(v_zona)
   order by (v_est is not null and id_estacion = v_est) desc, id_serie asc
   limit 1;
  if v_serie_sd is not null and btrim(v_serie_sd) <> '' then v_serie := btrim(v_serie_sd); end if;
  if v_serie is null then return jsonb_build_object('status','error','error','SERIE_REQUERIDA'); end if;

  v_num  := me.siguiente_correlativo(v_serie, v_ref);
  v_corr := v_serie || '-' || lpad(v_num::text, 6, '0');
  v_id   := 'V-' || (floor(extract(epoch from clock_timestamp()) * 1000))::bigint::text
                 || '-' || substr(md5(random()::text || clock_timestamp()::text || v_ref), 1, 8);

  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
                         tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio,
                         ref_local, obs, tipo_doc_cliente, nf_estado, zona_id)
  values (v_id, v_fecha, p->>'vendedor', p->>'estacion', coalesce(p->>'cliente_doc',''), coalesce(p->>'cliente_nombre',''),
          v_total, v_tipo,
          case when v_tardio then 'POR_COBRAR' else coalesce(p->>'forma_pago','EFECTIVO') end, v_corr, v_caja,   -- [1037] tardío aparte del cuadre
          coalesce(nullif(v_sub,''), p->>'dispositivo_id', ''), 'COMPLETADO', v_ref,
          case when v_tardio then '⏰TARDÍO (emitido sin conexión'||coalesce(' a las '||to_char(v_fl at time zone 'America/Lima','DD/MM HH24:MI'),'')
                                ||'; llegó '||to_char(now() at time zone 'America/Lima','DD/MM HH24:MI')||' con la caja ya cerrada) · '||coalesce(p->>'obs','')
               when v_resc then '🛟RESCATE (caja original '||coalesce(v_caja_orig,'?')||' cerrada) · '||coalesce(p->>'obs','')
               else coalesce(p->>'obs','') end,                                                 -- [1007]
          coalesce((p->>'tipo_doc_cliente')::int, 0), 'PENDIENTE', coalesce(v_zona,''))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;
  get diagnostics v_ins = row_count;

  if v_ins = 0 then
    select * into v_ex from me.ventas where ref_local = v_ref limit 1;
    if found then return jsonb_build_object('status','success','dedup',true,'id_venta',v_ex.id_venta,'correlativo',v_ex.correlativo,
                              'nf_estado',coalesce(v_ex.nf_estado,''),'nf_hash',coalesce(v_ex.nf_hash,''),'nf_enlace',coalesce(v_ex.nf_enlace,'')); end if;
    return jsonb_build_object('status','error','error','INSERT_INCONSISTENTE');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_linea := v_linea + 1;
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
                                   cod_barras, valor_unitario, tipo_igv, unidad_medida,
                                   segmento_id, segmento_nombre, segmento_pct)
    values (v_id, v_linea, v_item->>'sku', v_item->>'nombre', coalesce((v_item->>'cantidad')::numeric,0),
            coalesce((v_item->>'precio')::numeric,0), coalesce((v_item->>'subtotal')::numeric,0),
            coalesce(v_item->>'cod_barras',''), coalesce((v_item->>'valor_unitario')::numeric,0),
            coalesce((v_item->>'tipo_igv')::int,1), coalesce(v_item->>'unidad_medida','NIU'),
            nullif(btrim(coalesce(v_item->>'segmento_id','')),''),
            nullif(btrim(coalesce(v_item->>'segmento_nombre','')),''),
            nullif(v_item->>'segmento_pct','')::numeric)
    on conflict (id_venta, linea) do nothing;
  end loop;

  -- [1037] Registro de llegadas tardías (para el informe y la alerta). Nunca rompe la venta.
  if v_tardio or v_resc or (v_fl is not null and now() - v_fl > interval '5 minutes') then
    begin
      perform mos._venta_tardia_registrar(v_id, v_fl, v_tardio, v_resc, v_caja_orig);
    exception when others then raise warning '[1037] venta tardía % no registrada: %', v_id, sqlerrm; end;
  end if;

  return jsonb_build_object('status','success','dedup',false,'id_venta',v_id,'correlativo',v_corr,'numero',v_num,'nf_estado','PENDIENTE',
                            'rescatada', v_resc, 'tardio', v_tardio, 'idCaja', v_caja);                             -- [1007]
end;
$function$;

create table if not exists me.cola_dispositivo (
  device_id   text primary key,
  vendedor    text,
  zona        text,
  pendientes  int not null default 0,
  monto       numeric not null default 0,
  mas_antiguo timestamptz,
  ts          timestamptz not null default now(),
  alertado_ts timestamptz
);
alter table me.cola_dispositivo enable row level security;

create or replace function me.cola_reportar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare
  v_dev text := coalesce(nullif(me.jwt_sub(),''), nullif(btrim(coalesce(p->>'deviceId','')),''));
  v_n   int;
  v_m   numeric;
  v_ant timestamptz;
begin
  if coalesce(me.jwt_app(),'') <> 'mosExpress' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev is null then return jsonb_build_object('ok',false,'error','SIN_DEVICE'); end if;
  begin v_n := greatest(0, coalesce((p->>'pendientes')::int, 0)); exception when others then v_n := 0; end;
  begin v_m := coalesce(nullif(p->>'monto','')::numeric, 0); exception when others then v_m := 0; end;
  begin v_ant := nullif(btrim(coalesce(p->>'masAntiguo','')),'')::timestamptz; exception when others then v_ant := null; end;
  insert into me.cola_dispositivo (device_id, vendedor, zona, pendientes, monto, mas_antiguo, ts, alertado_ts)
  values (v_dev, left(coalesce(p->>'vendedor',''),80), left(coalesce(p->>'zona',''),40), v_n, v_m,
          case when v_n > 0 then v_ant end, now(), null)
  on conflict (device_id) do update
    set vendedor = excluded.vendedor, zona = excluded.zona, pendientes = excluded.pendientes, monto = excluded.monto,
        mas_antiguo = excluded.mas_antiguo, ts = now(),
        alertado_ts = case when excluded.pendientes = 0 then null else me.cola_dispositivo.alertado_ts end;
  return jsonb_build_object('ok', true);
end $f$;
revoke all on function me.cola_reportar(jsonb) from public, anon;
grant execute on function me.cola_reportar(jsonb) to authenticated, service_role;

create or replace function me.cola_vigilar()
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare r record; v_eq text; v_n int := 0;
begin
  for r in select * from me.cola_dispositivo
            where pendientes > 0 and alertado_ts is null
              and (ts < now() - interval '10 minutes' or mas_antiguo < now() - interval '30 minutes')
  loop
    select nombre_equipo into v_eq from mos.dispositivos where id_dispositivo = r.device_id limit 1;
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
        'titulo', '⚠️ Tickets sin subir',
        'cuerpo', coalesce(v_eq,'Un equipo') || ' (' || coalesce(nullif(r.vendedor,''),'?') || ' · ' || coalesce(nullif(r.zona,''),'?') || ') tiene '
                  || r.pendientes || ' ticket(s) por S/ ' || to_char(r.monto,'FM999990.00') || ' sin subir'
                  || case when r.ts < now() - interval '10 minutes'
                          then ' y no se conecta desde las ' || to_char(r.ts at time zone 'America/Lima','HH24:MI') || '. Que no lo apaguen: debe reconectarse.'
                          else ' desde las ' || to_char(r.mas_antiguo at time zone 'America/Lima','HH24:MI') || '.' end,
        'data', jsonb_build_object('tipo','cola_atascada','device',r.device_id)));
    exception when others then raise warning '[1037] push cola: %', sqlerrm;
    end;
    update me.cola_dispositivo set alertado_ts = now() where device_id = r.device_id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'alertas', v_n);
end $f$;
revoke all on function me.cola_vigilar() from public, anon, authenticated;

select cron.schedule('me-cola-vigilar', '*/5 * * * *', $cron$set statement_timeout = '5s'; select me.cola_vigilar();$cron$);

-- ── 4. Corrección de los 5 tickets del 07-oct (hora real desconocida → hora de cierre de su caja) ──
update me.ventas
   set id_caja = 'CAJA-1791374504581',
       forma_pago = 'POR_COBRAR',
       fecha = (select fecha_cierre from me.cajas where id_caja = 'CAJA-1791374504581'),
       obs = '⏰TARDÍO (emitido sin conexión el 07/10 durante la caída; hora real desconocida; llegó 08/10 07:09 con la caja ya cerrada; el cierre del 08/10 lo había anulado) · '
 where correlativo in ('NVM1-017171','NVM1-017172','NVM1-017173','NVM1-017174','NVM1-017175')
   and id_caja = 'CAJA-1791461121409' and forma_pago = 'ANULADO';

do $$
declare r record;
begin
  for r in select id_venta from me.ventas
            where correlativo in ('NVM1-017171','NVM1-017172','NVM1-017173','NVM1-017174','NVM1-017175')
              and id_caja = 'CAJA-1791374504581'
  loop
    perform mos._venta_tardia_registrar(r.id_venta, null, true, false, 'CAJA-1791374504581');
  end loop;
end $$;
update mos.ventas_tardias set nota = 'Caída Supabase 07-oct. Rescatado a la caja del 08-oct y anulado en su cierre; devuelto a su caja original el 08-oct.'
 where correlativo in ('NVM1-017171','NVM1-017172','NVM1-017173','NVM1-017174','NVM1-017175');
update mos.tickets_fantasma
   set mensaje = 'Devuelto a su caja original CAJA-1791374504581 (07-oct) como TARDÍO, POR_COBRAR. Confirmar con el cajero si se cobró.'
 where correlativo in ('NVM1-017171','NVM1-017172','NVM1-017173','NVM1-017174','NVM1-017175');

do $$ begin
  perform mos.recomputar_zona_dia(jsonb_build_object('zona','ZONA-01','fecha','2026-10-07'));
  perform mos.recomputar_zona_dia(jsonb_build_object('zona','ZONA-01','fecha','2026-10-08'));
exception when others then raise warning '[1037] recomputar: %', sqlerrm; end $$;

commit;

-- ROLLBACK
--  · funciones: reaplicar live_me_crear_venta_directa_jsonb_.sql y live_me_crear_cpe_directo_jsonb_.sql (versión previa).
--  · select cron.unschedule('me-cola-vigilar');
--  · los 5 tickets: update me.ventas set id_caja='CAJA-1791461121409', forma_pago='ANULADO', fecha=created_at where correlativo in (...);
--    y revertir su stock con kardex de ENTRADA (ver mos.ventas_tardias.stock).
