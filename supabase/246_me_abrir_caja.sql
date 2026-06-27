-- ════════════════════════════════════════════════════════════════════════════
-- 246 · REPARACIÓN #1 — me.abrir_caja: apertura de caja 100% Supabase (mata el cold-start de GAS)
-- ════════════════════════════════════════════════════════════════════════════
-- Port fiel de MosExpress/gas/Caja.gs::procesarAperturaCaja, espejando el patrón de me.cerrar_caja:
-- secdef + jwt_app()='mosExpress' + kill-switch por flag + idempotencia + shape {status,...}.
-- La apertura era el único paso de caja todavía 100% GAS (el cierre ya está en me.cerrar_caja);
-- el cold-start de GAS + 2 saltos GAS→Supabase + Sheet + push síncronos eran la causa del "Creando caja" lento.
-- Lógica: lock por-zona (anti-carrera 2 cajeros) → auto-cerrar viejas de la zona → guard 1-cajero-por-zona
-- (idempotente para el MISMO cajero = retry) → insert me.cajas → devuelve idCaja. Push/Sheet ya NO van acá
-- (el front los hace fire-and-forget, fuera del camino crítico). INERTE hasta ME_APERTURA_DIRECTO='1'.
-- ════════════════════════════════════════════════════════════════════════════

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
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  -- kill-switch server-side (además del gate del front). Inerte mientras el flag no esté en '1'.
  if coalesce((select valor from mos.config where clave='ME_APERTURA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('status','error','error','APERTURA_DIRECTA_DESACTIVADA');
  end if;
  if v_vendedor is null then return jsonb_build_object('status','error','error','VENDEDOR_REQUERIDO'); end if;
  if v_zona     is null then return jsonb_build_object('status','error','error','ZONA_REQUERIDA'); end if;

  -- Anti-carrera: serializa aperturas concurrentes de LA MISMA zona (xact lock, se libera al commit).
  perform pg_advisory_xact_lock(hashtext('me_abrir_caja:'||v_zona));

  -- 1. Auto-cerrar cajas ABIERTAS de días anteriores (TZ Lima) en la zona → no bloquean la apertura de hoy.
  with vieja as (
    update me.cajas set estado='CERRADA_AUTO', fecha_cierre=now()
     where estado='ABIERTA' and zona_id = v_zona
       and (fecha_apertura at time zone 'America/Lima')::date < (now() at time zone 'America/Lima')::date
    returning 1
  )
  select count(*)::int into v_auto from vieja;

  -- 2. Guard 1-cajero-por-zona (sobre lo que quedó ABIERTA hoy).
  select * into v_existe from me.cajas where zona_id = v_zona and estado = 'ABIERTA' limit 1;
  if found then
    if v_existe.vendedor is not distinct from v_vendedor then
      -- idempotente: el mismo cajero ya abrió su caja (retry / doble-tap) → devolver la existente (no duplicar).
      return jsonb_build_object('status','success','dedup',true,'idCaja',v_existe.id_caja,
        'cajasAutoCerradas',v_auto,'mensaje','Caja ya abierta');
    end if;
    return jsonb_build_object('status','error','error',
      'Ya hay un turno activo en '||v_zona||' (cajero: '||coalesce(v_existe.vendedor,'')||'). Cierra ese turno primero.');
  end if;

  -- 3. Crear la caja (id con formato GAS: CAJA-<epoch_ms>).
  v_id := 'CAJA-' || (extract(epoch from clock_timestamp())*1000)::bigint;
  insert into me.cajas (id_caja, vendedor, estacion, fecha_apertura, monto_inicial, estado, zona_id, printnode_id, dispositivo_id)
  values (v_id, v_vendedor, v_estacion, now(), v_monto, 'ABIERTA', v_zona, nullif(v_pn,''), nullif(v_dev,''));

  return jsonb_build_object('status','success','idCaja',v_id,'cajasAutoCerradas',v_auto,
                            'mensaje','Caja aperturada exitosamente');
end;
$fn$;

revoke all on function me.abrir_caja(jsonb) from public;
grant execute on function me.abrir_caja(jsonb) to authenticated, service_role;

insert into mos.config (clave, valor, descripcion) values
  ('ME_APERTURA_DIRECTO','0','ME: apertura de caja directa a Supabase (me.abrir_caja) en vez de GAS. 0=GAS, 1=Supabase (con GAS de red).')
on conflict (clave) do nothing;

notify pgrst, 'reload schema';
