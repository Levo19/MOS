-- ============================================================================
-- 323_fac_reconciliar_huerfanos.sql — B2: reconciliador de HUÉRFANOS cross-system
-- ----------------------------------------------------------------------------
-- El review 200x (B2) destapó: si NubeFact ACEPTA un número pero un statement posterior de la
-- misma tx falla → rollback borra el comprobante local Y retrocede fac.series.correlativo, pero
-- SUNAT conservó el número → la próxima venta lo REUSA (duplicado) o el "ya fue informado" lo
-- registra con datos equivocados. El DB local no tiene rastro del huérfano (todo rollbackeó); solo
-- NubeFact lo sabe. Reordenar el emit NO es la solución limpia (una NubeFact-rechazada dejaría la
-- NV anulada sin CPE, o re-crearía el huérfano). La red de seguridad correcta es DETECTAR vía NubeFact.
--
-- Este reconciliador, por cada serie activa, camina desde correlativo+1 hacia adelante:
--   · si el número ya está local → sigue mirando adelante;
--   · si NubeFact lo TIENE (aceptado o con enlace) y NO está local → HUÉRFANO: lo importa (fila
--     ORFANO_RECUP con los datos que NubeFact devuelve) + avanza fac.series.correlativo (nunca lo
--     reusa); marca 'revisar datos' porque consultar_comprobante no trae items/cliente completos;
--   · si NubeFact NO lo tiene → fin de la secuencia de esa serie (para).
-- Idempotente (local_id 'ORFANO-<serie>-<num>' + on conflict). Bounded (max_por_serie, tope 100).
-- Solo corre en modo REAL (config activa). `for update` en fac.series serializa con la emisión.
-- ============================================================================

create or replace function fac.reconciliar_huerfanos(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_cfg fac.config%rowtype; v_real boolean;
  v_max int := least(greatest(coalesce((p->>'max_por_serie')::int, 20), 1), 100);
  v_s record; v_num bigint; v_gap int; v_j jsonb;
  v_import int := 0; v_res jsonb := '[]'::jsonb;
  v_estado text; v_id text; v_local text;
begin
  -- SIN gate de app: corre desde pg_cron (sin request.jwt.claims → fac._app_ok()=false lo mataría,
  -- como fac.reconciliar). La contención es el gate v_real (config activa) + que solo lee NubeFact +
  -- importa números que YA existen en SUNAT (no manipula datos del caller). grant a authenticated/service_role.
  select * into v_cfg from fac.config where id = 1;
  v_real := v_cfg.activo and coalesce(v_cfg.nubefact_ruta,'') <> '' and coalesce(v_cfg.nubefact_token,'') <> '';
  if not v_real then return jsonb_build_object('status','skip','motivo','config inactiva'); end if;

  for v_s in select serie, tipo, correlativo from fac.series where coalesce(activa,true) = true for update loop
    v_num := v_s.correlativo;
    v_gap := 0;
    loop
      v_num := v_num + 1;
      v_gap := v_gap + 1;
      if v_gap > v_max then exit; end if;
      -- ya está local → seguir mirando adelante (no consultar de más)
      if exists (select 1 from fac.comprobantes where serie = v_s.serie and numero = v_num) then
        continue;
      end if;
      v_j := fac._consultar(v_s.serie, v_num, v_s.tipo);
      if v_j is null then exit; end if;   -- sin respuesta → parar (no arriesgar avanzar a ciegas)
      if coalesce((v_j->>'aceptada_por_sunat')::boolean, false)
         or coalesce(v_j->>'enlace_del_pdf','') <> '' then
        -- HUÉRFANO: NubeFact lo tiene, local no. Importar + avanzar el contador.
        v_estado := case when coalesce((v_j->>'aceptada_por_sunat')::boolean,false) then 'EMITIDO' else 'PENDIENTE' end;
        v_local  := 'ORFANO-' || v_s.serie || '-' || v_num;
        v_id     := 'CPE-' || to_char((now() at time zone 'America/Lima'),'YYYYMMDD') || '-' || v_s.serie || '-' || lpad(v_num::text,6,'0');
        insert into fac.comprobantes(id,app,origen,tipo,serie,numero,moneda,cliente_tipo_doc,cliente_doc,
           cliente_nombre,total,items,estado,nf_hash,nf_enlace_pdf,nf_enlace_xml,nf_qr,sunat_descripcion,errores,local_id,creado_por)
        values (v_id, fac._app(), 'ORFANO_RECUP', v_s.tipo, v_s.serie, v_num, 'PEN', '0', '',
           '', 0, '[]'::jsonb, v_estado, v_j->>'codigo_hash', v_j->>'enlace_del_pdf', v_j->>'enlace_del_xml',
           v_j->>'cadena_para_codigo_qr', v_j->>'sunat_description',
           'RECUPERADO por reconciliador de huérfanos — revisar cliente/items/total (consultar_comprobante no los trae)',
           v_local, 'RECON')
        on conflict (serie, numero) do nothing;
        update fac.series set correlativo = v_num where serie = v_s.serie and correlativo < v_num;
        v_import := v_import + 1;
        v_res := v_res || jsonb_build_array(jsonb_build_object('serie',v_s.serie,'numero',v_num,'estado',v_estado));
      else
        exit;   -- NubeFact no lo tiene → fin de la secuencia de esta serie
      end if;
    end loop;
  end loop;

  return jsonb_build_object('status','success','importados',v_import,'detalle',v_res);
end;
$fn$;
revoke all on function fac.reconciliar_huerfanos(jsonb) from public;
grant execute on function fac.reconciliar_huerfanos(jsonb) to authenticated, service_role;

-- pg_cron: barrido de huérfanos 1×/día (03:17 Lima≈08:17 UTC). No-op si config inactiva. Idempotente.
select cron.unschedule('fac-huerfanos') where exists (select 1 from cron.job where jobname='fac-huerfanos');
select cron.schedule('fac-huerfanos', '17 8 * * *', $$ select fac.reconciliar_huerfanos('{}'::jsonb) $$);
