-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 596_caja_opener_es_principal.sql — El equipo que ABRE la caja es el PRINCIPAL (amo) de su sesión
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- BUG (latente, detectado en el incidente Mia): `mos.accesos_dispositivos.es_principal` se asignaba por
-- ORDEN de pulso (registrar_ingreso_personal: "no exists principal ACTIVA" → el 1º en registrarse) →
-- podía quedar INVERTIDO (la EXTENSIÓN/celular marcada principal y el equipo real/tablet como esclavo).
-- Ya NO afecta dinero/logout/cierre (594 es device-anchored, 595 usa me.cajas.dispositivo_id), pero SÍ a
-- quién puede emitir el QR de extensión (396) y al ruteo de push → conviene corregirlo.
--
-- FIX: el AMO es, por definición, el equipo que ABRE la caja (la extensión nunca abre — comparte por
-- dedup). Así que al CREAR una caja, promovemos ese equipo a `es_principal` en su sesión y degradamos a
-- los demás. Un solo UPDATE deja EXACTAMENTE 1 principal ACTIVA por sesión → respeta el índice único
-- `ux_accdisp_principal` (WHERE es_principal AND estado='ACTIVA'). Best-effort (jamás rompe la apertura),
-- gateado por flag `MOS_CAJA_OPENER_ES_PRINCIPAL` (default '1'), reversible. La extensión NUNCA llega al
-- paso 3 (retorna en el dedup del paso 2) → nunca se auto-promueve. Base: me.abrir_caja de 594.
-- Verificado tx+ROLLBACK antes de aplicar en prod.
-- ════════════════════════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor, descripcion) values
  ('MOS_CAJA_OPENER_ES_PRINCIPAL','1','El equipo que ABRE la caja se marca es_principal (amo) en su sesión de accesos. Corrige es_principal invertido por orden de pulso. 1=ON, 0=OFF.')
on conflict (clave) do nothing;

create or replace function me.abrir_caja(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app      text := me.jwt_app();
  v_vendedor text := nullif(btrim(coalesce(p->>'vendedor','')), '');
  v_estacion text := coalesce(p->>'estacion','');
  v_zona     text := nullif(btrim(coalesce(p->>'zona','')), '');
  v_monto    numeric := coalesce(nullif(btrim(coalesce(p->>'montoInicial','')),'')::numeric, 0);
  v_pn       text := coalesce(p->>'printNodeId','');
  v_dev      text := coalesce(p->>'deviceId','');
  v_auto     int := 0;
  v_existe   me.cajas%rowtype;
  v_id       text;
  v_hoy      date := (now() at time zone 'America/Lima')::date;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_APERTURA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('status','error','error','APERTURA_DIRECTA_DESACTIVADA');
  end if;
  if v_vendedor is null then return jsonb_build_object('status','error','error','VENDEDOR_REQUERIDO'); end if;
  if v_zona     is null then return jsonb_build_object('status','error','error','ZONA_REQUERIDA'); end if;

  perform pg_advisory_xact_lock(hashtext('me_abrir_caja:'||v_zona));

  -- 1. Auto-cerrar cajas ABIERTAS de días anteriores (TZ Lima) en la zona.
  with vieja as (
    update me.cajas set estado='CERRADA_AUTO', fecha_cierre=now()
     where estado='ABIERTA' and zona_id = v_zona
       and (fecha_apertura at time zone 'America/Lima')::date < v_hoy
    returning 1
  )
  select count(*)::int into v_auto from vieja;

  -- 2. Guard 1-cajero-por-zona (sobre lo que quedó ABIERTA hoy).
  select * into v_existe from me.cajas where zona_id = v_zona and estado = 'ABIERTA' limit 1;
  if found then
    if v_existe.vendedor is not distinct from v_vendedor then
      -- idempotente: el mismo cajero ya abrió (retry / extensión que comparte la caja del amo).
      return jsonb_build_object('status','success','dedup',true,'idCaja',v_existe.id_caja,
        'cajasAutoCerradas',v_auto,'mensaje','Caja ya abierta');
    end if;
    return jsonb_build_object('status','error','error',
      'Ya hay un turno activo en '||v_zona||' (cajero: '||coalesce(v_existe.vendedor,'')||'). Cierra ese turno primero.');
  end if;

  -- [594] GUARD esclavo matado: si este device tiene un acceso CERRADO hoy y NINGÚN acceso ACTIVO
  -- (fue cerrado por el amo/trigger y aún no re-logueó) → NO abre caja propia; debe re-loguearse.
  if v_dev <> '' and exists (
       select 1 from mos.accesos_dispositivos
        where device_id = v_dev and upper(coalesce(estado,'')) = 'CERRADA'
          and (ultima_conexion at time zone 'America/Lima')::date = v_hoy
     ) and not exists (
       select 1 from mos.accesos_dispositivos
        where device_id = v_dev and upper(coalesce(estado,'')) = 'ACTIVA'
          and (ultima_conexion at time zone 'America/Lima')::date = v_hoy
     ) then
    return jsonb_build_object('status','error','error','SESION_CERRADA_RELOGIN',
      'mensaje','Tu sesión fue cerrada por el equipo principal. Vuelve a iniciar sesión.');
  end if;

  -- 3. Crear la caja.
  v_id := 'CAJA-' || (extract(epoch from clock_timestamp())*1000)::bigint;
  insert into me.cajas (id_caja, vendedor, estacion, fecha_apertura, monto_inicial, estado, zona_id, printnode_id, dispositivo_id)
  values (v_id, v_vendedor, v_estacion, now(), v_monto, 'ABIERTA', v_zona, nullif(v_pn,''), nullif(v_dev,''));

  -- [596] El equipo que ABRE la caja es el PRINCIPAL (amo) de su sesión. Corrige es_principal invertido
  -- (que se asignaba por orden de pulso). Un solo UPDATE = exactamente 1 principal ACTIVA por id_dia
  -- (respeta ux_accdisp_principal). La extensión no llega acá (retorna en el dedup del paso 2). Best-effort.
  -- DOS pasos (el índice único NO es deferrable → un solo UPDATE dejaría 2 principales transitorios y
  -- violaría). 1) degradar TODAS las filas ACTIVA de la sesión → 0 principales. 2) promover al que abrió
  -- → 1 principal. Si el paso 2 fallara, el exception revierte AMBOS (no deja la sesión sin principal).
  if coalesce((select valor from mos.config where clave='MOS_CAJA_OPENER_ES_PRINCIPAL' limit 1),'1') = '1'
     and v_dev <> '' then
    begin
      update mos.accesos_dispositivos
         set es_principal = false
       where id_dia in (
               select id_dia from mos.accesos_dispositivos
                where device_id = v_dev and upper(coalesce(estado,'')) = 'ACTIVA')
         and upper(coalesce(estado,'')) = 'ACTIVA';
      update mos.accesos_dispositivos
         set es_principal = true
       where device_id = v_dev and upper(coalesce(estado,'')) = 'ACTIVA'
         and id_dia in (
               select id_dia from mos.accesos_dispositivos
                where device_id = v_dev and upper(coalesce(estado,'')) = 'ACTIVA');
    exception when others then null;  -- nunca romper la apertura de caja
    end;
  end if;

  return jsonb_build_object('status','success','idCaja',v_id,'cajasAutoCerradas',v_auto,
                            'mensaje','Caja aperturada exitosamente');
end;
$fn$;

revoke all on function me.abrir_caja(jsonb) from public;
grant execute on function me.abrir_caja(jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
