-- 344b: push best-effort producto-nuevo (#33) + extension-pendiente (#27). Cero-GAS.
CREATE OR REPLACE FUNCTION wh.registrar_producto_nuevo(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cb    text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_guia  text := nullif(btrim(coalesce(p->>'idGuia','')), '');
  v_cant  numeric := wh._num(p->>'cantidad');   -- tolerante (coma decimal/vacío/basura → 0), paridad flota
  -- fecha defensiva: solo castea si arranca con formato ISO (YYYY-MM-DD); sino null (no aborta la tx)
  v_venc  timestamptz := case when nullif(btrim(coalesce(p->>'fechaVencimiento','')),'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
                              then (p->>'fechaVencimiento')::timestamptz else null end;
  v_exist text; v_id text;
begin
  if coalesce((select valor from mos.config where clave='WH_REGISTRAR_PN_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REGISTRAR_PN_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- código NLEV único si el producto no tiene barcode (secuencia atómica, sin parsear histórico)
  if v_cb is null then
    v_cb := 'NLEV' || nextval('wh.seq_nlev')::text;
  end if;

  -- UPSERT por (codigo_barra, id_guia, PENDIENTE) — idéntico al GAS (REPLACE, no duplica)
  if v_guia is not null then
    select id_producto_nuevo into v_exist from wh.producto_nuevo
      where id_guia = v_guia and upper(codigo_barra) = upper(v_cb) and upper(coalesce(estado,'')) = 'PENDIENTE'
      limit 1;
  end if;

  if v_exist is not null then
    update wh.producto_nuevo set
      marca             = coalesce(nullif(btrim(coalesce(p->>'marca','')),''), marca),
      descripcion       = coalesce(nullif(btrim(coalesce(p->>'descripcion','')),''), descripcion),
      id_categoria      = coalesce(nullif(btrim(coalesce(p->>'idCategoria','')),''), id_categoria),
      unidad            = coalesce(nullif(btrim(coalesce(p->>'unidad','')),''), unidad),
      cantidad          = case when v_cant > 0 then v_cant else cantidad end,
      fecha_vencimiento = coalesce(v_venc, fecha_vencimiento),
      foto              = coalesce(nullif(btrim(coalesce(p->>'foto','')),''), foto),
      usuario           = coalesce(nullif(btrim(coalesce(p->>'usuario','')),''), usuario),
      fecha_registro    = now()
    where id_producto_nuevo = v_exist;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('idProductoNuevo',v_exist,'codigoBarra',v_cb,'idempotente',true));
  end if;

  v_id := 'PN' || (extract(epoch from clock_timestamp())*1000)::bigint::text;
  insert into wh.producto_nuevo (id_producto_nuevo, id_guia, marca, descripcion, codigo_barra, id_categoria,
    unidad, cantidad, fecha_vencimiento, foto, estado, usuario, fecha_registro, aprobado_por, fecha_aprobacion, observacion)
  values (v_id, coalesce(v_guia,''), coalesce(p->>'marca',''), coalesce(p->>'descripcion',''), v_cb,
    coalesce(p->>'idCategoria',''), coalesce(p->>'unidad',''), v_cant, v_venc,
    coalesce(p->>'foto',''), 'PENDIENTE', coalesce(p->>'usuario',''), now(), '', null, '');
    begin perform mos.emitir_push(jsonb_build_object('audiencia',jsonb_build_object('roles',jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),'titulo','🆕 Producto nuevo por revisar','cuerpo','Código '||coalesce(nullif(v_cb,''),'?')||' · revísalo y apruébalo en el catálogo','data',jsonb_build_object('tipo','wh_producto_nuevo'))); exception when others then null; end;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idProductoNuevo',v_id,'codigoBarra',v_cb,'idempotente',false));
end;
$function$
;

CREATE OR REPLACE FUNCTION mos.pedir_extension(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_dev    text := btrim(coalesce(p->>'deviceId',''));
  v_rol    text := btrim(coalesce(p->>'rol',''));
  v_fecha  text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_idpers text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_dia    date; v_idp text; v_iddia text; v_ppal text; v_cod text; v_idreq text;
  v_prev   mos.extension_requests%rowtype;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF');
  end if;
  if v_nombre = '' or v_dev = '' then return jsonb_build_object('ok',false,'error','nombre y deviceId requeridos'); end if;
  begin v_dia := coalesce(v_fecha::date, (now() at time zone 'America/Lima')::date);
  exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;
  -- [306] WH manda idPersonal → identidad NO temporal (llave = id_personal, igual que
  --   su sesión en liquidaciones_dia). ME no manda idPersonal → temporal MEX (igual que antes).
  v_idp   := mos._identidad_persona(v_idpers, v_nombre, v_zona, v_idpers is null);
  v_iddia := mos._liqdia_key(v_idp, to_char(v_dia,'YYYY-MM-DD'));

  perform 1 from mos.liquidaciones_dia where id_dia = v_iddia and upper(coalesce(estado_sesion,''))='ACTIVA';
  if not found then return jsonb_build_object('ok', true, 'needsApproval', false); end if;

  perform 1 from mos.accesos_dispositivos where id_dia=v_iddia and device_id=v_dev and upper(coalesce(estado,''))='ACTIVA';
  if found then return jsonb_build_object('ok', true, 'needsApproval', false, 'alreadyLinked', true); end if;

  v_ppal := coalesce(
    (select device_id from mos.accesos_dispositivos where id_dia=v_iddia and es_principal order by hora_ingreso limit 1),
    (select device_id from mos.liquidaciones_dia where id_dia=v_iddia));

  -- [100x H2] si ya hay un PENDIENTE vivo de ESTE device para ESTA sesión → reusarlo (no spam)
  select * into v_prev from mos.extension_requests
   where id_dia=v_iddia and device_sol=v_dev and upper(coalesce(estado,''))='PENDIENTE' and now() <= expira
   order by creado desc limit 1;
  if found then
    return jsonb_build_object('ok',true,'needsApproval',true,'idReq',v_prev.id_req,'codigo',v_prev.codigo,'idDia',v_iddia,'principalDeviceId',v_ppal);
  end if;

  v_cod  := lpad((floor(random()*1000))::int::text, 3, '0');
  v_idreq := 'EXT-' || to_char(now(),'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text || v_dev), 1, 6);
  insert into mos.extension_requests (id_req, id_dia, device_sol, rol_sol, codigo, push_token)
  values (v_idreq, v_iddia, v_dev, v_rol, v_cod, btrim(coalesce(p->>'pushToken','')));
    begin perform mos.emitir_push(jsonb_build_object('audiencia',jsonb_build_object('roles',jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),'titulo','⏰ Solicitud de extensión de horario','cuerpo',coalesce(nullif(v_nombre,''),'alguien')||coalesce(' · '||nullif(v_zona,''),'')||' pide más tiempo · aprueba o rechaza','data',jsonb_build_object('tipo','extension_pendiente'))); exception when others then null; end;
  return jsonb_build_object('ok',true,'needsApproval',true,'idReq',v_idreq,'codigo',v_cod,'idDia',v_iddia,'principalDeviceId',v_ppal);
end;
$function$
;

