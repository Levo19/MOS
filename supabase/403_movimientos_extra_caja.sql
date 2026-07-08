-- 403 · Lectura de TODOS los extras (movimientos) de una caja → para que AMBOS equipos (principal +
-- extensión) vean los mismos extras. Antes cada equipo mostraba solo su localStorage local (por eso
-- el cierre sumaba bien -leía el backend- pero la vista no coincidía). Cero-GAS.

create or replace function me.movimientos_extra_caja(p jsonb)
returns jsonb language sql stable security definer set search_path='' as $fn$
  select case
    when coalesce(me.jwt_app(),'') not in ('mosExpress','MOS')
      then jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA')
    when nullif(btrim(coalesce(p->>'idCaja','')),'') is null
      then jsonb_build_object('ok',false,'error','idCaja requerido')
    else jsonb_build_object('ok',true,'data', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',            m.id_extra,
        'tipo',          m.tipo,
        'monto',         m.monto,
        'concepto',      coalesce(m.concepto,''),
        'obs',           coalesce(m.obs,''),
        'registradoPor', coalesce(m.registrado_por,''),
        'dispositivoId', coalesce(m.dispositivo_id,''),
        'timestamp',     (extract(epoch from coalesce(m.ts, m.created_at, now())) * 1000)::bigint
      ) order by coalesce(m.ts, m.created_at) asc)
      from me.movimientos_extra m
      where m.id_caja = btrim(p->>'idCaja')
    ), '[]'::jsonb)) end;
$fn$;

grant execute on function me.movimientos_extra_caja(jsonb) to authenticated, service_role, anon;
