-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 595_me_solo_dueno_cierra_caja.sql — SOLO el equipo DUEÑO (el que abrió la caja) puede cerrarla
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- CAUSA RAÍZ del incidente Mia (2026-07-31): la caja del AMO (tablet) apareció CERRADA aunque Mia jamás
-- la cerró en la tablet. Investigación: NO fue automático (ningún cron cierra cajas a esa hora; los de
-- cierre corren 4am/11pm) ni una actualización. Fue un cierre INTERACTIVO vía me.cerrar_caja (arqueo
-- real, monto_final=250.40). El CELULAR (extensión/esclavo) había perdido su flag `esExtension` → el ME
-- le mostró el botón "cerrar" (que un 2º equipo NO debe tener) → como el celular COMPARTE la caja del
-- amo (dedup en me.abrir_caja), al tocar "cerrar" cerró la caja del AMO. Luego el celular quedó sin caja
-- y abrió una fantasma. => Una EXTENSIÓN pudo cerrar la caja del amo. Eso es lo que se blinda acá.
--
-- FIX (backend, SIN tocar el frontend): el JWT del ME lleva `sub` = deviceId (Edge mint-me). me.cerrar_caja
-- ahora exige que el equipo que llama (sub) sea el DUEÑO de la caja (me.cajas.dispositivo_id = el que la
-- abrió). Un 2º equipo → SOLO_EQUIPO_PRINCIPAL_CIERRA (no cierra nada). Fail-open si falta el sub (cron
-- service_role / token legacy) o si la caja no tiene dispositivo (legacy) → jamás rompe cierres válidos.
-- Reversible por flag ME_SOLO_DUENO_CIERRA (default '1'). Los cierres forzados (315) y 11pm/4am (356) son
-- funciones aparte y corren como service_role (sin sub) → NO afectados.
--
-- Con esto + 594 (amo cierra → esclavo cae al login) el modelo queda simple y cerrado:
--   · SOLO el amo (equipo que abrió) cierra la caja.   · El amo cierra → el esclavo cierra sesión.
--   · El esclavo no cierra la caja del amo, ni abre caja propia (guard de 594 en me.abrir_caja).
-- Verificado tx+ROLLBACK antes de aplicar en prod.
-- ════════════════════════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor, descripcion) values
  ('ME_SOLO_DUENO_CIERRA','1','ME: solo el equipo que ABRIÓ la caja puede cerrarla (bloquea que una extensión cierre la caja del amo). 1=ON, 0=OFF.')
on conflict (clave) do nothing;

create or replace function me.cerrar_caja(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app      text := me.jwt_app();
  v_id       text := nullif(btrim(coalesce(p->>'id_caja','')), '');
  v_estado_f text := coalesce(nullif(p->>'estado_final',''), 'CERRADA');
  v_caja     me.cajas%rowtype;
  v_sub      text := coalesce(me.jwt_sub(),'');   -- [595] deviceId del equipo que llama
  v_ids_anular text[] := case
       when jsonb_typeof(p->'ids_anular') = 'array'
       then array(select jsonb_array_elements_text(p->'ids_anular'))
       else null end;
  v_anulados text[];
  v_efe      numeric := 0;
  v_ing      numeric := 0;
  v_egr      numeric := 0;
  v_auto     numeric;
  v_final    numeric;
  v_cobros   int := 0;
  v_efectos  jsonb := null;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_CIERRE_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('status','error','error','CIERRE_DIRECTO_DESACTIVADO');
  end if;
  if v_id is null then return jsonb_build_object('status','error','error','ID_CAJA_REQUERIDO'); end if;

  perform pg_advisory_xact_lock(hashtext('cerrarcaja:'||v_id));
  select * into v_caja from me.cajas where id_caja = v_id limit 1;
  if not found then return jsonb_build_object('status','error','error','CAJA_NO_ENCONTRADA'); end if;

  -- idempotencia: ya cerrada → dedup (cualquier equipo; un re-tap no molesta)
  if v_caja.estado in ('CERRADA','CERRADA_AUTO') then
    return jsonb_build_object('status','success','dedup',true,'id_caja',v_id,
      'estado',v_caja.estado,'monto_final',v_caja.monto_final,'vendedor',v_caja.vendedor,
      'zona',v_caja.zona_id,'printnode_id',v_caja.printnode_id);
  end if;

  -- [595] SOLO EL EQUIPO DUEÑO (el que abrió la caja) puede cerrarla. Bloquea que una EXTENSIÓN
  -- (que comparte la caja del amo por dedup) cierre la caja del amo. sub del JWT ME = deviceId.
  -- Fail-open: sin sub (cron/service_role) o caja sin dispositivo (legacy) → no bloquea.
  if coalesce((select valor from mos.config where clave='ME_SOLO_DUENO_CIERRA' limit 1),'1') = '1'
     and v_sub <> '' and coalesce(v_caja.dispositivo_id,'') <> ''
     and v_sub <> v_caja.dispositivo_id then
    return jsonb_build_object('status','error','error','SOLO_EQUIPO_PRINCIPAL_CIERRA',
      'mensaje','Solo el equipo que abrió la caja puede cerrarla. Este es un 2º equipo (extensión).');
  end if;

  -- solo una caja ABIERTA puede transicionar a CERRADA
  if v_caja.estado <> 'ABIERTA' then
    return jsonb_build_object('status','error','error','CAJA_ESTADO_INVALIDO','estado',v_caja.estado);
  end if;

  -- ── 2. Anular POR_COBRAR de la caja (o la lista explícita) ──
  with anuladas as (
    update me.ventas
       set forma_pago = 'ANULADO'
     where upper(forma_pago) = 'POR_COBRAR'
       and ( (v_ids_anular is not null and id_venta = any(v_ids_anular))
             or (v_ids_anular is null and id_caja = v_id) )
    returning id_venta
  )
  select array_agg(id_venta) into v_anulados from anuladas;
  v_anulados := coalesce(v_anulados, array[]::text[]);

  -- ── 3. Efectivo de ventas NO anuladas de la caja (EFECTIVO + parte EFE de MIXTO) ──
  with cobradas as (
    select distinct nullif(btrim(substring(m.obs from 'ticket ([^ ]+)')),'') as id_venta
    from me.movimientos_extra m
    where m.concepto = 'Abono deuda' and coalesce(m.obs,'') <> ''
  )
  select coalesce(sum(
    case
      when upper(v.forma_pago) = 'EFECTIVO' then v.total
      when upper(v.forma_pago) like 'MIXTO%' then coalesce((regexp_match(v.forma_pago,'EFE:([0-9.]+)'))[1]::numeric, 0)
      else 0
    end), 0)
  into v_efe
  from me.ventas v
  where v.id_caja = v_id
    and v.id_venta not in (select id_venta from cobradas where id_venta is not null);

  -- ── 4. Ingresos / egresos ──
  select coalesce(sum(case when tipo='INGRESO' then monto else 0 end),0),
         coalesce(sum(case when tipo='EGRESO'  then monto else 0 end),0)
  into v_ing, v_egr
  from me.movimientos_extra where id_caja = v_id;

  -- ── 5. montoFinal: declarado o auto ──
  v_auto := round(coalesce(v_caja.monto_inicial,0) + v_efe + v_ing - v_egr, 2);
  if p ? 'monto_final' and nullif(btrim(coalesce(p->>'monto_final','')),'') is not null then
    v_final := round((p->>'monto_final')::numeric, 2);
  else
    v_final := v_auto;
  end if;

  -- ── 6. Marcar CERRADA ──
  update me.cajas
     set estado = v_estado_f, monto_final = v_final, fecha_cierre = now()
   where id_caja = v_id;

  -- ── 7. Cancelar cobros ASIGNADO de la caja ──
  update me.creditos_cobro_asignado
     set estado = 'CANCELADO_CIERRE_CAJA', fecha_res = now()
   where caja_destino = v_id and estado = 'ASIGNADO';
  get diagnostics v_cobros = row_count;

  -- ── 8. Efectos idempotentes (descuento stock + guía + pickup WH). Best-effort. ──
  begin
    v_efectos := me.cerrar_caja_efectos(jsonb_build_object('id_caja', v_id));
  exception when others then
    v_efectos := jsonb_build_object('ok', false, 'error', SQLERRM);
  end;

  return jsonb_build_object(
    'status','success','dedup',false,'id_caja',v_id,'estado',v_estado_f,
    'vendedor',v_caja.vendedor,'zona',v_caja.zona_id,'printnode_id',v_caja.printnode_id,
    'monto_inicial',v_caja.monto_inicial,'efectivo_ventas',v_efe,'ingresos',v_ing,'egresos',v_egr,
    'monto_final',v_final,'monto_final_auto',v_auto,'descuadre',round(v_final - v_auto, 2),
    'ids_anulados',to_jsonb(v_anulados),'tickets_anulados',array_length(v_anulados,1),
    'cobros_cancelados',v_cobros,'efectos',v_efectos
  );
end;
$fn$;

revoke all on function me.cerrar_caja(jsonb) from public;
grant execute on function me.cerrar_caja(jsonb) to authenticated;

notify pgrst, 'reload schema';
