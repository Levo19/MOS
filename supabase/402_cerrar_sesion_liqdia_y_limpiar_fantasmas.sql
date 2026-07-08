-- 402 · Al cerrar, marcar la SESIÓN (liquidaciones_dia.estado_sesion) CERRADA + limpiar cajeros-fantasma.
-- Problema: extension_cerrar_cascada marcaba accesos_dispositivos='CERRADA' pero NO tocaba
-- liquidaciones_dia.estado_sesion → quedaba en 'ACTIVA' aunque la caja estuviera CERRADA → usuario fantasma
-- (ej. "caba3": caja CERRADA, sin presencia, pero sesión+accesos ACTIVA). Cero-GAS.

create or replace function mos.extension_cerrar_cascada(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare
  v_iddia text := nullif(btrim(coalesce(p->>'idDia','')),'');
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_dia date; v_n int := 0; rec record;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_iddia is null and v_nombre <> '' then
    begin v_dia := coalesce(nullif(btrim(coalesce(p->>'fecha','')),'')::date, (now() at time zone 'America/Lima')::date);
    exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;
    v_iddia := mos._liqdia_key(mos._identidad_persona(null, v_nombre, v_zona, true), to_char(v_dia,'YYYY-MM-DD'));
  end if;
  if v_iddia is null then return jsonb_build_object('ok',false,'error','idDia o nombre requerido'); end if;
  for rec in select device_id from mos.accesos_dispositivos
             where id_dia = v_iddia and coalesce(es_principal,false) = false and upper(coalesce(estado,'')) = 'ACTIVA'
  loop
    update mos.dispositivos set forzar_logout = true where id_dispositivo = rec.device_id;
    v_n := v_n + 1;
  end loop;
  update mos.accesos_dispositivos set estado='CERRADA' where id_dia = v_iddia and upper(coalesce(estado,''))='ACTIVA';
  -- [402] cerrar también la SESIÓN del día → deja de ser "activa" en cualquier vista que lea liquidaciones_dia.
  update mos.liquidaciones_dia set estado_sesion='CERRADA'
   where id_dia = v_iddia and upper(coalesce(estado_sesion,'')) = 'ACTIVA';
  return jsonb_build_object('ok',true,'extensionesCerradas', v_n);
end; $function$;

-- ── Limpieza one-shot de fantasmas: CAJEROS con sesión/accesos ACTIVA HOY pero SIN caja ABIERTA
--    (un cajero activo SIEMPRE tiene su caja abierta; si no la tiene, la sesión quedó colgada de un cierre
--    previo al fix). No toca vendedores (ellos no tienen caja propia). ──
with fantasmas as (
  select l.id_dia
  from mos.liquidaciones_dia l
  where upper(coalesce(l.estado_sesion,'')) = 'ACTIVA'
    and (l.fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
    and upper(coalesce(l.rol,'')) = 'CAJERO'
    and not exists (
      select 1 from me.cajas k
      where lower(btrim(k.vendedor)) = lower(btrim(l.nombre)) and upper(coalesce(k.estado,'')) = 'ABIERTA'
    )
)
update mos.liquidaciones_dia l set estado_sesion='CERRADA'
from fantasmas f where l.id_dia = f.id_dia;

update mos.accesos_dispositivos a set estado='CERRADA'
where upper(coalesce(a.estado,'')) = 'ACTIVA'
  and exists (
    select 1 from mos.liquidaciones_dia l
    where l.id_dia = a.id_dia
      and upper(coalesce(l.estado_sesion,'')) = 'CERRADA'
      and (l.fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
      and upper(coalesce(l.rol,'')) = 'CAJERO'
  );
