-- ════════════════════════════════════════════════════════════════════════════
-- fac_02_emitir.sql · Emisión CPE síncrona a NubeFact (dentro de Postgres)
-- ════════════════════════════════════════════════════════════════════════════
-- Port fiel del payload de emitir-cpe (Edge) + NubeFact.gs, ahora 100% en DB.
-- Correlativo seguro: PEEK → http_post → avanza SOLO si NubeFact responde. Timeout
-- → RAISE → rollback (no se quema número; el reintento manda el MISMO número y
-- NubeFact dedupea). Idempotente por local_id. STUB si config inactiva.
-- ════════════════════════════════════════════════════════════════════════════

-- Helper: POST a NubeFact con el header configurable (DRY: emitir/anular/consultar)
create or replace function fac._http_nf(p_body jsonb)
returns text language plpgsql security definer set search_path = '' as $fn$
declare v_cfg fac.config%rowtype; v_auth text; v_resp text;
begin
  select * into v_cfg from fac.config where id = 1;
  v_auth := replace(coalesce(nullif(v_cfg.auth_header,''),'Token token="{token}"'), '{token}', coalesce(v_cfg.nubefact_token,''));
  -- el rol authenticated tiene statement_timeout=8s; NubeFact puede tardar más → subir local
  perform set_config('statement_timeout','30000', true);
  -- CONNECTTIMEOUT corto: si la RUTA no resuelve/conecta, NO colgar el lock de la serie
  perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT','5');
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT','22');
  select content into v_resp from extensions.http(('POST', v_cfg.nubefact_ruta,
    array[extensions.http_header('Authorization', v_auth)], 'application/json', p_body::text)::extensions.http_request);
  return v_resp;
end;
$fn$;

-- Helper: consultar_comprobante (para dedup tras "ya fue informado" y reconciliación)
create or replace function fac._consultar(p_serie text, p_num bigint, p_tipoc int)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_resp text;
begin
  v_resp := fac._http_nf(jsonb_build_object(
    'operacion','consultar_comprobante','tipo_de_comprobante',p_tipoc,'serie',p_serie,'numero',p_num));
  return v_resp::jsonb;
exception when others then return null;
end;
$fn$;

create or replace function fac.emitir_cpe(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app   text := fac._app();
  v_tipo  text := upper(coalesce(p->>'tipo_doc',''));
  v_tipoc int;
  v_serie text;
  v_zona  text := nullif(btrim(coalesce(p->>'zona','')), '');   -- zona de emisión → serie por zona
  v_local text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_total numeric := coalesce((p->>'total')::numeric, 0);
  v_suma  numeric; v_nit int;
  v_cli   jsonb := coalesce(p->'cliente','{}'::jsonb);
  v_ex    fac.comprobantes%rowtype;
  v_cfg   fac.config%rowtype;
  v_real  boolean;
  v_num   bigint;
  v_grav numeric:=0; v_ivap numeric:=0; v_impivap numeric:=0; v_exo numeric:=0; v_inaf numeric:=0; v_igv numeric;
  v_nfitems jsonb;
  v_estado text; v_pdf text; v_qr text; v_hash text; v_xml text; v_err text; v_sunatdesc text;
  v_body jsonb; v_resp text; v_j jsonb; v_cons jsonb;
  v_id text;
begin
  if not fac._app_ok() then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not fac._on()     then return jsonb_build_object('status','error','error','FAC_DESACTIVADO'); end if;
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('status','error','error','TIPO_INVALIDO'); end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('status','error','error','ITEMS_VACIOS'); end if;
  -- local_id OBLIGATORIO: es la clave anti-doble-emisión fiscal (sin él, un reintento duplicaría)
  if v_local is null then return jsonb_build_object('status','error','error','REQUIERE_LOCAL_ID'); end if;

  select * into v_cfg from fac.config where id = 1;
  v_tipoc := case when v_tipo = 'FACTURA' then 1 else 2 end;
  -- [serie por zona de emisión] prioridad: serie explícita > serie de la ZONA (mos.series_documentales,
  -- la fuente de verdad que se edita en MOS; cada zona —incl. el propio MOS/VIP— tiene su seriado) >
  -- default de fac.config. Así una boleta emitida/convertida en zona1 lleva el serie de zona1, no uno
  -- tecleado a mano (evita el establecimiento equivocado / desync de correlativo).
  v_serie := coalesce(
    nullif(btrim(coalesce(p->>'serie','')),''),
    case when v_zona is not null then (
      select max(btrim(serie)) from mos.series_documentales
       where btrim(coalesce(id_zona,'')) = v_zona
         and coalesce(activo,true) = true
         and btrim(coalesce(serie,'')) <> ''
         and upper(regexp_replace(coalesce(tipo_documento,''),'[\s_]','','g')) =
             case when v_tipo='FACTURA' then 'FACTURA' else 'BOLETA' end
    ) else null end,
    case when v_tipo='FACTURA' then v_cfg.serie_factura else v_cfg.serie_boleta end);
  if v_serie is null or v_serie = '' then return jsonb_build_object('status','error','error','SERIE_REQUERIDA'); end if;

  -- [B1 · 200x] guard anti base-imponible manipulada (además del total==Σsubtotal). Por LÍNEA: la base
  -- (valor_unitario×cantidad) no puede exceder el subtotal de línea, y el IGV implícito no puede ser
  -- negativo; en exonerado/inafecto la base debe igualar el subtotal (sin IGV). Sin esto, un
  -- valor_unitario incoherente generaba gravada>total / IGV NEGATIVO enviado a SUNAT (rechazo o base mal).
  if exists (
    select 1 from jsonb_array_elements(v_items) e
    cross join lateral (select
        round(coalesce((e->>'valor_unitario')::numeric,0) * coalesce((e->>'cantidad')::numeric,1), 2) as subvu,
        coalesce((e->>'subtotal')::numeric,0) as sub,
        coalesce(nullif(regexp_replace(coalesce(e->>'tipo_igv','1'),'\D','','g'),'')::int, 1) as tig) x
    where x.subvu > x.sub + 0.01                                 -- base de línea > total de línea (siempre inválido)
       or (x.tig in (1,8)  and (x.sub - x.subvu) < -0.01)        -- IGV negativo en gravado/IVAP
       or (x.tig >= 9      and abs(x.sub - x.subvu) > 0.02)      -- exonerado/inafecto: base debe == total (sin IGV)
  ) then
    return jsonb_build_object('status','error','error','BASE_IMPONIBLE_INVALIDA',
      'detalle','una línea tiene valor_unitario incoherente con su subtotal (IGV negativo o base>total)');
  end if;

  -- base imponible no manipulable: total == Σ(items.subtotal) (tol 0.01)
  select coalesce(sum((e->>'subtotal')::numeric),0), count(*) into v_suma, v_nit
    from jsonb_array_elements(v_items) e;
  if v_nit > 0 and abs(v_total - v_suma) > 0.01 then
    return jsonb_build_object('status','error','error','TOTAL_NO_CUADRA','detalle','total='||v_total||' suma='||v_suma);
  end if;

  -- lock de la serie hasta fin de tx (serializa numeración + la llamada a NubeFact)
  perform 1 from fac.series where serie = v_serie for update;
  if not found then
    insert into fac.series(serie,tipo,correlativo) values (v_serie, v_tipoc, 0) on conflict (serie) do nothing;
    perform 1 from fac.series where serie = v_serie for update;
  end if;

  -- idempotencia (dentro del lock)
  if v_local is not null then
    select * into v_ex from fac.comprobantes where local_id = v_local limit 1;
    if found then
      return jsonb_build_object('status','success','dedup',true,'id',v_ex.id,'serie',v_ex.serie,'numero',v_ex.numero,
        'correlativo',v_ex.serie||'-'||lpad(v_ex.numero::text,6,'0'),'estado',v_ex.estado,
        'qr',coalesce(v_ex.nf_qr,''),'pdf',coalesce(v_ex.nf_enlace_pdf,''),'hash',coalesce(v_ex.nf_hash,''));
    end if;
  end if;

  -- ── totales catálogo 07 SUNAT + items NubeFact (1=Gravado 8=IVAP 9/10=Exonerado 11+=Inafecto) ──
  select
    coalesce(sum(case when tig=1 then subvu else 0 end),0),
    coalesce(sum(case when tig=1 then igvit else 0 end),0),   -- IGV = Σ por ítem (cuadra con el payload, no por resta)
    coalesce(sum(case when tig=8 then subvu else 0 end),0),
    coalesce(sum(case when tig=8 then igvit else 0 end),0),
    coalesce(sum(case when tig in (9,10) then sub else 0 end),0),
    coalesce(sum(case when tig not in (1,8,9,10) then sub else 0 end),0),
    jsonb_agg(jsonb_build_object(
      'unidad_de_medida', um, 'codigo', sku, 'codigo_producto_sunat', cods,
      'descripcion', nom, 'cantidad', cant, 'valor_unitario', round(vu,2),
      'precio_unitario', preu, 'descuento','', 'subtotal', subvu,
      'tipo_de_igv', tig, 'igv', igvit, 'total', sub,
      'anticipo_regularizacion', false, 'anticipo_documento_serie','', 'anticipo_documento_numero',''))
  into v_grav, v_igv, v_ivap, v_impivap, v_exo, v_inaf, v_nfitems
  from (
    select tig, cant, vu, sub, preu, um, sku, cods, nom, subvu,
           case when tig in (1,8) then round(sub - subvu, 2) else 0 end as igvit
    from (
      select coalesce(nullif(regexp_replace(coalesce(e->>'tipo_igv','1'),'\D','','g'),'')::int, 1) as tig,
             coalesce((e->>'cantidad')::numeric,1) as cant,
             coalesce((e->>'valor_unitario')::numeric,0) as vu,
             coalesce((e->>'subtotal')::numeric,0) as sub,
             coalesce((e->>'precio')::numeric,0) as preu,
             coalesce(e->>'unidad_medida','NIU') as um,
             coalesce(e->>'sku','') as sku,
             coalesce(e->>'cod_sunat','') as cods,
             coalesce(e->>'nombre','') as nom,
             round(coalesce((e->>'valor_unitario')::numeric,0) * coalesce((e->>'cantidad')::numeric,1), 2) as subvu
      from jsonb_array_elements(v_items) e
    ) a
  ) q;
  v_grav:=round(v_grav,2); v_igv:=round(v_igv,2); v_ivap:=round(v_ivap,2); v_impivap:=round(v_impivap,2); v_exo:=round(v_exo,2); v_inaf:=round(v_inaf,2);

  -- PEEK del correlativo (idempotente; NO avanza todavía)
  v_num := fac._peek_correlativo(v_serie, v_local);

  -- ── STUB (config inactiva) vs REAL (http a NubeFact) ──
  v_real := v_cfg.activo and coalesce(v_cfg.nubefact_ruta,'') <> '' and coalesce(v_cfg.nubefact_token,'') <> '';
  v_estado := 'STUB'; v_pdf := '(demo) PDF pendiente NubeFact'; v_qr := '(demo)';

  if v_real then
    v_body := jsonb_build_object(
      'operacion','generar_comprobante','tipo_de_comprobante',v_tipoc,'serie',v_serie,'numero',v_num,
      'sunat_transaction',1,
      'cliente_tipo_de_documento', coalesce(nullif(regexp_replace(coalesce(v_cli->>'tipo',''),'\D','','g'),'')::int, 0),
      'cliente_numero_de_documento', coalesce(nullif(v_cli->>'doc',''),'0'),
      'cliente_denominacion', coalesce(nullif(v_cli->>'nombre',''),'CLIENTE ANONIMO'),
      'cliente_direccion', coalesce(v_cli->>'direccion',''),
      'cliente_email', coalesce(v_cli->>'email',''),
      'fecha_de_emision', to_char((now() at time zone 'America/Lima')::date,'DD-MM-YYYY'),
      'fecha_de_vencimiento','', 'moneda', case when coalesce(p->>'moneda','PEN')='USD' then 2 else 1 end, 'tipo_de_cambio','',
      'porcentaje_de_igv',18,
      'total_gravada',   case when v_grav>0    then v_grav    else null end,
      'total_ivap',      case when v_ivap>0    then v_ivap    else null end,
      'total_imp_ivap',  case when v_impivap>0 then v_impivap else null end,
      'total_exonerada', case when v_exo>0     then v_exo     else null end,
      'total_inafecta',  case when v_inaf>0    then v_inaf    else null end,
      'total_igv',       case when v_igv>0     then v_igv     else null end,
      'total_precio_de_venta', v_total, 'total_descuentos','', 'total_otros_cargos','', 'total', v_total,
      'detraccion', false, 'enviar_automaticamente_a_la_sunat', true,
      'enviar_automaticamente_al_cliente', (coalesce(v_cli->>'email','')<>''),
      'formato_de_pdf','TICKET', 'items', v_nfitems);

    -- Timeout/red → RAISE → rollback total. NO se consume numeración.
    begin
      v_resp := fac._http_nf(v_body);
    exception when others then
      raise exception 'NUBEFACT_SIN_RESPUESTA: % (no se consumió numeración; reintenta)', SQLERRM;
    end;
    v_j := v_resp::jsonb;
    -- desync de numeración: NubeFact debe usar el número que enviamos. Si difiere → parar y realinear
    -- (no corromper silenciosamente). Pasa solo si las series Postgres/NubeFact no están alineadas.
    if nullif(v_j->>'numero','') is not null and (v_j->>'numero') ~ '^\d+$'
       and (v_j->>'numero')::bigint <> v_num then
      raise exception 'CORRELATIVO_DESYNC: NubeFact respondió numero=% pero enviamos %; realinear con admin_alinear_correlativo', v_j->>'numero', v_num;
    end if;

    if coalesce((v_j->>'aceptada_por_sunat')::boolean, false) then
      -- SUNAT aceptó → EMITIDO
      v_estado := 'EMITIDO'; v_pdf := v_j->>'enlace_del_pdf'; v_xml := v_j->>'enlace_del_xml';
      v_qr := v_j->>'cadena_para_codigo_qr'; v_hash := v_j->>'codigo_hash'; v_sunatdesc := v_j->>'sunat_description';
    elsif coalesce(v_j->>'errors','') ~* 'ya\s+fue\s+informado|duplicad|ya\s+existe' then
      -- duplicado (reintento tras timeout) → consultar el existente
      v_cons := fac._consultar(v_serie, v_num, v_tipoc);
      if v_cons is not null and coalesce((v_cons->>'aceptada_por_sunat')::boolean,false) then
        v_estado := 'EMITIDO'; v_pdf := v_cons->>'enlace_del_pdf'; v_xml := v_cons->>'enlace_del_xml';
        v_qr := v_cons->>'cadena_para_codigo_qr'; v_hash := v_cons->>'codigo_hash'; v_sunatdesc := v_cons->>'sunat_description';
      else
        v_estado := 'PENDIENTE'; v_err := 'duplicado en NubeFact; reconciliación verificará'; v_qr := coalesce(v_cons->>'cadena_para_codigo_qr','');
      end if;
    elsif coalesce(v_j->>'enlace_del_pdf','') <> '' then
      -- NubeFact GENERÓ el comprobante pero SUNAT aún NO lo aceptó (async). NO afirmar EMITIDO
      -- (riesgo legal): queda PENDIENTE; el cron fac-reconciliar lo confirma. Guardamos pdf/qr/hash.
      v_estado := 'PENDIENTE'; v_pdf := v_j->>'enlace_del_pdf'; v_xml := v_j->>'enlace_del_xml';
      v_qr := v_j->>'cadena_para_codigo_qr'; v_hash := v_j->>'codigo_hash'; v_sunatdesc := v_j->>'sunat_description';
    else
      v_estado := 'RECHAZADO'; v_err := coalesce(v_j->>'errors', v_j->>'sunat_description', 'rechazado');
      v_sunatdesc := v_j->>'sunat_description'; v_hash := v_j->>'codigo_hash';
      v_pdf := v_j->>'enlace_del_pdf'; v_qr := v_j->>'cadena_para_codigo_qr';
    end if;
  end if;

  -- avance del correlativo (monotónico: nunca retrocede). STUB siempre avanza; REAL porque NubeFact respondió.
  update fac.series set correlativo = v_num where serie = v_serie and correlativo < v_num;

  v_id := 'CPE-' || to_char((now() at time zone 'America/Lima'),'YYYYMMDD') || '-' || v_serie || '-' || lpad(v_num::text,6,'0');
  insert into fac.comprobantes(id,app,origen,tipo,serie,numero,moneda,cliente_tipo_doc,cliente_doc,cliente_nombre,
     cliente_direccion,cliente_email,total_gravada,total_exonerada,total_inafecta,total_ivap,total_imp_ivap,total_igv,total,items,estado,
     nf_hash,nf_enlace_pdf,nf_enlace_xml,nf_qr,sunat_descripcion,errores,local_id,ref_externa,creado_por)
  values (v_id, v_app, coalesce(p->>'origen','POS'), v_tipoc, v_serie, v_num, coalesce(p->>'moneda','PEN'),
     coalesce(v_cli->>'tipo','0'), coalesce(v_cli->>'doc',''), coalesce(v_cli->>'nombre',''),
     coalesce(v_cli->>'direccion',''), coalesce(v_cli->>'email',''),
     v_grav, v_exo, v_inaf, v_ivap, v_impivap, v_igv, v_total, coalesce(v_nfitems, v_items), v_estado,
     v_hash, v_pdf, v_xml, v_qr, v_sunatdesc, v_err, v_local, nullif(p->>'ref_externa',''), coalesce(p->>'creado_por', v_app));

  if v_local is not null then
    insert into fac.correlativos_emitidos(idem_key,serie,numero) values (v_local,v_serie,v_num)
    on conflict (idem_key) do nothing;
  end if;

  return jsonb_build_object('status','success','dedup',false,'id',v_id,'serie',v_serie,'numero',v_num,
    'correlativo', v_serie||'-'||lpad(v_num::text,6,'0'), 'estado',v_estado,
    'gravada',v_grav,'igv',v_igv,'total',v_total,
    'qr',coalesce(v_qr,''),'pdf',coalesce(v_pdf,''),'hash',coalesce(v_hash,''),'errores',coalesce(v_err,''));
end;
$fn$;

revoke all on function fac._http_nf(jsonb) from public;
revoke all on function fac._consultar(text, bigint, int) from public;
revoke all on function fac.emitir_cpe(jsonb) from public;
grant execute on function fac.emitir_cpe(jsonb) to authenticated;
