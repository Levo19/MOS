-- [885] BUZÓN DE IGV A FAVOR — facturas de compra que NO tienen guía de ingreso (van directo a zona
-- por decisión de la jefa). Se suben acá, el OCR las lee y su IGV suma al "a favor". Con dos reglas:
--   1) DEDUP: si la misma factura (serie+número+RUC emisor) ya está en una guía de ingreso o en el
--      buzón, se marca DUPLICADA y NO vuelve a sumar.
--   2) RUC CLIENTE = el nuestro: una factura emitida a OTRO RUC no da IGV recuperable → NO_ES_NUESTRA.

-- el RUC de la empresa (el que debe figurar como CLIENTE en las facturas de compra para recuperar IGV)
insert into mos.config (clave, valor, descripcion) values
  ('EMPRESA_RUC', '20610714057', 'RUC de la empresa. En una factura de COMPRA debe ser el CLIENTE para que su IGV sea recuperable.')
on conflict (clave) do update set valor = excluded.valor, descripcion = excluded.descripcion;

-- guardamos también el RUC cliente que lea el OCR de las guías (hoy no se captura). Sirve para avisar
-- si una guía de ingreso quedó emitida a OTRO RUC (IGV NO recuperable).
alter table wh.guias add column if not exists ocr_ruc_cliente text;

create table if not exists wh.igv_buzon (
  id_buzon        text primary key default ('BZ-' || replace(gen_random_uuid()::text,'-','')),
  foto            text,
  mes             int not null,
  anio            int not null,
  ruc_emisor      text,
  razon_social    text,
  ruc_cliente     text,
  serie           text,
  numero          text,
  fecha_comprobante text,
  total           numeric,
  igv             numeric,
  tipo_comprobante text,
  confidence      int,
  ocr_estado      text,
  estado          text not null default 'PENDIENTE',   -- VALIDA | DUPLICADA | NO_ES_NUESTRA | SIN_IGV | ILEGIBLE | NO_COMPROBANTE
  dup_ref         text,                                  -- id_guia o id_buzon que duplica
  notas           text,
  subido_por      text,
  ts              timestamptz not null default now()
);
create index if not exists ix_igv_buzon_mes on wh.igv_buzon (anio, mes);
create index if not exists ix_igv_buzon_doc on wh.igv_buzon (ruc_emisor, serie, numero);

-- registra una entrada del buzón (la llama la Edge tras el OCR). Aplica dedup + validación de RUC.
create or replace function mos.igv_buzon_registrar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_ruc_emp  text := btrim(coalesce((select valor from mos.config where clave='EMPRESA_RUC' limit 1),''));
  v_emisor   text := btrim(coalesce(p->>'rucEmisor',''));
  v_cliente  text := btrim(coalesce(p->>'rucCliente',''));
  v_serie    text := upper(btrim(coalesce(p->>'serie','')));
  v_numero   text := btrim(coalesce(p->>'numero',''));
  v_tipo     text := upper(btrim(coalesce(p->>'tipoComprobante','')));
  v_ocr_est  text := upper(btrim(coalesce(p->>'estado','')));
  v_igv      numeric := coalesce(mos._numn(p->>'igv'), 0);
  v_mes int; v_anio int; v_estado text; v_dup text := null; v_id text;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_mes  := coalesce(mos._numn(p->>'mes')::int,  extract(month from (now() at time zone 'America/Lima'))::int);
  v_anio := coalesce(mos._numn(p->>'anio')::int, extract(year  from (now() at time zone 'America/Lima'))::int);

  -- clasificación (en cascada, la primera que aplica manda)
  if v_ocr_est in ('ILEGIBLE','NO_COMPROBANTE') then
    v_estado := v_ocr_est;
  elsif v_tipo <> 'FACTURA' or v_igv <= 0 then
    v_estado := 'SIN_IGV';
  elsif v_ruc_emp <> '' and v_cliente <> '' and v_cliente <> v_ruc_emp then
    v_estado := 'NO_ES_NUESTRA';   -- la factura NO está a nuestro RUC → su IGV no es recuperable
  else
    -- DEDUP: ¿ya está esta factura como guía de ingreso? (mismo emisor + serie + número)
    if v_emisor <> '' and v_serie <> '' and v_numero <> '' then
      select id_guia into v_dup from wh.guias
       where upper(coalesce(tipo,'')) like 'INGRESO_PROVEEDOR%'
         and btrim(coalesce(ocr_ruc_emisor,'')) = v_emisor
         and upper(btrim(coalesce(ocr_serie,''))) = v_serie
         and btrim(coalesce(ocr_numero,'')) = v_numero
       limit 1;
      if v_dup is null then
        select id_buzon into v_dup from wh.igv_buzon
         where btrim(coalesce(ruc_emisor,'')) = v_emisor
           and upper(btrim(coalesce(serie,''))) = v_serie
           and btrim(coalesce(numero,'')) = v_numero
           and estado <> 'DUPLICADA'
         limit 1;
      end if;
    end if;
    v_estado := case when v_dup is not null then 'DUPLICADA' else 'VALIDA' end;
  end if;

  insert into wh.igv_buzon (foto, mes, anio, ruc_emisor, razon_social, ruc_cliente, serie, numero,
      fecha_comprobante, total, igv, tipo_comprobante, confidence, ocr_estado, estado, dup_ref, notas, subido_por)
  values (nullif(btrim(coalesce(p->>'foto','')),''), v_mes, v_anio, v_emisor, nullif(btrim(coalesce(p->>'razonSocial','')),''),
      v_cliente, v_serie, v_numero, nullif(btrim(coalesce(p->>'fecha','')),''),
      coalesce(mos._numn(p->>'total'),0), v_igv, v_tipo, coalesce(mos._numn(p->>'confidence')::int,0),
      v_ocr_est, v_estado, v_dup, nullif(btrim(coalesce(p->>'notas','')),''), nullif(btrim(coalesce(p->>'usuario','')),''))
  returning id_buzon into v_id;

  return jsonb_build_object('ok',true,'idBuzon',v_id,'estado',v_estado,'dupRef',v_dup,
    'igv', case when v_estado='VALIDA' then v_igv else 0 end);
end $function$;
grant execute on function mos.igv_buzon_registrar(jsonb) to authenticated, anon, service_role;

-- listar el buzón del mes
create or replace function mos.igv_buzon_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_mes int := coalesce(mos._numn(p->>'mes')::int, extract(month from (now() at time zone 'America/Lima'))::int);
        v_anio int := coalesce(mos._numn(p->>'anio')::int, extract(year from (now() at time zone 'America/Lima'))::int);
        v_arr jsonb; v_val numeric;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'idBuzon', id_buzon, 'foto', foto, 'rucEmisor', ruc_emisor, 'razonSocial', razon_social, 'rucCliente', ruc_cliente,
      'serie', serie, 'numero', numero, 'fecha', fecha_comprobante, 'total', total, 'igv', igv,
      'estado', estado, 'dupRef', dup_ref, 'confidence', confidence, 'notas', notas,
      'ts', to_char(ts at time zone 'America/Lima','YYYY-MM-DD HH24:MI')) order by ts desc), '[]'::jsonb),
    coalesce(sum(igv) filter (where estado='VALIDA'),0)
    into v_arr, v_val
    from wh.igv_buzon where anio = v_anio and mes = v_mes;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('items', v_arr, 'igvBuzonValido', round(v_val,2)));
end $function$;
grant execute on function mos.igv_buzon_listar(jsonb) to authenticated, anon, service_role;

-- borrar una entrada del buzón (admin)
create or replace function mos.igv_buzon_borrar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_id text := nullif(btrim(coalesce(p->>'idBuzon','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','falta idBuzon'); end if;
  delete from wh.igv_buzon where id_buzon = v_id; get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0);
end $function$;
grant execute on function mos.igv_buzon_borrar(jsonb) to authenticated, anon, service_role;

select mos.igv_buzon_registrar(jsonb_build_object('rucEmisor','20111111111','rucCliente','20610714057','serie','F001','numero','123','tipoComprobante','FACTURA','igv','18','total','118','estado','PROCESADO','mes','8','anio','2026')) prueba_valida;
select mos.igv_buzon_registrar(jsonb_build_object('rucEmisor','20111111111','rucCliente','20999999999','serie','F001','numero','999','tipoComprobante','FACTURA','igv','36','total','236','estado','PROCESADO','mes','8','anio','2026')) prueba_ajena;
select mos.igv_buzon_registrar(jsonb_build_object('rucEmisor','20111111111','rucCliente','20610714057','serie','F001','numero','123','tipoComprobante','FACTURA','igv','18','total','118','estado','PROCESADO','mes','8','anio','2026')) prueba_dup;
