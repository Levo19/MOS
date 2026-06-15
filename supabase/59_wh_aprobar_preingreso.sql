-- 59_wh_aprobar_preingreso.sql — [PASO 5 · B4] Orquestador ATÓMICO (hallazgo 40x #4): aprobar preingreso.
-- Crea la guía (INGRESO_PROVEEDOR, ABIERTA) desde el preingreso + marca el preingreso PROCESADO con esa guía,
-- EN UNA SOLA TRANSACCIÓN. Replica _aprobarPreingresoImpl (GAS): si ya PROCESADO con guía → dedup. Idempotente.
-- La guía hereda id_proveedor/comentario/usuario del preingreso (foto = URL ya en Drive, no sube nueva). Gate _claim_ok.

insert into mos.config (clave, valor, descripcion) values
  ('WH_APROBAR_PREINGRESO_DIRECTO','0','WH: aprobar preingreso directo (orquestador atomico guia+procesado).')
on conflict (clave) do nothing;

create or replace function wh.aprobar_preingreso(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idpre  text := nullif(btrim(coalesce(p->>'id_preingreso','')), '');
  v_idguia text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_usuario text := coalesce(p->>'usuario','');
  v_estado text; v_guia_ex text; v_prov text; v_coment text; v_usupre text;
begin
  if coalesce((select valor from mos.config where clave='WH_APROBAR_PREINGRESO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_APROBAR_PREINGRESO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idpre is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  select estado, id_guia, id_proveedor, comentario, usuario
    into v_estado, v_guia_ex, v_prov, v_coment, v_usupre
    from wh.preingresos where id_preingreso = v_idpre limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','PREINGRESO_NO_ENCONTRADO'); end if;

  -- idempotencia: ya procesado con guía → dedup (no crea otra guía)
  if upper(coalesce(v_estado,'')) = 'PROCESADO' and nullif(btrim(coalesce(v_guia_ex,'')),'') is not null then
    return jsonb_build_object('ok',true,'dedup',true,'id_guia',v_guia_ex);
  end if;
  if v_idguia is null then return jsonb_build_object('ok',false,'error','FALTA_ID_GUIA'); end if;

  -- crear la guía ABIERTA desde el preingreso (on conflict → idempotente por id_guia)
  insert into wh.guias (id_guia, tipo, fecha, usuario, id_proveedor, id_zona, numero_documento,
    comentario, monto_total, estado, id_preingreso, foto)
  values (v_idguia, 'INGRESO_PROVEEDOR', now(), coalesce(nullif(v_usuario,''), v_usupre), coalesce(v_prov,''),
    '', '', coalesce(v_coment,''), 0, 'ABIERTA', v_idpre, '')
  on conflict (id_guia) do nothing;

  -- marcar el preingreso PROCESADO + vincular la guía
  update wh.preingresos set estado = 'PROCESADO', id_guia = v_idguia where id_preingreso = v_idpre;

  return jsonb_build_object('ok',true,'dedup',false,'id_guia',v_idguia);
end;
$fn$;

revoke all on function wh.aprobar_preingreso(jsonb) from public;
grant execute on function wh.aprobar_preingreso(jsonb) to service_role, authenticated;
