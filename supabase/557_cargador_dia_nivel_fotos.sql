-- ════════════════════════════════════════════════════════════════════
-- 557 — Cargadores del día v2: TERMÓMETRO (nivel 0-100) + FOTOS por cargador.
--
-- Pedido del dueño: los cargadores son INDEPENDIENTES del preingreso (ya lo son:
-- viven en wh.cargadores_log). Se cambia el modelo "×count" por UNA fila por
-- (fecha, cargador) con un NIVEL de carga (termómetro, 0-100%) y sus FOTOS.
--
-- id_log DETERMINISTA por (día, cargador) = 'CLGN_'||dia||'_'||idCargador → una
-- sola fila canónica por cargador/día (idempotente, sin duplicar).
-- Gateado con el flag EXISTENTE WH_ADD_CARGADOR_DIA_DIRECTO (ya ON) — sin flag nuevo.
-- ════════════════════════════════════════════════════════════════════

alter table wh.cargadores_log add column if not exists nivel int default 0;
alter table wh.cargadores_log add column if not exists fotos jsonb default '[]'::jsonb;

-- Helper: normaliza fecha param → date (yyyy-MM-dd) en TZ Lima.
create or replace function wh._carg_dia(p_fecha text)
returns date language sql immutable as $$
  select case when p_fecha is not null and left(btrim(p_fecha),10) ~ '^\d{4}-\d{2}-\d{2}$'
              then left(btrim(p_fecha),10)::date
              else (now() at time zone 'America/Lima')::date end;
$$;

-- ── UPSERT: crea (o reusa) la fila canónica del cargador en el día. nivel opcional. ──
create or replace function wh.cargador_dia_upsert(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_idc  text := nullif(btrim(coalesce(p->>'idCargador', p->>'id_cargador','')), '');
  v_nom  text := coalesce(p->>'nombre','');
  v_user text := coalesce(p->>'usuario','');
  v_dev  text := coalesce(p->>'deviceId', p->>'device_id','');
  v_dia  date := wh._carg_dia(p->>'fecha');
  v_niv  int  := case when (p ? 'nivel') then greatest(0, least(100, coalesce((p->>'nivel')::int,0))) else null end;
  v_fecha timestamptz := (v_dia::text || ' 00:00:00')::timestamp at time zone 'America/Lima';
  v_idlog text;
  v_row wh.cargadores_log%rowtype;
begin
  if coalesce((select valor from mos.config where clave='WH_ADD_CARGADOR_DIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ADD_CARGADOR_DIA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idc is null then return jsonb_build_object('ok',false,'error','idCargador requerido'); end if;

  v_idlog := 'CLGN_' || to_char(v_dia,'YYYYMMDD') || '_' || v_idc;
  insert into wh.cargadores_log (id_log, fecha, id_cargador, nombre, added_by, device_id, ts, estado, nivel, fotos)
  values (v_idlog, v_fecha, v_idc, v_nom, v_user, v_dev, now(), 'ACTIVO', coalesce(v_niv,0), '[]'::jsonb)
  on conflict (id_log) do update
    set estado = 'ACTIVO',
        nombre = case when coalesce(excluded.nombre,'') <> '' then excluded.nombre else wh.cargadores_log.nombre end,
        nivel  = coalesce(v_niv, wh.cargadores_log.nivel),
        ts     = now()
  returning * into v_row;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'idLog',v_row.id_log,'idCargador',v_row.id_cargador,'nombre',coalesce(v_row.nombre,''),
    'nivel',coalesce(v_row.nivel,0),'fotos',coalesce(v_row.fotos,'[]'::jsonb),'fecha',to_char(v_dia,'YYYY-MM-DD')));
end; $function$;

-- ── SET NIVEL: mueve el termómetro (0-100). Crea la fila si no existe (robusto). ──
create or replace function wh.cargador_dia_set_nivel(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_idc  text := nullif(btrim(coalesce(p->>'idCargador', p->>'id_cargador','')), '');
  v_dia  date := wh._carg_dia(p->>'fecha');
  v_niv  int  := greatest(0, least(100, coalesce((p->>'nivel')::int,0)));
  v_idlog text;
begin
  if coalesce((select valor from mos.config where clave='WH_ADD_CARGADOR_DIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ADD_CARGADOR_DIA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idc is null then return jsonb_build_object('ok',false,'error','idCargador requerido'); end if;
  v_idlog := 'CLGN_' || to_char(v_dia,'YYYYMMDD') || '_' || v_idc;

  update wh.cargadores_log set nivel = v_niv, ts = now(), estado='ACTIVO'
   where id_log = v_idlog;
  if not found then
    perform wh.cargador_dia_upsert(jsonb_build_object('idCargador',v_idc,'fecha',to_char(v_dia,'YYYY-MM-DD'),
      'nombre',coalesce(p->>'nombre',''),'nivel',v_niv,'usuario',coalesce(p->>'usuario',''),'deviceId',coalesce(p->>'deviceId','')));
  end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idCargador',v_idc,'nivel',v_niv,'fecha',to_char(v_dia,'YYYY-MM-DD')));
end; $function$;

-- ── ADD FOTO: agrega una URL (Storage) al array fotos del cargador del día. ──
create or replace function wh.cargador_dia_add_foto(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_idc  text := nullif(btrim(coalesce(p->>'idCargador', p->>'id_cargador','')), '');
  v_url  text := nullif(btrim(coalesce(p->>'fotoUrl', p->>'foto','')), '');
  v_dia  date := wh._carg_dia(p->>'fecha');
  v_idlog text; v_fotos jsonb;
begin
  if coalesce((select valor from mos.config where clave='WH_ADD_CARGADOR_DIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ADD_CARGADOR_DIA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idc is null or v_url is null then return jsonb_build_object('ok',false,'error','idCargador y fotoUrl requeridos'); end if;
  v_idlog := 'CLGN_' || to_char(v_dia,'YYYYMMDD') || '_' || v_idc;

  -- asegura la fila
  perform wh.cargador_dia_upsert(jsonb_build_object('idCargador',v_idc,'fecha',to_char(v_dia,'YYYY-MM-DD'),
    'nombre',coalesce(p->>'nombre',''),'usuario',coalesce(p->>'usuario',''),'deviceId',coalesce(p->>'deviceId','')));
  update wh.cargadores_log
     set fotos = (coalesce(fotos,'[]'::jsonb) || to_jsonb(v_url)), ts = now()
   where id_log = v_idlog
     and not (coalesce(fotos,'[]'::jsonb) @> to_jsonb(v_url))   -- idempotente: no duplica la misma URL
   returning fotos into v_fotos;
  if v_fotos is null then select fotos into v_fotos from wh.cargadores_log where id_log = v_idlog; end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idCargador',v_idc,'fotos',coalesce(v_fotos,'[]'::jsonb),'fecha',to_char(v_dia,'YYYY-MM-DD')));
end; $function$;

-- ── QUITAR: elimina el cargador del día (todas sus filas ACTIVO). ──
create or replace function wh.cargador_dia_quitar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_idc text := nullif(btrim(coalesce(p->>'idCargador', p->>'id_cargador','')), '');
  v_dia date := wh._carg_dia(p->>'fecha');
begin
  if coalesce((select valor from mos.config where clave='WH_REMOVE_CARGADOR_DIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REMOVE_CARGADOR_DIA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idc is null then return jsonb_build_object('ok',false,'error','idCargador requerido'); end if;
  update wh.cargadores_log set estado='ELIMINADO'
   where id_cargador = v_idc and upper(coalesce(estado,''))='ACTIVO'
     and (fecha at time zone 'America/Lima')::date = v_dia;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idCargador',v_idc,'fecha',to_char(v_dia,'YYYY-MM-DD')));
end; $function$;

-- ── RESUMEN v2: por cargador → nivel + fotos (de la fila más reciente) + count (compat). ──
create or replace function wh.resumen_cargadores_dia(p jsonb DEFAULT '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_dia date := wh._carg_dia(p->>'fecha'); v_cargs jsonb; v_total int;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with activos as (
    select id_cargador,
           max(nombre) filter (where coalesce(nombre,'') <> '') as nombre,
           count(*)::int as cnt,
           (array_agg(nivel order by ts desc nulls last, id_log desc))[1] as nivel,
           (array_agg(coalesce(fotos,'[]'::jsonb) order by ts desc nulls last, id_log desc))[1] as fotos,
           max(ts) as ts
      from wh.cargadores_log
     where upper(coalesce(estado,'')) = 'ACTIVO'
       and (fecha at time zone 'America/Lima')::date = v_dia
     group by id_cargador
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'idCargador', id_cargador, 'nombre', coalesce(nombre,''), 'count', cnt,
           'nivel', coalesce(nivel,0), 'fotos', coalesce(fotos,'[]'::jsonb))
           order by ts desc nulls last, id_cargador), '[]'::jsonb),
         coalesce(count(*),0)::int
    into v_cargs, v_total from activos;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'fecha', to_char(v_dia,'YYYY-MM-DD'), 'total', v_total, 'cargadores', v_cargs));
end; $function$;

grant execute on function wh._carg_dia(text) to anon, authenticated, service_role;
grant execute on function wh.cargador_dia_upsert(jsonb)    to anon, authenticated, service_role;
grant execute on function wh.cargador_dia_set_nivel(jsonb) to anon, authenticated, service_role;
grant execute on function wh.cargador_dia_add_foto(jsonb)  to anon, authenticated, service_role;
grant execute on function wh.cargador_dia_quitar(jsonb)    to anon, authenticated, service_role;
grant execute on function wh.resumen_cargadores_dia(jsonb) to anon, authenticated, service_role;
