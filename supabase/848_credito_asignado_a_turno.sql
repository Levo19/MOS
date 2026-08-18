-- 848_credito_asignado_a_turno.sql
--
-- [DUEÑO] "los trabajadores de ME ya pueden tener crédito pero no quiero darles claves. Que el
--  cajero, con el botón ASIGNAR, vea los empleados de HOY de cualquier zona y le dé el crédito a
--  quien vino a trabajar hoy. No debería poder asignar al siguiente día trabajado."
--
-- POR QUÉ NO SE ATA POR DOCUMENTO (la idea que el dueño descartó, con razón):
--   la identidad de un trabajador ME se fabrica con el NOMBRE TECLEADO + la zona
--   (`MEX:MARCELO|ZONA-01`). Si la otra semana entra otro Marcelo a Zona 01, no se *parece* al
--   anterior: ES la misma identidad. Atar un documento a esa identidad convertiría una colisión
--   latente en cobrarle a una persona la deuda de otra. Por eso el vínculo es EXPLÍCITO y, sobre
--   todo, apunta a un TURNO (persona + día), que es único para siempre y es además la unidad que
--   se liquida y se sella como PAGADA.
--
-- EL DOCUMENTO SIGUE VIVO para el personal fijo (Jorgenis, Jesus, Sergio): ahí no hay suposición,
-- la ficha y el documento los verificó el dueño. Por ese camino ya se saldaron 56 tickets.
-- Son dos mecanismos porque son dos tipos de persona. Conviven: un ticket entra a la liquidación
-- si su documento es el de la persona O si fue asignado a uno de sus turnos.
--
-- SE REUSA `mos.creditos_planilla`, que ya tiene la forma exacta (id_venta, id_personal, monto,
-- correlativo, estado) y ya es la que impide el doble descuento. Solo se le agrega el estado
-- ASIGNADO —un paso ANTES del descuento— y a qué turno se cargó.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) La tabla del descuento ahora también guarda la ASIGNACIÓN previa.
--    Una fila ASIGNADA todavía no tiene pago: esos campos pasan a ser opcionales.
-- ─────────────────────────────────────────────────────────────────────────────
alter table mos.creditos_planilla alter column id_pago        drop not null;
alter table mos.creditos_planilla alter column descontado_por drop not null;
alter table mos.creditos_planilla alter column descontado_ts  drop not null;
alter table mos.creditos_planilla alter column descontado_ts  drop default;

alter table mos.creditos_planilla add column if not exists id_dia       text;
alter table mos.creditos_planilla add column if not exists fecha_dia    date;
alter table mos.creditos_planilla add column if not exists asignado_por text;
alter table mos.creditos_planilla add column if not exists asignado_ts  timestamptz;
alter table mos.creditos_planilla add column if not exists nombre_dia   text;

create index if not exists ix_credplan_persona_estado
  on mos.creditos_planilla (id_personal, estado);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) Los TURNOS de un día, para el selector "¿a quién se le da este crédito?".
--    Cualquier zona, cualquier rol, pero SOLO ese día y SOLO turnos abiertos: un día PAGADO o
--    VETADO tiene el monto sellado y no admite un descuento nuevo.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.turnos_del_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_d date; v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  begin v_d := nullif(btrim(coalesce(p->>'fecha','')),'')::date;
  exception when others then v_d := null; end;
  v_d := coalesce(v_d, (now() at time zone 'America/Lima')::date);

  select coalesce(jsonb_agg(x.obj order by x.zona, x.rol, x.nombre), '[]'::jsonb) into v_out
    from (
      select coalesce(nullif(btrim(l.zona),''),'—') zona, upper(coalesce(l.rol,'')) rol, l.nombre,
        jsonb_build_object(
          'idDia',      l.id_dia,
          'idPersonal', l.id_personal,
          'nombre',     coalesce(l.nombre,''),
          'rol',        upper(coalesce(l.rol,'')),
          'zona',       coalesce(l.zona,''),
          'esTemporal', coalesce(l.es_temporal,false),
          'horaIngreso',to_char(l.hora_ingreso at time zone 'America/Lima','HH24:MI'),
          'ventaCobrada', coalesce(l.venta_cobrada,0),
          'pagoDia',    coalesce(l.total_dia,0),
          -- lo que ya se le asignó ese día, para que el cajero lo vea antes de sumar otro
          'yaAsignado', coalesce((select round(sum(cp.monto),2) from mos.creditos_planilla cp
                                   where cp.id_dia = l.id_dia and cp.estado in ('ASIGNADO','DESCONTADO')),0)
        ) obj
      from mos.liquidaciones_dia l
     where (l.fecha at time zone 'America/Lima')::date = v_d
       and upper(coalesce(l.estado,'PENDIENTE')) = 'PENDIENTE'
       and upper(coalesce(l.rol,'')) not in ('MASTER','ADMIN','ADMINISTRADOR')
    ) x;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'fecha', to_char(v_d,'YYYY-MM-DD'), 'n', jsonb_array_length(v_out), 'turnos', v_out));
end $fn$;

grant execute on function mos.turnos_del_dia(jsonb) to anon, authenticated, service_role;

-- espejo en el esquema `me` para que el POS lo llame con su Content-Profile de siempre
create or replace function me.turnos_del_dia(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select mos.turnos_del_dia(p);
$fn$;

grant execute on function me.turnos_del_dia(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) Asignar un ticket de crédito a un turno.
--    Reglas duras (es dinero):
--      · el ticket tiene que estar VIVO en CRÉDITO
--      · un ticket, un solo turno (la PK por id_venta lo garantiza)
--      · si ya fue descontado en una liquidación, no se toca
--      · el turno tiene que estar PENDIENTE (uno PAGADO/VETADO está sellado)
--      · la fecha del turno tiene que ser la MISMA que la del ticket — pedido del dueño:
--        se le da a quien vino a trabajar ESE día, no se arrastra al siguiente
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.credito_asignar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_venta text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_dia   text := nullif(btrim(coalesce(p->>'idDia','')),'');
  v_por   text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'?');
  v_v     record; v_l record; v_prev record;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
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

  select estado, id_personal into v_prev from mos.creditos_planilla where id_venta = v_venta;
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
    'nombre', v_l.nombre, 'rol', v_l.rol, 'zona', v_l.zona, 'monto', v_v.total));
end $fn$;

grant execute on function mos.credito_asignar(jsonb) to anon, authenticated, service_role;

create or replace function me.credito_asignar(p jsonb)
returns jsonb language sql security definer set search_path to '' as $fn$
  select mos.credito_asignar(p);
$fn$;
grant execute on function me.credito_asignar(jsonb) to anon, authenticated, service_role;

-- Quitar la asignación (mientras no se haya descontado).
create or replace function mos.credito_desasignar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_venta text := nullif(btrim(coalesce(p->>'idVenta','')),''); v_est text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_venta is null then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;
  select estado into v_est from mos.creditos_planilla where id_venta = v_venta for update;
  if not found then return jsonb_build_object('ok',true,'data',jsonb_build_object('sinCambio',true)); end if;
  if v_est = 'DESCONTADO' then
    return jsonb_build_object('ok',false,'error','Ya fue descontado en una liquidación — no se puede desasignar');
  end if;
  delete from mos.creditos_planilla where id_venta = v_venta and estado <> 'DESCONTADO';
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idVenta',v_venta));
end $fn$;

grant execute on function mos.credito_desasignar(jsonb) to anon, authenticated, service_role;
create or replace function me.credito_desasignar(p jsonb)
returns jsonb language sql security definer set search_path to '' as $fn$
  select mos.credito_desasignar(p);
$fn$;
grant execute on function me.credito_desasignar(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) La liquidación toma también los tickets ASIGNADOS a los turnos que se pagan.
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text; v_paso text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'marcar_pagos';

  -- (a) los automáticos: documento (como siempre) MÁS los asignados a un turno del período
  v_paso := 'auto';
  v_new := replace(v_def,
$old$      ), '[]'::jsonb);
    end if;
  end if;

  -- [419] VALIDAR + DESCONTAR créditos$old$,
$new$      ), '[]'::jsonb);
    end if;
    -- [848] Y los tickets ASIGNADOS a un turno de esta persona dentro de los días que se pagan.
    -- Es el camino de los trabajadores de ME, que no tienen ficha ni documento: el vínculo lo
    -- puso una persona a mano, ticket por ticket, contra un turno concreto.
    v_creds := v_creds || coalesce((
      select jsonb_agg(to_jsonb(cp.id_venta))
        from mos.creditos_planilla cp
        join me.ventas v on v.id_venta = cp.id_venta
       where cp.id_personal = v_idp and cp.estado = 'ASIGNADO'
         and upper(coalesce(v.forma_pago,'')) = 'CREDITO'
         and cp.fecha_dia::text in (select e->>'fecha' from jsonb_array_elements(v_dias) e)
    ), '[]'::jsonb);
  end if;

  -- [419] VALIDAR + DESCONTAR créditos$new$);
  if v_new = v_def then raise exception '848: no se encontró el bloque de consumos automáticos'; end if;
  v_def := v_new;

  -- (b) ya no se exige documento para descontar: un ticket asignado no lo necesita
  v_paso := 'sin-doc';
  v_new := replace(v_def,
$old$    select btrim(coalesce(documento,'')) into v_docp from mos.personal where id_personal = v_idp;
    if coalesce(v_docp,'') = '' then
      return jsonb_build_object('ok',false,'error','La persona no tiene documento registrado (Personal → documento) — no se pueden descontar créditos');
    end if;$old$,
$new$    -- [848] el documento puede no existir (trabajador de ME sin ficha): ya no se aborta acá.
    -- La pertenencia se decide ticket por ticket más abajo: documento propio O asignación explícita.
    select btrim(coalesce(documento,'')) into v_docp from mos.personal where id_personal = v_idp;$new$);
  if v_new = v_def then raise exception '848: no se encontró la guarda de documento'; end if;
  v_def := v_new;

  -- (c) pertenencia por documento O por asignación
  v_paso := 'pertenencia';
  v_new := replace(v_def,
$old$      if v_vrow.doc <> v_docp then
        return jsonb_build_object('ok',false,'error','El ticket '||coalesce(nullif(v_vrow.correlativo,''),v_vid)||' no pertenece al documento '||v_docp);
      end if;$old$,
$new$      -- [848] es suyo si el documento del ticket es el de su ficha, o si alguien lo ASIGNÓ a un
      -- turno suyo. Sin ninguna de las dos, no se descuenta: nunca se adivina de quién es.
      if not (coalesce(v_docp,'') <> '' and v_vrow.doc = v_docp)
         and not exists (select 1 from mos.creditos_planilla cp
                          where cp.id_venta = v_vid and cp.id_personal = v_idp
                            and cp.estado in ('ASIGNADO','DESCONTADO')) then
        return jsonb_build_object('ok',false,'error','El ticket '||coalesce(nullif(v_vrow.correlativo,''),v_vid)||
          ' no es de esta persona: ni coincide su documento ni fue asignado a uno de sus turnos');
      end if;$new$);
  if v_new = v_def then raise exception '848: no se encontró la validación de documento por ticket'; end if;
  v_def := v_new;

  -- (d) al descontar, conservar la marca del turno al que se había asignado
  v_paso := 'insert';
  v_new := replace(v_def,
$old$        set id_pago = excluded.id_pago, id_personal = excluded.id_personal, monto = excluded.monto,
            correlativo = excluded.correlativo, fecha_venta = excluded.fecha_venta,
            descontado_por = excluded.descontado_por, descontado_ts = now(),
            estado = 'DESCONTADO', revertido_ts = null;$old$,
$new$        set id_pago = excluded.id_pago, id_personal = excluded.id_personal, monto = excluded.monto,
            correlativo = excluded.correlativo, fecha_venta = excluded.fecha_venta,
            descontado_por = excluded.descontado_por, descontado_ts = now(),
            estado = 'DESCONTADO', revertido_ts = null;   -- [848] id_dia/fecha_dia se conservan$new$);
  if v_new = v_def then raise exception '848: no se encontró el upsert de creditos_planilla'; end if;

  execute v_new;
exception when others then
  raise exception '848 marcar_pagos (paso %): %', v_paso, sqlerrm;
end $mig$;

-- el insert "nuevo" de marcar_pagos no fija estado → default explícito para que nunca quede vacío
alter table mos.creditos_planilla alter column estado set default 'DESCONTADO';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) La deuda que MOS muestra de una persona: documento (si tiene ficha) + asignados.
--    Antes fallaba con 'personal no encontrado' para cualquier identidad de ME.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.creditos_personal(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_idp text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_doc text; v_arr jsonb; v_total numeric;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  -- [848] sin ficha ya no es un error: un trabajador de ME existe solo como turno.
  select btrim(coalesce(documento,'')) into v_doc from mos.personal where id_personal = v_idp;
  v_doc := coalesce(v_doc,'');

  select coalesce(jsonb_agg(jsonb_build_object(
           'idVenta', v.id_venta,
           'fecha', to_char((v.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD'),
           'correlativo', coalesce(v.correlativo,''),
           'total', coalesce(v.total,0),
           'via', case when v_doc <> '' and btrim(coalesce(v.cliente_doc,'')) = v_doc
                       then 'documento' else 'asignado' end
         ) order by v.fecha), '[]'::jsonb),
         coalesce(round(sum(coalesce(v.total,0))::numeric,2),0)
    into v_arr, v_total
    from me.ventas v
   where upper(coalesce(v.forma_pago,'')) = 'CREDITO'
     and ( (v_doc <> '' and btrim(coalesce(v.cliente_doc,'')) = v_doc)
        or exists (select 1 from mos.creditos_planilla cp
                    where cp.id_venta = v.id_venta and cp.id_personal = v_idp
                      and cp.estado = 'ASIGNADO') );

  return jsonb_build_object('ok',true,'documento',v_doc,'total',v_total,
    'n', jsonb_array_length(v_arr), 'tickets', v_arr, '_fresh', true);
end $fn$;

grant execute on function mos.creditos_personal(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) El POS puede asignar en el mismo acto de dar el crédito (idDia opcional).
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'me' and p.proname = 'creditar_venta_directo';

  v_new := replace(v_def,
$old$  return jsonb_build_object('ok',true,'via','directo','mensaje','Crédito registrado',
    'idVenta',v_id,'antes',coalesce(v_ant,''));$old$,
$new$  -- [848] El cajero eligió a quién se le da: se asigna en el mismo acto. Si la asignación
  -- falla (turno cerrado, otro día), el crédito YA quedó registrado y se devuelve el motivo:
  -- el ticket existe como deuda, solo queda sin dueño y se asigna después desde MOS.
  if nullif(btrim(coalesce(p->>'idDia','')),'') is not null then
    v_asig := mos.credito_asignar(jsonb_build_object(
      'idVenta', v_id, 'idDia', p->>'idDia', 'usuario', coalesce(v_user,'')));
  end if;

  return jsonb_build_object('ok',true,'via','directo','mensaje','Crédito registrado',
    'idVenta',v_id,'antes',coalesce(v_ant,''),'asignacion',coalesce(v_asig,'null'::jsonb));$new$);
  if v_new = v_def then raise exception '848: no se encontró el return de creditar_venta_directo'; end if;

  v_new := replace(v_new, $old$  v_rvf jsonb;$old$, $old$  v_rvf jsonb;
  v_asig jsonb;$old$);
  execute v_new;
end $mig$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7) Los dos tickets viejos de Marcelo: el dueño los da por cobrados.
--    Se marcan PLANILLA —el estado que ya significa "saldado fuera de caja"— para no inyectar
--    plata fantasma en el efectivo de dos días ya cerrados. Queda el porqué en el historial.
-- ─────────────────────────────────────────────────────────────────────────────
update me.ventas v
   set forma_pago = 'PLANILLA',
       historial_cambios = me._venta_hist_append(v.historial_cambios, jsonb_build_object(
         'ts', to_jsonb(now()), 'usuario', 'Luis', 'rol', 'MASTER',
         'source', 'SQL_848', 'accion', 'dado_por_cobrado',
         'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes','CREDITO','despues','PLANILLA')),
         'motivo', 'Dado por cobrado por el dueño: consumo anterior a la regla de asignación de créditos a trabajadores de ME')),
       updated_at = now()
 where v.id_venta in ('V-1786834414491-6dca31db','V-1786655193879-dc8c28fd')
   and upper(coalesce(v.forma_pago,'')) = 'CREDITO';

commit;
