-- 851_asignar_credito_con_clave.sql
--
-- [DUEÑO] "en MOS, una vez asignado te debe pedir clave admin para ser auditado".
--
-- Asignar un consumo mueve dinero: le baja el pago del día a una persona concreta. Desasignar lo
-- devuelve. Las dos cosas pasan a exigir clave y quedan en la auditoría con quién, qué ticket y a
-- qué turno — el mismo camino que ya usan anular un pago o mover un movimiento extra.
--
-- PERO el POS NO pide clave otra vez: el cajero ya puso la clave admin para dar el crédito
-- (CREDITAR_VENTA) y la asignación viaja en ese mismo acto. Pedirla dos veces sería ruido.
-- Para que eso no sea un agujero, la función se parte en dos:
--   · mos._credito_asignar_core(...)  — hace el trabajo. SIN grant a anon: nadie la alcanza desde
--                                        afuera; solo la llama creditar_venta_directo, que ya validó.
--   · mos.credito_asignar(p)          — la puerta pública. EXIGE clave, la valida, audita y recién
--                                        entonces llama al core.
-- Así el atajo no se puede pedir desde el cliente: no existe un flag que saltarse.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) Las dos acciones entran al catálogo de permisos (nivel 2 = admin o master).
-- ─────────────────────────────────────────────────────────────────────────────
insert into mos.permisos_accion (accion, tier, nivel_minimo, label, app) values
  ('ASIGNAR_CREDITO_TRABAJADOR',    2, 2, 'Asignar consumo a un trabajador',  'MOS'),
  ('DESASIGNAR_CREDITO_TRABAJADOR', 2, 2, 'Quitar consumo de un trabajador',  'MOS')
on conflict (accion) do update
  set tier = excluded.tier, nivel_minimo = excluded.nivel_minimo,
      label = excluded.label, app = excluded.app;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) El núcleo: mismas guardas duras de siempre, sin clave (uso interno).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos._credito_asignar_core(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_venta text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_dia   text := nullif(btrim(coalesce(p->>'idDia','')),'');
  v_por   text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'?');
  v_v     record; v_l record; v_prev record;
begin
  if v_venta is null or v_dia is null then
    return jsonb_build_object('ok',false,'error','idVenta e idDia requeridos');
  end if;

  perform pg_advisory_xact_lock(hashtext('credasig:'||v_venta));

  select id_venta, upper(coalesce(forma_pago,'')) fp, coalesce(total,0) total,
         coalesce(correlativo,'') correlativo, fecha
    into v_v from me.ventas where id_venta = v_venta for update;
  if not found then return jsonb_build_object('ok',false,'error','Ticket no encontrado'); end if;
  if v_v.fp <> 'CREDITO' then
    return jsonb_build_object('ok',false,'error','El ticket no está en CRÉDITO (está '||v_v.fp||')');
  end if;

  select id_dia, id_personal, coalesce(nombre,'') nombre, upper(coalesce(rol,'')) rol,
         coalesce(zona,'') zona, upper(coalesce(estado,'PENDIENTE')) estado,
         (fecha at time zone 'America/Lima')::date dia
    into v_l from mos.liquidaciones_dia where id_dia = v_dia;
  if not found then return jsonb_build_object('ok',false,'error','Ese turno no existe'); end if;
  if v_l.estado <> 'PENDIENTE' then
    return jsonb_build_object('ok',false,'error','El turno de '||v_l.nombre||' ya está '||v_l.estado||
      ' — su monto está sellado y no admite un consumo nuevo');
  end if;
  if v_l.dia <> (v_v.fecha at time zone 'America/Lima')::date then
    return jsonb_build_object('ok',false,'error','El ticket es del '||
      to_char((v_v.fecha at time zone 'America/Lima')::date,'DD/MM')||
      ' y ese turno es del '||to_char(v_l.dia,'DD/MM')||' — solo se asigna a quien trabajó ese mismo día');
  end if;

  select estado into v_prev from mos.creditos_planilla where id_venta = v_venta;
  if found and v_prev.estado = 'DESCONTADO' then
    return jsonb_build_object('ok',false,'error','Ese ticket ya fue descontado en una liquidación');
  end if;

  insert into mos.creditos_planilla
    (id_venta, id_personal, monto, correlativo, fecha_venta, estado,
     id_dia, fecha_dia, nombre_dia, asignado_por, asignado_ts)
  values (v_venta, v_l.id_personal, v_v.total, v_v.correlativo, v_v.fecha, 'ASIGNADO',
          v_l.id_dia, v_l.dia, v_l.nombre, v_por, now())
  on conflict (id_venta) do update
    set id_personal = excluded.id_personal, monto = excluded.monto,
        correlativo = excluded.correlativo, fecha_venta = excluded.fecha_venta,
        estado = 'ASIGNADO', id_dia = excluded.id_dia, fecha_dia = excluded.fecha_dia,
        nombre_dia = excluded.nombre_dia, asignado_por = excluded.asignado_por,
        asignado_ts = now(), revertido_ts = null;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'idVenta', v_venta, 'idDia', v_l.id_dia, 'idPersonal', v_l.id_personal,
    'nombre', v_l.nombre, 'rol', v_l.rol, 'zona', v_l.zona, 'monto', v_v.total,
    'asignadoPor', v_por));
end $fn$;

revoke all on function mos._credito_asignar_core(jsonb) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) La puerta pública: clave obligatoria + auditoría, y el nombre real de quien firmó.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.credito_asignar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_venta text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_dia   text := nullif(btrim(coalesce(p->>'idDia','')),'');
  v_val   jsonb; v_nom text; v_det text; v_r jsonb;
begin
  if coalesce(me.jwt_app(),'') not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_venta is null or v_dia is null then
    return jsonb_build_object('ok',false,'error','idVenta e idDia requeridos');
  end if;

  -- detalle legible para la auditoría: se arma ANTES de escribir
  select 'Asignar consumo ' || coalesce(nullif(v.correlativo,''), v.id_venta) ||
         ' (S/ ' || to_char(coalesce(v.total,0),'FM999999990.00') || ') al turno de ' ||
         coalesce(nullif(l.nombre,''),'?') || ' del ' ||
         to_char((l.fecha at time zone 'America/Lima')::date,'DD/MM')
    into v_det
    from me.ventas v left join mos.liquidaciones_dia l on l.id_dia = v_dia
   where v.id_venta = v_venta;

  v_val := mos._validar_clave_admin_core(coalesce(p->>'claveAdmin',''), 'ASIGNAR_CREDITO_TRABAJADOR',
             v_venta, 'MOS', coalesce(p->>'deviceId',''), coalesce(v_det,'Asignar consumo'), null, null);
  if coalesce((v_val->>'autorizado')::boolean, false) <> true then
    return jsonb_build_object('ok',false,'error', coalesce(v_val->>'error','Clave incorrecta'),
      'requiere', v_val->>'requiere');
  end if;
  v_nom := coalesce(nullif(btrim(coalesce(v_val->>'nombre','')),''), nullif(btrim(coalesce(p->>'usuario','')),''), '?');

  v_r := mos._credito_asignar_core(jsonb_build_object('idVenta', v_venta, 'idDia', v_dia, 'usuario', v_nom));
  if coalesce((v_r->>'ok')::boolean,false) then
    v_r := jsonb_set(v_r, '{data,idAccion}', to_jsonb(coalesce(v_val->>'id_accion','')));
  end if;
  return v_r;
end $fn$;

grant execute on function mos.credito_asignar(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) Desasignar también firma: devolverle el consumo a nadie mueve el mismo dinero.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.credito_desasignar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_venta text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_est text; v_nom text; v_monto numeric; v_corr text; v_val jsonb;
begin
  if coalesce(me.jwt_app(),'') not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_venta is null then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;

  select estado, coalesce(nombre_dia,''), coalesce(monto,0), coalesce(correlativo,'')
    into v_est, v_nom, v_monto, v_corr
    from mos.creditos_planilla where id_venta = v_venta;
  if v_est is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('sinCambio',true)); end if;
  if v_est = 'DESCONTADO' then
    return jsonb_build_object('ok',false,'error','Ya fue descontado en una liquidación — no se puede desasignar');
  end if;

  v_val := mos._validar_clave_admin_core(coalesce(p->>'claveAdmin',''), 'DESASIGNAR_CREDITO_TRABAJADOR',
             v_venta, 'MOS', coalesce(p->>'deviceId',''),
             'Quitar consumo ' || coalesce(nullif(v_corr,''), v_venta) ||
             ' (S/ ' || to_char(v_monto,'FM999999990.00') || ') del turno de ' || coalesce(nullif(v_nom,''),'?'),
             null, null);
  if coalesce((v_val->>'autorizado')::boolean, false) <> true then
    return jsonb_build_object('ok',false,'error', coalesce(v_val->>'error','Clave incorrecta'),
      'requiere', v_val->>'requiere');
  end if;

  delete from mos.creditos_planilla where id_venta = v_venta and estado <> 'DESCONTADO';
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'idVenta',v_venta,'nombre',v_nom,'idAccion',coalesce(v_val->>'id_accion','')));
end $fn$;

grant execute on function mos.credito_desasignar(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) El POS entra por el núcleo: su clave ya la validó CREDITAR_VENTA.
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'me' and p.proname = 'creditar_venta_directo';
  v_new := replace(v_def,
    $old$    v_asig := mos.credito_asignar(jsonb_build_object($old$,
    $old$    v_asig := mos._credito_asignar_core(jsonb_build_object($old$);
  if v_new = v_def then raise exception '851: no se encontró la llamada a credito_asignar en el POS'; end if;
  execute v_new;
end $mig$;

commit;
