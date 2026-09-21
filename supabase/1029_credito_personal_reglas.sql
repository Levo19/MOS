-- 1029 · Reglas de crédito del personal fijo de WH + cierre del hueco papel≠sistema en liquidaciones (21-sep-2026)
-- Incidente: Jesús (almacenero, DNI 72793090). (a) consumo del 3-sep hecho un día que NO inició sesión en WH → la
-- liquidación no lo tomó; (b) el 6-sep el comprobante impreso salió SIN consumos (pendientes cacheados 30 min en el
-- front) y se pagó el bruto, pero marcar_pagos descontó igual (autoConsumos) → tickets "cobrados" que nunca se
-- cobraron (Jesús 85.40, y probablemente Jorgenis 56.80 y Sergio 17.30 ese mismo día).
--
-- R1 · Personal fijo de WH (mos.personal con documento, app_origen=warehouseMos) SOLO tiene crédito en ME el día
--      que tiene sesión de WH (fila en mos.liquidaciones_dia de ESE día). Sin sesión → rechazo con mensaje.
-- R2 · El crédito del personal fijo va SOLO por su DNI. "Asignar a turno" es para vendedores de paso de ME:
--      no se asigna un ticket cuyo DNI es de personal fijo, ni a un turno ME que sea alias de personal fijo.
--      Un ticket asignado que luego se cobra (efectivo/virtual) suelta su asignación (trigger).
-- R3 · Si el día ya fue liquidado (PAGADA) o vetado, no hay más crédito ese día.
-- R4 · marcar_pagos recibe netoEsperado (lo que dice el comprobante del front). Si el servidor calcula otro neto,
--      NO paga (rollback) y avisa → imposible imprimir un monto y registrar otro.
-- R5 · pago_detalle devuelve los consumos descontados (detalle y reimpresión dicen la verdad).
-- Off-switch R1/R3: mos.config CREDITO_PERSONAL_WH_REGLA='0'.

-- ── Alias: identidades de ME (nombre+zona) que en realidad son personal fijo ─────────────────────────
create table if not exists mos.personal_alias_me (
  id_mex      text primary key,          -- p.ej. 'MEX:JESUS GUERRERO|ZONA-02'
  id_personal text not null,             -- ficha fija (mos.personal)
  creado      timestamptz not null default now(),
  nota        text not null default ''
);
revoke all on mos.personal_alias_me from public, anon;
grant select on mos.personal_alias_me to authenticated, service_role;
insert into mos.personal_alias_me (id_mex, id_personal, nota)
select x, 'PER2607251158418560a6', 'Jesús: almacenero que también atiende caja en ME'
  from unnest(array['MEX:JESUS GUERRERO|ZONA-02','MEX:JESUS GUERRERO|ZONA-01','MEX:JESÚS GUERRERO|ZONA-02',
                    'MEX:JESUS|ZONA-02','MEX:JESÚS|ZONA-02']) x
on conflict (id_mex) do nothing;

-- ── R1/R3: el chequeo único ─────────────────────────────────────────────────────────────────────────
create or replace function mos._credito_personal_check(p_doc text, p_fecha date default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare
  v_f   date := coalesce(p_fecha, (now() at time zone 'America/Lima')::date);
  v_per record; v_dia record; v_hoy boolean;
begin
  if coalesce(btrim(p_doc),'') = '' then return jsonb_build_object('ok',true,'personal',false); end if;
  if coalesce((select valor from mos.config where clave='CREDITO_PERSONAL_WH_REGLA' limit 1),'1') <> '1' then
    return jsonb_build_object('ok',true,'personal',false,'regla','OFF');
  end if;
  select id_personal, coalesce(nullif(btrim(nombre),''),'El trabajador') nombre into v_per
    from mos.personal
   where btrim(coalesce(documento,'')) = btrim(p_doc) and coalesce(estado,true)
     and app_origen = 'warehouseMos'
   limit 1;
  if not found then return jsonb_build_object('ok',true,'personal',false); end if;
  v_hoy := v_f = (now() at time zone 'America/Lima')::date;
  select estado into v_dia from mos.liquidaciones_dia
   where id_dia = mos._liqdia_resolver(v_per.id_personal, to_char(v_f,'YYYY-MM-DD'));
  if not found then
    return jsonb_build_object('ok',false,'personal',true,'error','CREDITO_PERSONAL_SIN_SESION_WH',
      'mensaje', v_per.nombre||' no inició sesión en WH '||case when v_hoy then 'hoy' else 'el '||to_char(v_f,'DD/MM') end||
                 '. Sin sesión de WH no hay crédito: que entre a WH y vuelve a intentar.');
  end if;
  if upper(coalesce(v_dia.estado,'')) = 'PAGADA' then
    return jsonb_build_object('ok',false,'personal',true,'error','CREDITO_PERSONAL_DIA_LIQUIDADO',
      'mensaje', 'No hay crédito para '||v_per.nombre||': su día '||case when v_hoy then 'de hoy' else to_char(v_f,'DD/MM') end||
                 ' ya fue liquidado. Vuelve a tener crédito cuando inicie sesión en WH otro día.');
  end if;
  if upper(coalesce(v_dia.estado,'')) = 'VETADA' then
    return jsonb_build_object('ok',false,'personal',true,'error','CREDITO_PERSONAL_DIA_VETADO',
      'mensaje', 'No hay crédito para '||v_per.nombre||': su día '||case when v_hoy then 'de hoy' else to_char(v_f,'DD/MM') end||' está vetado.');
  end if;
  return jsonb_build_object('ok',true,'personal',true,'nombre',v_per.nombre);
end $$;
revoke all on function mos._credito_personal_check(text, date) from public, anon, authenticated;

-- Consulta previa desde el POS (antes de vender a crédito)
create or replace function me.credito_personal_verificar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  return mos._credito_personal_check(p->>'doc', null);
end $$;
revoke all on function me.credito_personal_verificar(jsonb) from public, anon;
grant execute on function me.credito_personal_verificar(jsonb) to authenticated, service_role;

-- Padrón de DNIs del personal fijo de WH (3 filas) → el POS lo guarda y así, SIN conexión, sabe que no puede
-- verificar el crédito de esa persona y lo bloquea (en vez de vender y que luego rebote como "fantasma").
create or replace function me.credito_personal_docs(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  return jsonb_build_object('ok',true,'docs', coalesce((select jsonb_agg(distinct btrim(documento))
    from mos.personal where coalesce(btrim(documento),'') <> '' and coalesce(estado,true) and app_origen = 'warehouseMos'), '[]'::jsonb));
end $$;
revoke all on function me.credito_personal_docs(jsonb) from public, anon;
grant execute on function me.credito_personal_docs(jsonb) to authenticated, service_role;


-- me.crear_venta_directa (desde pg_get_functiondef vivo; + guarda 1029)
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
begin
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
      if v_zona is null or btrim(v_zona) = '' then v_zona := nullif(btrim(coalesce(p->>'zona','')),''); end if;
      if (v_zona is null or btrim(v_zona) = '') and v_est is not null then
        select nullif(btrim(coalesce(id_zona,'')),'') into v_zona from mos.series_documentales
         where activo and id_estacion = v_est limit 1;
      end if;
      if v_zona is not null and btrim(v_zona) <> '' then
        select c.id_caja into v_caja from me.cajas c
         where upper(coalesce(c.estado,'')) = 'ABIERTA' and c.zona_id = btrim(v_zona)
           and (c.fecha_apertura at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
         order by c.fecha_apertura desc nulls last limit 1;
        if v_caja is not null and v_caja <> v_caja_orig then v_resc := true; end if;
      end if;
    end if;
    if not v_resc then
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
  values (v_id, now(), p->>'vendedor', p->>'estacion', coalesce(p->>'cliente_doc',''), coalesce(p->>'cliente_nombre',''),
          v_total, coalesce(nullif(v_tipo,''),'NOTA_DE_VENTA'),
          case when v_resc then 'POR_COBRAR' else coalesce(p->>'forma_pago','EFECTIVO') end,   -- [1007]
          v_corr, v_caja,
          coalesce(nullif(v_sub,''), p->>'dispositivo_id', ''), 'COMPLETADO', v_ref,
          case when v_resc then '🛟RESCATE (caja original '||coalesce(v_caja_orig,'?')||' cerrada) · '||coalesce(p->>'obs','')
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

  return jsonb_build_object('status','success','dedup',false,'id_venta',v_id,'correlativo',v_corr,'numero',v_num,
                            'rescatada', v_resc, 'idCaja', v_caja);                             -- [1007]
end;
$function$
;


-- me.crear_cpe_directo (desde pg_get_functiondef vivo; + guarda 1029)
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
begin
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
      if v_zona is null or btrim(v_zona) = '' then v_zona := nullif(btrim(coalesce(p->>'zona','')),''); end if;
      if (v_zona is null or btrim(v_zona) = '') and v_est is not null then
        select nullif(btrim(coalesce(id_zona,'')),'') into v_zona from mos.series_documentales
         where activo and id_estacion = v_est limit 1;
      end if;
      if v_zona is not null and btrim(v_zona) <> '' then
        select c.id_caja into v_caja from me.cajas c
         where upper(coalesce(c.estado,'')) = 'ABIERTA' and c.zona_id = btrim(v_zona)
           and (c.fecha_apertura at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
         order by c.fecha_apertura desc nulls last limit 1;
        if v_caja is not null and v_caja <> v_caja_orig then v_resc := true; end if;
      end if;
    end if;
    if not v_resc then
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
  values (v_id, now(), p->>'vendedor', p->>'estacion', coalesce(p->>'cliente_doc',''), coalesce(p->>'cliente_nombre',''),
          v_total, v_tipo,
          coalesce(p->>'forma_pago','EFECTIVO'), v_corr, v_caja,
          coalesce(nullif(v_sub,''), p->>'dispositivo_id', ''), 'COMPLETADO', v_ref,
          case when v_resc then '🛟RESCATE (caja original '||coalesce(v_caja_orig,'?')||' cerrada) · '||coalesce(p->>'obs','')
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

  return jsonb_build_object('status','success','dedup',false,'id_venta',v_id,'correlativo',v_corr,'numero',v_num,'nf_estado','PENDIENTE',
                            'rescatada', v_resc, 'idCaja', v_caja);                             -- [1007]
end;
$function$
;


-- me.creditar_venta_directo (desde pg_get_functiondef vivo; + guarda 1029)
CREATE OR REPLACE FUNCTION me.creditar_venta_directo(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_obs   text := coalesce(p->>'obs','');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_ant   text; v_obsAnt text; v_hist jsonb;
  v_rvf jsonb;
  v_asig jsonb;
  v_chk1029 jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'CREDITAR_VENTA', coalesce(p->>'idVenta',p->>'idVentaNV',p->>'idGuia',p->>'nombre',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  if v_app not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;

  perform pg_advisory_xact_lock(hashtext('cobro:'||v_id));
  select forma_pago, coalesce(obs,''), historial_cambios into v_ant, v_obsAnt, v_hist
  from me.ventas where id_venta = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Venta '||v_id||' no encontrada'); end if;

  if upper(coalesce(v_ant,'')) like 'ANULADO%' then
    return jsonb_build_object('ok',false,'error','La venta está ANULADA — no se puede creditar');
  end if;

  -- [1029 R1/R3] si el cliente del ticket es personal fijo de WH: sesión WH ese día y día no liquidado
  select mos._credito_personal_check(cliente_doc, (fecha at time zone 'America/Lima')::date)
    into v_chk1029 from me.ventas where id_venta = v_id;
  if not coalesce((v_chk1029->>'ok')::boolean, true) then
    return jsonb_build_object('ok',false,'error',v_chk1029->>'error','mensaje',v_chk1029->>'mensaje');
  end if;

  update me.ventas
     set forma_pago = 'CREDITO', obs = v_obs,
         historial_cambios = me._venta_hist_append(v_hist, jsonb_build_object(
           'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
           'source','ME_CREDITAR_VENTA','accion','convertir_a_credito',
           'cambios', jsonb_build_array(
             jsonb_build_object('campo','FormaPago','antes',coalesce(v_ant,''),'despues','CREDITO'),
             jsonb_build_object('campo','Obs','antes',coalesce(v_obsAnt,''),'despues',v_obs)),
           'autorizadoPor', v_auth, 'motivo', coalesce(nullif(v_obs,''),''))),
         updated_at = now()
   where id_venta = v_id;

  -- [848] El cajero eligió a quién se le da: se asigna en el mismo acto. Si la asignación
  -- falla (turno cerrado, otro día), el crédito YA quedó registrado y se devuelve el motivo:
  -- el ticket existe como deuda, solo queda sin dueño y se asigna después desde MOS.
  if nullif(btrim(coalesce(p->>'idDia','')),'') is not null then
    v_asig := mos._credito_asignar_core(jsonb_build_object(
      'idVenta', v_id, 'idDia', p->>'idDia', 'usuario', coalesce(v_user,'')));
  end if;

  return jsonb_build_object('ok',true,'via','directo','mensaje','Crédito registrado',
    'idVenta',v_id,'antes',coalesce(v_ant,''),'asignacion',coalesce(v_asig,'null'::jsonb));
end;
$function$
;


-- mos._credito_asignar_core (desde pg_get_functiondef vivo; + reglas 1029 R2)
CREATE OR REPLACE FUNCTION mos._credito_asignar_core(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_venta text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_dia   text := nullif(btrim(coalesce(p->>'idDia','')),'');
  v_por   text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'?');
  v_v     record; v_l record; v_prev record;
begin
  if v_venta is null or v_dia is null then
    return jsonb_build_object('ok',false,'error','idVenta e idDia requeridos');
  end if;

  perform pg_advisory_xact_lock(hashtext('credasig:'||v_venta));

  select id_venta, upper(coalesce(forma_pago,'')) fp, coalesce(total,0) total,
         coalesce(correlativo,'') correlativo, fecha
    into v_v from me.ventas where id_venta = v_venta for update;
  if not found then return jsonb_build_object('ok',false,'error','Ticket no encontrado'); end if;
  if v_v.fp <> 'CREDITO' then
    return jsonb_build_object('ok',false,'error','El ticket no está en CRÉDITO (está '||v_v.fp||')');
  end if;
  -- [1029 R2] el crédito del personal fijo va por su DNI, nunca por asignación a un turno de ME
  if exists (select 1 from me.ventas v join mos.personal pf on btrim(coalesce(pf.documento,'')) = btrim(coalesce(v.cliente_doc,''))
              where v.id_venta = v_venta and coalesce(btrim(pf.documento),'') <> '' and pf.app_origen = 'warehouseMos') then
    return jsonb_build_object('ok',false,'error','Este ticket es de personal fijo (por su DNI): se descuenta solo en su liquidación, no se asigna a un turno');
  end if;

  select id_dia, id_personal, coalesce(nombre,'') nombre, upper(coalesce(rol,'')) rol,
         coalesce(zona,'') zona, upper(coalesce(estado,'PENDIENTE')) estado,
         (fecha at time zone 'America/Lima')::date dia
    into v_l from mos.liquidaciones_dia where id_dia = v_dia;
  if not found then return jsonb_build_object('ok',false,'error','Ese turno no existe'); end if;
  -- [1029 R2] un turno de ME que es alias de personal fijo (p.ej. Jesús cajero) no recibe asignaciones
  if exists (select 1 from mos.personal_alias_me a where a.id_mex = v_l.id_personal) then
    return jsonb_build_object('ok',false,'error',v_l.nombre||' es personal fijo: su crédito va por su DNI en su liquidación, no por asignación');
  end if;
  if v_l.estado <> 'PENDIENTE' then
    return jsonb_build_object('ok',false,'error','El turno de '||v_l.nombre||' ya está '||v_l.estado||
      ' — su monto está sellado y no admite un consumo nuevo');
  end if;
  if v_l.dia <> (v_v.fecha at time zone 'America/Lima')::date then
    return jsonb_build_object('ok',false,'error','El ticket es del '||
      to_char((v_v.fecha at time zone 'America/Lima')::date,'DD/MM')||
      ' y ese turno es del '||to_char(v_l.dia,'DD/MM')||' — solo se asigna a quien trabajó ese mismo día');
  end if;

  select estado into v_prev from mos.creditos_planilla where id_venta = v_venta;
  if found and v_prev.estado = 'DESCONTADO' then
    return jsonb_build_object('ok',false,'error','Ese ticket ya fue descontado en una liquidación');
  end if;

  insert into mos.creditos_planilla
    (id_venta, id_personal, monto, correlativo, fecha_venta, estado,
     id_dia, fecha_dia, nombre_dia, asignado_por, asignado_ts)
  values (v_venta, v_l.id_personal, v_v.total, v_v.correlativo, v_v.fecha, 'ASIGNADO',
          v_l.id_dia, v_l.dia, v_l.nombre, v_por, now())
  on conflict (id_venta) do update
    set id_personal = excluded.id_personal, monto = excluded.monto,
        correlativo = excluded.correlativo, fecha_venta = excluded.fecha_venta,
        estado = 'ASIGNADO', id_dia = excluded.id_dia, fecha_dia = excluded.fecha_dia,
        nombre_dia = excluded.nombre_dia, asignado_por = excluded.asignado_por,
        asignado_ts = now(), revertido_ts = null;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'idVenta', v_venta, 'idDia', v_l.id_dia, 'idPersonal', v_l.id_personal,
    'nombre', v_l.nombre, 'rol', v_l.rol, 'zona', v_l.zona, 'monto', v_v.total,
    'asignadoPor', v_por));
end $function$
;


-- mos.turnos_del_dia (desde pg_get_functiondef vivo; + alias 1029)
CREATE OR REPLACE FUNCTION mos.turnos_del_dia(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_d date; v_out jsonb;
begin
  -- [848d] MOS y el POS: las dos apps usan esta función a propósito
  if coalesce(me.jwt_app(),'') not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  begin v_d := nullif(btrim(coalesce(p->>'fecha','')),'')::date;
  exception when others then v_d := null; end;
  v_d := coalesce(v_d, (now() at time zone 'America/Lima')::date);

  select coalesce(jsonb_agg(x.obj order by x.zona, x.rol, x.nombre), '[]'::jsonb) into v_out
    from (
      select coalesce(nullif(btrim(l.zona),''),'—') zona, upper(coalesce(l.rol,'')) rol, l.nombre,
        jsonb_build_object(
          'idDia',      l.id_dia,
          'idPersonal', l.id_personal,
          'nombre',     coalesce(l.nombre,''),
          'rol',        upper(coalesce(l.rol,'')),
          'zona',       coalesce(l.zona,''),
          'esTemporal', coalesce(l.es_temporal,false),
          'horaIngreso',to_char(l.hora_ingreso at time zone 'America/Lima','HH24:MI'),
          'ventaCobrada', coalesce(l.venta_cobrada,0),
          'pagoDia',    coalesce(l.total_dia,0),
          -- lo que ya se le asignó ese día, para que el cajero lo vea antes de sumar otro
          'yaAsignado', coalesce((select round(sum(cp.monto),2) from mos.creditos_planilla cp
                                   where cp.id_dia = l.id_dia and cp.estado in ('ASIGNADO','DESCONTADO')),0)
        ) obj
      from mos.liquidaciones_dia l
     where (l.fecha at time zone 'America/Lima')::date = v_d
       and upper(coalesce(l.estado,'PENDIENTE')) = 'PENDIENTE'
       and upper(coalesce(l.rol,'')) not in ('MASTER','ADMIN','ADMINISTRADOR')
       -- [880] SOLO trabajadores de zona: el personal fijo (WH, con documento) NO se asigna a mano,
       -- su consumo se descuenta solo en su liquidación por el documento del ticket [572].
       and coalesce(btrim(l.zona),'') <> ''
       and not exists (select 1 from mos.personal pf
                        where pf.id_personal = l.id_personal
                          and coalesce(btrim(pf.documento),'') <> '')
       -- [1029 R2] ni identidades de ME que son alias de personal fijo
       and not exists (select 1 from mos.personal_alias_me a where a.id_mex = l.id_personal)
    ) x;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'fecha', to_char(v_d,'YYYY-MM-DD'), 'n', jsonb_array_length(v_out), 'turnos', v_out));
end $function$
;


create or replace function mos._trg_credito_suelta_asignacion()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if upper(coalesce(old.forma_pago,'')) = 'CREDITO'
     and upper(coalesce(new.forma_pago,'')) not in ('CREDITO','PLANILLA') then
    delete from mos.creditos_planilla where id_venta = new.id_venta and estado = 'ASIGNADO';
  end if;
  return new;
end $$;
drop trigger if exists trg_1029_credito_suelta_asignacion on me.ventas;
create trigger trg_1029_credito_suelta_asignacion
  after update of forma_pago on me.ventas
  for each row when (old.forma_pago is distinct from new.forma_pago)
  execute function mos._trg_credito_suelta_asignacion();

-- limpieza: asignaciones de tickets que ya no están en crédito (FM02-000096 y FM02-000099 de Jesús)
delete from mos.creditos_planilla cp using me.ventas v
 where v.id_venta = cp.id_venta and cp.estado = 'ASIGNADO' and upper(coalesce(v.forma_pago,'')) <> 'CREDITO';


-- mos.marcar_pagos (desde pg_get_functiondef vivo; + guarda 1029 R4)
CREATE OR REPLACE FUNCTION mos.marcar_pagos(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_localid text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_pagpor  text := coalesce(nullif(btrim(coalesce(p->>'pagadoPor','')),''), 'admin');
  v_coment  text := coalesce(p->>'comentario','');
  v_nombre  text := coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), '');
  v_rol     text := upper(coalesce(p->>'rol',''));
  v_appo    text := coalesce(p->>'appOrigen','');
  v_dias    jsonb := coalesce(p->'dias','[]'::jsonb);
  v_fechas  jsonb := case when jsonb_typeof(p->'fechas')='array' then p->'fechas' else null end;
  v_creds   jsonb := case when jsonb_typeof(p->'creditos')='array' then p->'creditos' else '[]'::jsonb end;
  v_auto_cons boolean := coalesce((p->>'autoConsumos')::boolean, false);   -- [572]
  v_docp    text; v_vid text; v_vrow record; v_desc numeric := 0; v_ncred int := 0; v_neto numeric;
  v_fs      text; v_row mos.liquidaciones_dia%rowtype; v_built jsonb := '[]'::jsonb;
  v_id_pago text;
  v_id_gasto text;
  v_now     timestamptz := clock_timestamp();
  v_total   numeric := 0;
  v_n       int := 0;
  v_existe_gasto record;
  d         jsonb;
  v_fecha_s text;
  v_fecha   timestamptz;
  v_id_dia  text;
  v_mb numeric; v_pe numeric; v_bm numeric; v_sa numeric; v_td numeric;
  v_dia_estado text; v_dia_idpago text; v_led_idpago text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PAGOS_JORNAL_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PAGOS_JORNAL_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPersonal'); end if;
  if v_localid is null then return jsonb_build_object('ok',false,'error','Requiere localId (idempotencia DINERO)'); end if;

  if (jsonb_typeof(v_dias) <> 'array' or jsonb_array_length(v_dias) = 0) and v_fechas is not null then
    for v_fs in select jsonb_array_elements_text(v_fechas) loop
      v_fs := nullif(btrim(v_fs),'');
      if v_fs is null then continue; end if;
      select * into v_row from mos.liquidaciones_dia where id_dia = mos._liqdia_resolver(v_idp, v_fs) limit 1;
      if not found then
        return jsonb_build_object('ok',false,'error','Día no materializado (refrescá liquidación): '||v_fs,'fecha',v_fs);
      end if;
      v_built := v_built || jsonb_build_object(
        'fecha', left(v_fs,10),
        'montoBase', coalesce(v_row.monto_base,0),
        'pagoEnvasado', coalesce(v_row.pago_envasado,0),
        'bonoMeta', coalesce(v_row.bono_meta,0),
        'sancion', coalesce(v_row.sancion,0),
        'totalDia', coalesce(v_row.total_dia, mos._liqdia_total(v_row.monto_base,v_row.pago_envasado,v_row.bono_meta,0,v_row.sancion)));
      if v_nombre = '' then v_nombre := coalesce(v_row.nombre,''); end if;
      if v_rol = '' then v_rol := upper(coalesce(v_row.rol,'')); end if;
      if v_appo = '' then v_appo := coalesce(v_row.app_origen,''); end if;
    end loop;
    v_dias := v_built;
  end if;

  if jsonb_typeof(v_dias) <> 'array' or jsonb_array_length(v_dias) = 0 then
    return jsonb_build_object('ok',false,'error','Requiere dias[] o fechas[]');
  end if;

  v_id_pago := 'LIQ-' || v_localid;

  select id_gasto, monto into v_existe_gasto from mos.gastos where local_id = v_localid limit 1;
  if found then
    select count(*) into v_n from mos.liquidaciones_pagos where id_pago = v_id_pago and upper(coalesce(estado,'')) = 'PAGADA';
    return jsonb_build_object('ok',true,'dedup',true,'data',
      jsonb_build_object('idPago',v_id_pago,'idGasto',v_existe_gasto.id_gasto,'dias',v_n,'total',mos._r2(v_existe_gasto.monto)));
  end if;

  if exists (select 1 from mos.liquidaciones_pagos where id_pago = v_id_pago) then
    return jsonb_build_object('ok',true,'dedup',true,'data',
      jsonb_build_object('idPago',v_id_pago,'reusado',true,'total',0,'dias',0));
  end if;

  for d in select * from jsonb_array_elements(v_dias) e order by e->>'fecha' loop
    v_fecha_s := nullif(btrim(coalesce(d->>'fecha','')), '');
    if v_fecha_s is null then return jsonb_build_object('ok',false,'error','Día sin fecha'); end if;
    v_id_dia := coalesce(mos._liqdia_resolver(v_idp, v_fecha_s), mos._liqdia_key(v_idp, v_fecha_s));
    select upper(coalesce(estado,'')), coalesce(id_pago,'') into v_dia_estado, v_dia_idpago
      from mos.liquidaciones_dia where id_dia = v_id_dia for update;
    if found and v_dia_estado = 'VETADA' then
      return jsonb_build_object('ok',false,'error','Dia vetado (no pagable): '||v_fecha_s||' - quitalo de la seleccion o desvetalo','fecha',v_fecha_s);
    end if;
    if found and v_dia_estado = 'PAGADA' and v_dia_idpago <> v_id_pago then
      return jsonb_build_object('ok',false,'error','Día ya pagado: '||v_fecha_s,'fecha',v_fecha_s,'idPagoExistente',v_dia_idpago);
    end if;
    select id_pago into v_led_idpago from mos.liquidaciones_pagos
     where id_personal = v_idp and upper(coalesce(estado,'')) = 'PAGADA'
       and to_char(fecha,'YYYY-MM-DD') = v_fecha_s and id_pago <> v_id_pago limit 1;
    if found then
      return jsonb_build_object('ok',false,'error','Día ya pagado: '||v_fecha_s,'fecha',v_fecha_s,'idPagoExistente',v_led_idpago);
    end if;
  end loop;

  -- ════════════════════════════════════════════════════════════════════════
  -- [572] CONSUMOS AUTOMÁTICOS (server-truth). Si autoConsumos=true, el servidor
  -- arma v_creds = TODOS los tickets CREDITO vivos de la persona (por su documento)
  -- cuya fecha Lima cae en los días que se pagan. Ignora la lista del cliente →
  -- imposible evadir deuda desde el front. Mismo match exacto que 422 (consumoDia).
  -- ════════════════════════════════════════════════════════════════════════
  -- UNE (no reemplaza) los del período con lo que el admin haya marcado aparte
  -- (p.ej. "deuda de otras fechas" opcional). El loop dedup por `distinct`.
  if v_auto_cons then
    select btrim(coalesce(documento,'')) into v_docp from mos.personal where id_personal = v_idp;
    if coalesce(v_docp,'') <> '' then                           -- sin documento → nada que atar
      v_creds := v_creds || coalesce((
        select jsonb_agg(to_jsonb(v.id_venta))
          from me.ventas v
         where btrim(coalesce(v.cliente_doc,'')) = v_docp
           and upper(coalesce(v.forma_pago,'')) = 'CREDITO'
           and (v.fecha at time zone 'America/Lima')::date::text in (
                 select e->>'fecha' from jsonb_array_elements(v_dias) e)
      ), '[]'::jsonb);
    end if;
    -- [848] Y los tickets ASIGNADOS a un turno de esta persona dentro de los días que se pagan.
    -- Es el camino de los trabajadores de ME, que no tienen ficha ni documento: el vínculo lo
    -- puso una persona a mano, ticket por ticket, contra un turno concreto.
    v_creds := v_creds || coalesce((
      select jsonb_agg(to_jsonb(cp.id_venta))
        from mos.creditos_planilla cp
        join me.ventas v on v.id_venta = cp.id_venta
       where cp.id_personal = v_idp and cp.estado = 'ASIGNADO'
         and upper(coalesce(v.forma_pago,'')) = 'CREDITO'
         and cp.fecha_dia::text in (select e->>'fecha' from jsonb_array_elements(v_dias) e)
    ), '[]'::jsonb);
  end if;

  -- [419] VALIDAR + DESCONTAR créditos (elegidos por el admin O automáticos [572]) —
  -- misma tx que el pago (o TODO o NADA).
  if jsonb_array_length(v_creds) > 0 then
    -- [848] el documento puede no existir (trabajador de ME sin ficha): ya no se aborta acá.
    -- La pertenencia se decide ticket por ticket más abajo: documento propio O asignación explícita.
    select btrim(coalesce(documento,'')) into v_docp from mos.personal where id_personal = v_idp;
    for v_vid in select distinct v from unnest(array(select jsonb_array_elements_text(v_creds))) v order by v loop
      v_vid := nullif(btrim(v_vid),'');
      if v_vid is null then continue; end if;
      perform pg_advisory_xact_lock(hashtext('cobro:'||v_vid));
      select id_venta, upper(coalesce(forma_pago,'')) as fp, btrim(coalesce(cliente_doc,'')) as doc,
             coalesce(total,0) as total, coalesce(correlativo,'') as correlativo, fecha, historial_cambios
        into v_vrow from me.ventas where id_venta = v_vid for update;
      if not found then
        return jsonb_build_object('ok',false,'error','Crédito no encontrado: '||v_vid);
      end if;
      if v_vrow.fp <> 'CREDITO' then
        return jsonb_build_object('ok',false,'error','El ticket '||coalesce(nullif(v_vrow.correlativo,''),v_vid)||' ya no está en CRÉDITO ('||v_vrow.fp||') — refrescá y reintentá');
      end if;
      -- [848] es suyo si el documento del ticket es el de su ficha, o si alguien lo ASIGNÓ a un
      -- turno suyo. Sin ninguna de las dos, no se descuenta: nunca se adivina de quién es.
      if not (coalesce(v_docp,'') <> '' and v_vrow.doc = v_docp)
         and not exists (select 1 from mos.creditos_planilla cp
                          where cp.id_venta = v_vid and cp.id_personal = v_idp
                            and cp.estado in ('ASIGNADO','DESCONTADO')) then
        return jsonb_build_object('ok',false,'error','El ticket '||coalesce(nullif(v_vrow.correlativo,''),v_vid)||
          ' no es de esta persona: ni coincide su documento ni fue asignado a uno de sus turnos');
      end if;
      if exists (select 1 from mos.creditos_planilla cp where cp.id_venta = v_vid and cp.estado = 'DESCONTADO') then
        return jsonb_build_object('ok',false,'error','El ticket '||coalesce(nullif(v_vrow.correlativo,''),v_vid)||' ya fue descontado por planilla');
      end if;
      update me.ventas set
          forma_pago = 'PLANILLA',
          historial_cambios = me._venta_hist_append(v_vrow.historial_cambios, jsonb_build_object(
            'ts', to_jsonb(v_now), 'usuario', v_pagpor, 'rol', 'ADMIN',
            'source', 'MOS_MARCAR_PAGOS', 'accion', 'descuento_planilla',
            'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes','CREDITO','despues','PLANILLA')),
            'motivo', 'Descontado en liquidación '||v_id_pago)),
          updated_at = v_now
        where id_venta = v_vid;
      insert into mos.creditos_planilla (id_venta, id_pago, id_personal, monto, correlativo, fecha_venta, descontado_por)
      values (v_vid, v_id_pago, v_idp, v_vrow.total, v_vrow.correlativo, v_vrow.fecha, v_pagpor)
      on conflict (id_venta) do update
        set id_pago = excluded.id_pago, id_personal = excluded.id_personal, monto = excluded.monto,
            correlativo = excluded.correlativo, fecha_venta = excluded.fecha_venta,
            descontado_por = excluded.descontado_por, descontado_ts = now(),
            estado = 'DESCONTADO', revertido_ts = null;   -- [848] id_dia/fecha_dia se conservan
      v_desc := v_desc + coalesce(v_vrow.total,0);
      v_ncred := v_ncred + 1;
    end loop;
  end if;

  for d in select * from jsonb_array_elements(v_dias) loop
    v_fecha_s := nullif(btrim(coalesce(d->>'fecha','')), '');
    begin v_fecha := (v_fecha_s || 'T00:00:00-05:00')::timestamptz; exception when others then v_fecha := v_now; end;
    -- [571 · FIX RAÍZ] recomputar v_id_dia por cada día.
    v_id_dia := coalesce(mos._liqdia_resolver(v_idp, v_fecha_s), mos._liqdia_key(v_idp, v_fecha_s));
    select coalesce(monto_base,0), coalesce(pago_envasado,0), coalesce(bono_meta,0),
           coalesce(sancion,0), coalesce(total_dia,0)
      into v_mb, v_pe, v_bm, v_sa, v_td
      from mos.liquidaciones_dia where id_dia = v_id_dia;
    if v_td is null then v_td := 0; end if;
    v_total := v_total + v_td;
    insert into mos.liquidaciones_pagos (
      id_pago, id_personal, fecha, nombre, rol, app_origen,
      monto_base, pago_envasado, bono_meta, sancion, total_dia,
      ticket_job_id, pagado_por, pagado_ts, estado, comentario, id_gasto_generado
    ) values (
      v_id_pago, v_idp, v_fecha, v_nombre, v_rol, v_appo,
      v_mb, v_pe, v_bm, v_sa, v_td, '', v_pagpor, v_now, 'PAGADA', v_coment, ''
    ) on conflict (id_pago, id_personal, fecha) do nothing;
    update mos.liquidaciones_dia set estado='PAGADA', id_pago=v_id_pago, ts_actualizado=v_now
     where id_dia = v_id_dia;
  end loop;

  v_total := mos._r2(v_total);
  v_desc  := mos._r2(v_desc);
  v_neto  := mos._r2(v_total - v_desc);
  -- [1029 R4] el comprobante del front dice netoEsperado. Si el servidor descuenta otra cosa, NO se paga:
  -- raise → rollback de TODO (días, tickets PLANILLA, gasto). El front recarga y muestra lo real.
  if nullif(btrim(coalesce(p->>'netoEsperado','')),'') is not null
     and abs(mos._r2(wh._num(p->>'netoEsperado')) - v_neto) > 0.009 then
    raise exception 'NETO_NO_CUADRA: el comprobante dice S/% pero hoy corresponde S/% (consumos S/%). Recarga liquidaciones y vuelve a pagar.',
      to_char(mos._r2(wh._num(p->>'netoEsperado')),'FM999990.00'), to_char(v_neto,'FM999990.00'), to_char(v_desc,'FM999990.00')
      using errcode = 'P0001';
  end if;
  v_id_gasto := 'GAS-' || v_localid;
  insert into mos.gastos (id_gasto, fecha, categoria, tipo, descripcion, monto, comprobante, registrado_por, local_id)
  values (
    v_id_gasto, (select min(fecha) from mos.liquidaciones_pagos where id_pago = v_id_pago),
    'JORNALES', 'FIJO',
    'Liquidación '||v_id_pago||' · '||coalesce(nullif(v_nombre,''),v_idp)||' · '
      ||(select count(*) from mos.liquidaciones_pagos where id_pago=v_id_pago and upper(coalesce(estado,''))='PAGADA')::text||' día(s)'
      ||case when v_ncred > 0 then ' · −S/'||to_char(v_desc,'FM999999990.00')||' ('||v_ncred||' consumo(s) por planilla)' else '' end,
    v_neto, '', v_pagpor, v_localid
  ) on conflict (local_id) where local_id is not null do nothing;

  update mos.liquidaciones_pagos set id_gasto_generado = v_id_gasto
   where id_pago = v_id_pago and coalesce(id_gasto_generado,'') = '';
  select count(*) into v_n from mos.liquidaciones_pagos where id_pago = v_id_pago and upper(coalesce(estado,'')) = 'PAGADA';

  return jsonb_build_object('ok',true,'dedup',false,'data',
    jsonb_build_object('idPago',v_id_pago,'idGasto',v_id_gasto,'dias',v_n,'total',v_total,
                       'descuentoCreditos',v_desc,'creditosDescontados',v_ncred,'neto',v_neto));
end;
$function$
;


-- mos.pago_detalle (desde pg_get_functiondef vivo; + consumos 1029 R5)
CREATE OR REPLACE FUNCTION mos.pago_detalle(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idpago text := nullif(btrim(coalesce(p->>'idPago','')), '');
  v_idpers text;
  v_head   record;
  v_dias   jsonb;
  v_total  numeric;
  v_cant   int;
  v_fr     jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_idpago is null then return jsonb_build_object('ok', false, 'error', 'Requiere idPago'); end if;
  v_fr := mos._frescura_sombra();

  -- ¿existe el pago? (paridad: si no hay filas → 'idPago no encontrado')
  if not exists (select 1 from mos.liquidaciones_pagos g where coalesce(g.id_pago,'') = v_idpago) then
    return jsonb_build_object('ok', false, 'error', 'idPago no encontrado');
  end if;

  -- cabecera = 1ª fila del pago. Orden estable por ctid para emular "rows[0]" del GAS.
  select g.id_pago, g.id_personal, g.nombre, g.rol, g.pagado_por,
         coalesce(to_char(g.pagado_ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),'') as pagado_ts,
         g.estado, g.ticket_job_id, g.id_gasto_generado, g.comentario
    into v_head
  from mos.liquidaciones_pagos g
  where coalesce(g.id_pago,'') = v_idpago
  order by g.ctid
  limit 1;

  v_idpers := coalesce(v_head.id_personal,'');

  -- motivo sanción por fecha: última eval (ctid desc) con sancion>0 para v_idpers (key idPersonal|fecha)
  with sanmot as (
    select distinct on (fdia)
      to_char((e.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD') as fdia,
      coalesce(nullif(e.sancion_motivo,''), 'sin motivo registrado')    as motivo
    from mos.evaluaciones e
    where coalesce(e.id_personal,'') = v_idpers
      and coalesce(e.sancion,0) > 0
    order by fdia, e.ctid desc
  )
  select jsonb_agg(
           jsonb_build_object(
             'fecha',             f,
             'montoBase',         monto_base,
             'pagoEnvasado',      pago_env,
             'bonoMeta',          bono_meta,
             'sancion',           sancion,
             'totalDia',          total_dia,
             'auditado',          auditado,
             'scoreFinal',        score_final,
             'evaluacionesCount', evaluaciones_count,
             'tarifaEnvasado',    tarifa,
             'unidadesEnvasadas', uds,
             'sancionMotivo',     sancion_motivo
           ) order by ord
         ),
         round(sum(total_dia)::numeric, 2),
         count(*)::int
    into v_dias, v_total, v_cant
  from (
    select
      to_char((g.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD') as f,
      coalesce(g.monto_base, 0)                                         as monto_base,
      coalesce(g.pago_envasado, 0)                                      as pago_env,
      coalesce(g.bono_meta, 0)                                          as bono_meta,
      coalesce(g.sancion, 0)                                            as sancion,
      coalesce(g.total_dia, 0)                                          as total_dia,
      coalesce(d.auditado, false)                                       as auditado,
      coalesce(d.score_final, 0)                                        as score_final,
      coalesce(d.evaluaciones_count, 0)::int                            as evaluaciones_count,
      coalesce(d.tarifa_envasado, 0)                                    as tarifa,
      case when coalesce(d.tarifa_envasado,0) > 0
           then round((coalesce(g.pago_envasado,0) / d.tarifa_envasado))::int
           else 0 end                                                   as uds,
      coalesce(sm.motivo, '')                                           as sancion_motivo,
      g.ctid                                                            as ord
    from mos.liquidaciones_pagos g
    -- cruce ldia por idPersonal|fecha (idPers = cabecera, NO g.id_personal — paridad L537)
    left join mos.liquidaciones_dia d
      on coalesce(d.id_personal,'') = v_idpers
     and to_char((d.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD')
       = to_char((g.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD')
    left join sanmot sm
      on sm.fdia = to_char((g.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD')
    where coalesce(g.id_pago,'') = v_idpago
  ) z;

  return jsonb_build_object(
           'ok',   true,
           'data', jsonb_build_object(
             'idPago',          coalesce(v_head.id_pago,''),
             'idPersonal',      coalesce(v_head.id_personal,''),
             'nombre',          coalesce(v_head.nombre,''),
             'rol',             coalesce(v_head.rol,''),
             'pagadoPor',       coalesce(v_head.pagado_por,''),
             'pagadoTs',        coalesce(v_head.pagado_ts,''),
             'estado',          coalesce(v_head.estado,''),
             'ticketJobId',     coalesce(v_head.ticket_job_id,''),
             'idGastoGenerado', coalesce(v_head.id_gasto_generado,''),
             'comentario',      coalesce(v_head.comentario,''),
             'ticketEscPos',    coalesce((select ticket_escpos from mos.ticket_pago_snapshot where id_pago = v_idpago),''),
             'dias',            coalesce(v_dias, '[]'::jsonb),
             'total',           coalesce(v_total, 0),
             'cantidadDias',    coalesce(v_cant, 0),
             -- [1029 R5] consumos descontados en este pago + neto
             'consumos',        coalesce((select jsonb_agg(jsonb_build_object(
                                   'correlativo', cp.correlativo, 'monto', cp.monto,
                                   'fecha', to_char(cp.fecha_venta at time zone 'America/Lima','YYYY-MM-DD'))
                                   order by cp.fecha_venta)
                                 from mos.creditos_planilla cp
                                where cp.id_pago = v_idpago and cp.estado = 'DESCONTADO'), '[]'::jsonb),
             'descuentoConsumos', coalesce((select mos._r2(sum(cp.monto)) from mos.creditos_planilla cp
                                where cp.id_pago = v_idpago and cp.estado = 'DESCONTADO'), 0),
             'neto',            mos._r2(coalesce(v_total,0) - coalesce((select sum(cp.monto) from mos.creditos_planilla cp
                                where cp.id_pago = v_idpago and cp.estado = 'DESCONTADO'), 0))
           )
         ) || v_fr;
end;
$function$
;
