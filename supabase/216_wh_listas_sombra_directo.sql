-- 216_wh_listas_sombra_directo.sql — Escritura DIRECTA de listas-sombra a Supabase (100% Supabase, sin GAS).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- Cierra la asimetría: getListasSombra YA lee de wh.listas_sombra (directo), pero crear/tomar/liberar/
-- progreso/cerrar/anular iban por GAS→Hoja. Réplica fiel de gas/ListasSombra.gs. Gate wh._claim_ok +
-- flag WH_LISTA_SOMBRA_DIRECTO. Idempotente por id_lista (PK). El push a operadores (notificarMOS) NO
-- va acá (es Grupo C externo). items = jsonb.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

-- CREAR
create or replace function wh.crear_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_user text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_items jsonb := p->'items';
  v_id   text := nullif(btrim(coalesce(p->>'idLista','')), '');
  v_comp boolean := coalesce((p->>'compartir')::boolean, false);
  v_estado text;
begin
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_user is null then return jsonb_build_object('ok',false,'error','usuario requerido'); end if;
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok',false,'error','sin items'); end if;
  v_id := coalesce(v_id, 'LS'||(extract(epoch from clock_timestamp())*1000)::bigint::text);
  -- idempotencia
  if exists (select 1 from wh.listas_sombra where id_lista = v_id) then
    return jsonb_build_object('ok',true,'data', jsonb_build_object('idLista', v_id, 'duplicado', true)); end if;
  v_estado := case when v_comp then 'DISPONIBLE' else 'EN_USO' end;
  insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, usuario_tomada, fecha_tomada, fecha_completada, nota)
  values (v_id, now(), v_user, v_items, v_estado,
          case when v_comp then null else v_user end,
          case when v_comp then null else now() end,
          null, coalesce(p->>'nota',''))
  on conflict (id_lista) do nothing;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idLista', v_id, 'estado', v_estado));
end;
$fn$;

-- TOMAR
create or replace function wh.tomar_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idLista','')), '');
  v_user text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_forzar boolean := coalesce((p->>'forzar')::boolean, false);
  v_row wh.listas_sombra%rowtype;
begin
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_user is null then return jsonb_build_object('ok',false,'error','idLista y usuario requeridos'); end if;
  select * into v_row from wh.listas_sombra where id_lista = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if upper(coalesce(v_row.estado,'')) = 'COMPLETADA' then return jsonb_build_object('ok',false,'error','YA_COMPLETADA'); end if;
  if upper(coalesce(v_row.estado,'')) = 'EN_USO' and coalesce(btrim(v_row.usuario_tomada),'') <> ''
     and btrim(v_row.usuario_tomada) <> v_user and not v_forzar then
    return jsonb_build_object('ok',false,'error','EN_USO_POR_OTRO','mensaje','Tomada por: '||v_row.usuario_tomada); end if;
  update wh.listas_sombra set estado='EN_USO', usuario_tomada=v_user, fecha_tomada=now() where id_lista = v_id;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idLista', v_id, 'items', coalesce(v_row.items,'[]'::jsonb), 'dueno', v_user));
end;
$fn$;

-- LIBERAR
create or replace function wh.liberar_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idLista','')), '');
  v_user text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_forzar boolean := coalesce((p->>'forzar')::boolean, false);
  v_row wh.listas_sombra%rowtype;
begin
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idLista requerido'); end if;
  select * into v_row from wh.listas_sombra where id_lista = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if v_user is not null and coalesce(btrim(v_row.usuario_tomada),'') <> v_user and not v_forzar then
    return jsonb_build_object('ok',false,'error','NO_ES_TUYA','mensaje','Está tomada por: '||coalesce(v_row.usuario_tomada,'')); end if;
  update wh.listas_sombra set estado='DISPONIBLE', usuario_tomada=null, fecha_tomada=null where id_lista = v_id;
  return jsonb_build_object('ok',true);
end;
$fn$;

-- ACTUALIZAR PROGRESO
create or replace function wh.actualizar_progreso_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idLista','')), ''); v_items jsonb := p->'items'; v_n int;
begin
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idLista requerido'); end if;
  if v_items is null or jsonb_typeof(v_items) <> 'array' then return jsonb_build_object('ok',false,'error','items debe ser array'); end if;
  update wh.listas_sombra set items = v_items where id_lista = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

-- ANULAR
create or replace function wh.anular_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idLista','')), ''); v_n int;
begin
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idLista requerido'); end if;
  update wh.listas_sombra set estado='ANULADA', fecha_completada=now() where id_lista = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

-- CERRAR (COMPLETADA + items finales opcionales)
create or replace function wh.cerrar_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idLista','')), ''); v_items jsonb := p->'items'; v_n int;
begin
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idLista requerido'); end if;
  update wh.listas_sombra
     set items = case when v_items is not null and jsonb_typeof(v_items)='array' then v_items else items end,
         estado='COMPLETADA', fecha_completada=now()
   where id_lista = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

insert into mos.config (clave, valor, descripcion) values
  ('WH_LISTA_SOMBRA_DIRECTO','0','WH: escritura directa de listas-sombra (crear/tomar/liberar/progreso/cerrar/anular) a wh.listas_sombra')
on conflict (clave) do nothing;

do $$ begin
  perform 1;
  revoke all on function wh.crear_lista_sombra(jsonb), wh.tomar_lista_sombra(jsonb), wh.liberar_lista_sombra(jsonb),
    wh.actualizar_progreso_lista_sombra(jsonb), wh.anular_lista_sombra(jsonb), wh.cerrar_lista_sombra(jsonb) from public;
  grant execute on function wh.crear_lista_sombra(jsonb), wh.tomar_lista_sombra(jsonb), wh.liberar_lista_sombra(jsonb),
    wh.actualizar_progreso_lista_sombra(jsonb), wh.anular_lista_sombra(jsonb), wh.cerrar_lista_sombra(jsonb) to authenticated;
end $$;
