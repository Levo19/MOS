-- 65_wh_actualizar_guia.sql — [PASO 4] Editar campos de CABECERA de una guía. INERTE.
-- Replica fielmente _actualizarGuiaImpl (Productos.gs): UPDATE de los campos de la whitelist que vengan presentes
-- (tipo, idProveedor, idZona, numeroDocumento, comentario, foto). NO toca stock ni lotes (solo metadatos de la guía).
-- Además, si viene comentario, lo propaga al preingreso vinculado (id_preingreso de la guía) — igual que el GAS.
--
-- Idempotente NATURAL: es un UPDATE de campos concretos a valores concretos → re-ejecutar = mismo resultado.
-- No mueve stock por delta → NO necesita dedup por local_id.
-- CONTRATO: solo se escribe un campo si la CLAVE viene presente en p (el cliente solo manda los que cambió). Se
-- distingue 'ausente' de 'vacío' con `p ? 'clave'` (operador jsonb has-key) → mandar ''  SÍ limpia el campo (igual que
-- GAS, que solo entra al forEach si params[key] !== undefined).

insert into mos.config (clave, valor, descripcion) values
  ('WH_ACTUALIZAR_GUIA_DIRECTO','0','WH: editar cabecera de guia directo a Supabase (RPC wh.actualizar_guia).')
on conflict (clave) do nothing;

-- p = { id_guia, tipo?, id_proveedor?, id_zona?, numero_documento?, comentario?, foto? }
create or replace function wh.actualizar_guia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_pre text;
begin
  if coalesce((select valor from mos.config where clave='WH_ACTUALIZAR_GUIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ACTUALIZAR_GUIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- asegurar que existe (devuelve también id_preingreso para la propagación de comentario)
  select id_preingreso into v_pre from wh.guias where id_guia = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  -- UPDATE solo de los campos PRESENTES en p (operador `?` = has-key; coalesce al valor viejo si la clave no vino).
  update wh.guias set
    tipo             = case when p ? 'tipo'             then p->>'tipo'             else tipo end,
    id_proveedor     = case when p ? 'id_proveedor'     then p->>'id_proveedor'     else id_proveedor end,
    id_zona          = case when p ? 'id_zona'          then p->>'id_zona'          else id_zona end,
    numero_documento = case when p ? 'numero_documento' then p->>'numero_documento' else numero_documento end,
    comentario       = case when p ? 'comentario'       then p->>'comentario'       else comentario end,
    foto             = case when p ? 'foto'             then p->>'foto'             else foto end
  where id_guia = v_id;

  -- propagar comentario al preingreso vinculado (igual que GAS)
  if p ? 'comentario' and nullif(btrim(coalesce(v_pre,'')),'') is not null then
    update wh.preingresos set comentario = p->>'comentario' where id_preingreso = v_pre;
  end if;

  return jsonb_build_object('ok',true,'id_guia',v_id);
end;
$fn$;

revoke all on function wh.actualizar_guia(jsonb) from public;
grant execute on function wh.actualizar_guia(jsonb) to service_role, authenticated;
