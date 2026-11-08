-- 1051 · Costos fijos por zona (alquiler, luz, agua, internet…) para el Reporte de zonas.
-- Pedido de Luis 08-nov-2026: botón en reporte-zonas.html para cargarlos con opciones prefijadas y monto;
-- el reporte los prorratea al periodo (hoy / 7 días / 4 semanas) y "Queda" pasa a ser UTILIDAD NETA.
-- zona: 'ZONA-01' | 'ZONA-02' | 'GENERAL' (del negocio, no se carga a una zona; suma solo en TODAS).
-- frecuencia: MES | SEMANA | DIA. Por día: MES × 12 / 365 · SEMANA / 7 · DIA.
-- Historial: nunca se pisa una fila; un cambio cierra la vieja (activo=false, hasta=now) e inserta la nueva.
-- Escritura: solo ADMIN/MASTER (doctrina 724: costos solo desde MOS por admin/master) vía mos._rol_precio_ok.
-- OJO PostgREST (pg_safeupdate): todo UPDATE lleva WHERE.

create table if not exists mos.costos_fijos_zona (
  id            bigserial primary key,
  zona          text not null,
  concepto      text not null,
  monto         numeric(12,2) not null check (monto >= 0),
  frecuencia    text not null default 'MES' check (frecuencia in ('MES','SEMANA','DIA')),
  activo        boolean not null default true,
  desde         timestamptz not null default now(),
  hasta         timestamptz,
  creado_por    text,
  cerrado_por   text
);
create index if not exists ix_cfz_activo on mos.costos_fijos_zona (zona) where activo;
alter table mos.costos_fijos_zona enable row level security;
revoke all on mos.costos_fijos_zona from public, anon, authenticated;

-- lectura: costos activos de todas las zonas
create or replace function mos.costos_fijos_listar(p jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
begin
  if coalesce(me.jwt_app(), '') <> 'MOS' then
    return jsonb_build_object('ok', false, 'error', 'NO_AUTORIZADO');
  end if;
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'zona', c.zona, 'concepto', c.concepto, 'monto', c.monto,
             'frecuencia', c.frecuencia, 'desde', c.desde, 'por', c.creado_por) order by c.zona, c.monto desc)
      from mos.costos_fijos_zona c where c.activo), '[]'::jsonb));
end; $function$;

-- escritura: reemplaza el set activo de UNA zona por p.items (con historial)
create or replace function mos.costos_fijos_guardar(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_usr  text := btrim(coalesce(p->>'usuario', ''));
  v_zona text := upper(btrim(coalesce(p->>'zona', '')));
  v_it   jsonb;
  v_id   bigint;
  v_con  text; v_mon numeric; v_fre text;
  v_keep bigint[] := '{}';
  v_old  record;
  n_ins int := 0; n_cer int := 0;
begin
  if coalesce(me.jwt_app(), '') <> 'MOS' then
    return jsonb_build_object('ok', false, 'error', 'NO_AUTORIZADO');
  end if;
  if v_usr = '' or not mos._rol_precio_ok(v_usr) then
    return jsonb_build_object('ok', false, 'error', 'ROL_NO_AUTORIZADO');
  end if;
  if v_zona <> 'GENERAL' and not exists (select 1 from mos.zonas z where z.id_zona = v_zona and z.id_zona like 'ZONA-%') then
    return jsonb_build_object('ok', false, 'error', 'ZONA_INVALIDA');
  end if;
  if jsonb_typeof(p->'items') <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'ITEMS_INVALIDOS');
  end if;

  for v_it in select * from jsonb_array_elements(p->'items') loop
    v_con := left(btrim(coalesce(v_it->>'concepto', '')), 60);
    v_mon := round(coalesce(nullif(v_it->>'monto', '')::numeric, 0), 2);
    v_fre := upper(coalesce(nullif(v_it->>'frecuencia', ''), 'MES'));
    v_id  := nullif(v_it->>'id', '')::bigint;
    if v_con = '' or v_mon <= 0 or v_fre not in ('MES', 'SEMANA', 'DIA') then continue; end if;
    -- sin cambios → se conserva la fila
    if v_id is not null and exists (select 1 from mos.costos_fijos_zona c
          where c.id = v_id and c.activo and c.zona = v_zona and c.concepto = v_con and c.monto = v_mon and c.frecuencia = v_fre) then
      v_keep := v_keep || v_id;
      continue;
    end if;
    insert into mos.costos_fijos_zona (zona, concepto, monto, frecuencia, creado_por)
      values (v_zona, v_con, v_mon, v_fre, v_usr) returning id into v_id;
    v_keep := v_keep || v_id; n_ins := n_ins + 1;
  end loop;

  -- todo lo activo de la zona que no quedó en la lista se cierra (historial, no se borra)
  for v_old in select c.id from mos.costos_fijos_zona c where c.zona = v_zona and c.activo and not (c.id = any (v_keep)) loop
    update mos.costos_fijos_zona set activo = false, hasta = now(), cerrado_por = v_usr where id = v_old.id;
    n_cer := n_cer + 1;
  end loop;

  return jsonb_build_object('ok', true, 'nuevos', n_ins, 'cerrados', n_cer);
end; $function$;

revoke all on function mos.costos_fijos_listar(jsonb) from public, anon;
revoke all on function mos.costos_fijos_guardar(jsonb) from public, anon;
grant execute on function mos.costos_fijos_listar(jsonb) to authenticated, service_role;
grant execute on function mos.costos_fijos_guardar(jsonb) to authenticated, service_role;
