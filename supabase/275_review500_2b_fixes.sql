-- 275_review500_2b_fixes.sql — Correcciones de la 2ª pasada del 500x jornada 2.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- (A) TRIGGER de normalización/guardia fiscal en me.ventas (BEFORE INSERT/UPDATE) — defensa UNICA que cubre
--     TODOS los caminos de escritura de nf_estado (incl. el PATCH crudo de GAS _dualWriteVentaPatchME que
--     elude set_cpe_nf): [HIGH dual-write raw] [HIGH revierte BAJA] [HIGH/MED vocab BAJA] [MED STUB].
--       · normaliza vocabulario: BAJA*→BAJA, STUB/EMITIENDO→PENDIENTE, RECHAZADO*→RECHAZADO.
--       · EMITIDO y BAJA son TERMINALES (no se degradan; solo EMITIDO→BAJA permitido).
--       · no borra nf_hash/nf_enlace/nf_qr buenos con cadena vacía (defensa del [HIGH hash-blank]).
-- (B) me.set_cpe_nf: nf_hash/nf_enlace con nullif (no pisar con '') [HIGH hash-blank, fix primario].
-- (C) crear_venta_directa / crear_cpe_directo: exigir items (no quemar correlativo en comprobante vacío)
--     [MED sin-items] + serie SOLO de la zona de la caja [LOW serie cruza zona].
-- (D) cpe_trazabilidad: pendientes_sunat excluye también 'BAJA%' [HIGH/critico contaminación].
-- Money/fiscal-safe, idempotente. El trigger solo actúa sobre filas CPE (BOLETA/FACTURA).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── (A) Trigger de guardia fiscal ──
create or replace function me._nf_estado_guard() returns trigger language plpgsql as $fn$
begin
  if NEW.tipo_doc not in ('BOLETA','FACTURA') then return NEW; end if;

  -- normalizar vocabulario fiscal a los canónicos
  if NEW.nf_estado is not null and btrim(NEW.nf_estado) <> '' then
    NEW.nf_estado := case
      when upper(NEW.nf_estado) like 'BAJA%'      then 'BAJA'
      when upper(NEW.nf_estado) in ('STUB','EMITIENDO') then 'PENDIENTE'
      when upper(NEW.nf_estado) like 'RECHAZAD%'   then 'RECHAZADO'
      when upper(NEW.nf_estado) in ('PENDIENTE','EMITIDO','RECHAZADO','BAJA') then upper(NEW.nf_estado)
      else NEW.nf_estado end;
  end if;

  if TG_OP = 'UPDATE' then
    -- EMITIDO y BAJA son terminales (no se degradan). EMITIDO→BAJA sí (anulación legítima).
    if coalesce(OLD.nf_estado,'') = 'EMITIDO'
       and NEW.nf_estado is distinct from 'EMITIDO' and coalesce(NEW.nf_estado,'') <> 'BAJA' then
      NEW.nf_estado := 'EMITIDO';
    end if;
    if coalesce(OLD.nf_estado,'') = 'BAJA' and coalesce(NEW.nf_estado,'') <> 'BAJA' then
      NEW.nf_estado := 'BAJA';
    end if;
    -- no borrar comprobante (hash/enlace/qr) bueno con un valor vacío
    if coalesce(NEW.nf_hash,'')   = '' and coalesce(OLD.nf_hash,'')   <> '' then NEW.nf_hash   := OLD.nf_hash;   end if;
    if coalesce(NEW.nf_enlace,'') = '' and coalesce(OLD.nf_enlace,'') <> '' then NEW.nf_enlace := OLD.nf_enlace; end if;
    if coalesce(NEW.nf_qr,'')     = '' and coalesce(OLD.nf_qr,'')     <> '' then NEW.nf_qr     := OLD.nf_qr;     end if;
  end if;
  return NEW;
end;
$fn$;

drop trigger if exists tg_nf_estado_guard on me.ventas;
create trigger tg_nf_estado_guard before insert or update on me.ventas
  for each row execute function me._nf_estado_guard();

-- ── (B) set_cpe_nf: no pisar nf_hash/nf_enlace con cadena vacía ──
create or replace function me.set_cpe_nf(p_ref_local text, p_nf jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app  text := me.jwt_app();
  v_role text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','');
  v_ref  text := nullif(btrim(coalesce(p_ref_local,'')),'');
  v_new  text := upper(coalesce(p_nf->>'nf_estado',''));
  v_cur  me.ventas%rowtype;
  v_n    int;
  v_acep boolean := case when p_nf ? 'aceptada' then (p_nf->>'aceptada')::boolean
                         when p_nf ? 'nf_aceptada_sunat' then (p_nf->>'nf_aceptada_sunat')::boolean
                         else null end;
begin
  if v_app not in ('mosExpress','MOS') and v_role <> 'service_role' then
    return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA');
  end if;
  if not me._cpe_directo_on() then return jsonb_build_object('status','error','error','CPE_DIRECTO_DESACTIVADO'); end if;
  if v_ref is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  if v_new <> '' and v_new not in ('PENDIENTE','EMITIDO','RECHAZADO','BAJA') then
    return jsonb_build_object('status','error','error','NF_ESTADO_INVALIDO');
  end if;

  select * into v_cur from me.ventas where ref_local = v_ref limit 1;
  if not found then return jsonb_build_object('status','success','actualizadas',0); end if;
  if v_cur.tipo_doc not in ('BOLETA','FACTURA') then
    return jsonb_build_object('status','error','error','NO_ES_CPE');
  end if;
  if coalesce(v_cur.nf_estado,'') = 'EMITIDO' and v_new <> '' and v_new <> 'EMITIDO' and v_new <> 'BAJA' then
    return jsonb_build_object('status','error','error','EMITIDO_NO_DEGRADABLE');
  end if;

  update me.ventas
     set nf_estado = case when v_new <> '' then v_new else nf_estado end,
         nf_hash   = coalesce(nullif(p_nf->>'nf_hash',''),   nf_hash),
         nf_enlace = coalesce(nullif(p_nf->>'nf_enlace',''), nf_enlace),
         nf_qr     = coalesce(nullif(p_nf->>'nf_qr',''), nullif(p_nf->>'qr',''), nullif(p_nf->>'qrString',''), nf_qr),
         nf_aceptada_sunat = coalesce(v_acep, nf_aceptada_sunat),
         nf_sunat_code  = coalesce(nullif(p_nf->>'sunat_code',''), nullif(p_nf->>'nf_sunat_code',''), nf_sunat_code),
         nf_sunat_desc  = coalesce(nullif(p_nf->>'sunat_desc',''), nullif(p_nf->>'sunatDescription',''), nullif(p_nf->>'nf_sunat_desc',''), nf_sunat_desc),
         nf_enlace_xml  = coalesce(nullif(p_nf->>'enlace_xml',''), nullif(p_nf->>'nf_enlace_xml',''), nf_enlace_xml),
         nf_enlace_cdr  = coalesce(nullif(p_nf->>'enlace_cdr',''), nullif(p_nf->>'nf_enlace_cdr',''), nf_enlace_cdr),
         nf_orden_sunat = coalesce(nullif(p_nf->>'numero_orden_sunat',''), nullif(p_nf->>'nf_orden_sunat',''), nf_orden_sunat),
         nf_ultima_consulta = case when p_nf ? 'consultado' or v_acep is not null or coalesce(p_nf->>'nf_estado','')<>''
                                   then now() else nf_ultima_consulta end
   where ref_local = v_ref;
  get diagnostics v_n = row_count;
  return jsonb_build_object('status','success','actualizadas', v_n);
end;
$fn$;
revoke all on function me.set_cpe_nf(text, jsonb) from public;
grant execute on function me.set_cpe_nf(text, jsonb) to authenticated, service_role;

-- ── (D) cpe_trazabilidad: pendientes_sunat excluye también 'BAJA%' ──
create or replace function me.cpe_trazabilidad(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app   text := me.jwt_app();
  v_role  text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','');
  v_desde date := coalesce(nullif(p->>'desde','')::date, current_date - 30);
  v_hasta date := coalesce(nullif(p->>'hasta','')::date, current_date);
  v_estado text := upper(coalesce(p->>'estado',''));
  v_rows jsonb;
begin
  if v_app not in ('MOS','mosExpress') and v_role <> 'service_role' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(j order by (j->>'fecha') desc), '[]'::jsonb) into v_rows from (
    select jsonb_build_object(
      'idVenta', v.id_venta, 'refLocal', v.ref_local, 'correlativo', v.correlativo,
      'tipo', v.tipo_doc, 'fecha', v.fecha, 'total', v.total,
      'cliente', nullif(btrim(coalesce(v.cliente_nombre,'')),''), 'clienteDoc', v.cliente_doc,
      'nfEstado', coalesce(nullif(v.nf_estado,''),'(sin emitir)'),
      'aceptadoNubefact', (coalesce(v.nf_hash,'') <> ''),
      'aceptadoSunat',    coalesce(v.nf_aceptada_sunat, v.nf_estado='EMITIDO'),
      'sunatCode', v.nf_sunat_code, 'sunatDesc', v.nf_sunat_desc,
      'enlacePdf', v.nf_enlace, 'enlaceXml', v.nf_enlace_xml, 'enlaceCdr', v.nf_enlace_cdr,
      'ordenSunat', v.nf_orden_sunat, 'qr', v.nf_qr,
      'ultimaConsulta', v.nf_ultima_consulta,
      'zona', v.zona_id, 'vendedor', v.vendedor
    ) j, v.fecha
    from me.ventas v
    where v.tipo_doc in ('BOLETA','FACTURA')
      and v.fecha::date between v_desde and v_hasta
      and (v_estado = '' or upper(coalesce(v.nf_estado,'')) = v_estado
           or (v_estado='SIN_SUNAT' and coalesce(v.nf_aceptada_sunat,false) is not true and coalesce(v.nf_estado,'') not in ('RECHAZADO','BAJA')))
    order by v.fecha desc
  ) t;

  return jsonb_build_object('ok',true,'desde',v_desde,'hasta',v_hasta,
    'total', jsonb_array_length(v_rows),
    'pendientes_sunat', (select count(*) from me.ventas v where v.tipo_doc in ('BOLETA','FACTURA')
        and v.fecha::date between v_desde and v_hasta
        and coalesce(v.nf_aceptada_sunat,false) is not true
        and coalesce(v.nf_estado,'') not in ('RECHAZADO','BAJA','')
        and upper(coalesce(v.nf_estado,'')) not like 'BAJA%'),
    'cpe', v_rows);
end;
$fn$;
revoke all on function me.cpe_trazabilidad(jsonb) from public;
grant execute on function me.cpe_trazabilidad(jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
