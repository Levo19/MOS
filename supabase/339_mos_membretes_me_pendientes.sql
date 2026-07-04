-- 339_mos_membretes_me_pendientes.sql
-- [CERO-GAS] Alertas de precio-cambiado para ME (membretes). Reemplaza gas/MembretesAlerts.gs
-- (sheet MEMBRETES_ME_PENDIENTES + hook en publicarPrecio). Tabla + read + 2 writes + hook best-effort
-- en mos.publicar_precio (NUNCA rompe el publish de precio).

create table if not exists mos.membretes_me_pendientes (
  id_alerta          text primary key,
  fecha_cambio       timestamptz not null default now(),
  fecha_ultimo_update timestamptz not null default now(),
  id_producto        text,
  sku_base           text,
  codigo_barra       text,
  descripcion        text,
  precio_anterior    numeric,
  precio_nuevo       numeric,
  usuario            text,
  estado             text not null default 'PENDIENTE',
  fecha_expira       timestamptz,
  fecha_impreso      timestamptz,
  id_lote            text
);
create index if not exists ix_membretes_me_pend_estado on mos.membretes_me_pendientes (estado);

-- READ: {ok, data:{items:[...], count}}. Keys camelCase = HEADERS del GAS. Filtra PENDIENTE (no expiradas).
create or replace function mos.membretes_me_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_limit int := nullif(btrim(coalesce(p->>'limit','')),'')::int;
  v_items jsonb; v_count int;
begin
  if v_claim not in ('mosExpress','MOS','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select count(*) into v_count from mos.membretes_me_pendientes
    where upper(coalesce(estado,''))='PENDIENTE' and (fecha_expira is null or fecha_expira > now());
  select coalesce(jsonb_agg(row order by (row->>'fechaCambio') desc), '[]'::jsonb) into v_items
  from (
    select jsonb_build_object(
      'idAlerta', a.id_alerta,
      'fechaCambio', to_char(a.fecha_cambio at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
      'fechaUltimoUpdate', to_char(a.fecha_ultimo_update at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
      'idProducto', coalesce(a.id_producto,''), 'skuBase', coalesce(a.sku_base,''),
      'codigoBarra', coalesce(a.codigo_barra,''), 'descripcion', coalesce(a.descripcion,''),
      'precioAnterior', coalesce(a.precio_anterior,0), 'precioNuevo', coalesce(a.precio_nuevo,0),
      'usuario', coalesce(a.usuario,''), 'estado', a.estado,
      'fechaExpira', case when a.fecha_expira is null then '' else to_char(a.fecha_expira at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
      'fechaImpreso', case when a.fecha_impreso is null then '' else to_char(a.fecha_impreso at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
      'idLote', coalesce(a.id_lote,'')
    ) as row
    from mos.membretes_me_pendientes a
    where upper(coalesce(a.estado,''))='PENDIENTE' and (a.fecha_expira is null or a.fecha_expira > now())
    order by a.fecha_cambio desc
    limit case when v_limit is not null and v_limit > 0 then v_limit else null end
  ) t;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v_items, 'count', coalesce(v_count,0)));
end;
$fn$;
revoke all on function mos.membretes_me_pendientes(jsonb) from public;
grant execute on function mos.membretes_me_pendientes(jsonb) to anon, authenticated, service_role;

-- WRITE: marcar impreso {idAlertas:[...], idLote}. estado→IMPRESO. Devuelve {ok,actualizados}.
create or replace function mos.marcar_membrete_me_impreso(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_ids text[]; v_n int;
begin
  if v_claim not in ('mosExpress','MOS','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select array_agg(x) into v_ids from jsonb_array_elements_text(coalesce(p->'idAlertas','[]'::jsonb)) x;
  if v_ids is null then return jsonb_build_object('ok',true,'actualizados',0); end if;
  update mos.membretes_me_pendientes
     set estado='IMPRESO', fecha_impreso=now(), fecha_ultimo_update=now(), id_lote=coalesce(nullif(p->>'idLote',''), id_lote)
   where id_alerta = any(v_ids) and upper(coalesce(estado,''))='PENDIENTE';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'actualizados', v_n);
end;
$fn$;
revoke all on function mos.marcar_membrete_me_impreso(jsonb) from public;
grant execute on function mos.marcar_membrete_me_impreso(jsonb) to anon, authenticated, service_role;

-- WRITE: ignorar {idAlertas:[...]}. estado→IGNORADO. Devuelve {ok,actualizados}.
create or replace function mos.ignorar_membrete_me(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_ids text[]; v_n int;
begin
  if v_claim not in ('mosExpress','MOS','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select array_agg(x) into v_ids from jsonb_array_elements_text(coalesce(p->'idAlertas','[]'::jsonb)) x;
  if v_ids is null then return jsonb_build_object('ok',true,'actualizados',0); end if;
  update mos.membretes_me_pendientes set estado='IGNORADO', fecha_ultimo_update=now()
   where id_alerta = any(v_ids) and upper(coalesce(estado,''))='PENDIENTE';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'actualizados', v_n);
end;
$fn$;
revoke all on function mos.ignorar_membrete_me(jsonb) from public;
grant execute on function mos.ignorar_membrete_me(jsonb) to anon, authenticated, service_role;
