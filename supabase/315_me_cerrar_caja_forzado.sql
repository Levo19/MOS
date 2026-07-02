-- ============================================================================
-- 315_me_cerrar_caja_forzado.sql — Cierre FORZADO de caja (admin MOS) cero-GAS
-- ----------------------------------------------------------------------------
-- Replica gas Caja.gs::_cerrarCajaAtomicoCore (esForzado) + la validación de PIN admin
-- de MOS. Es la RPC dedicada que el panel MOS necesitaba (me.cerrar_caja es 'mosExpress'
-- y NO valida PIN; el forzado viene de 'MOS' con clave admin de 8 dígitos).
--   0) valida PIN admin (mos.verificar_clave_admin: global+personal, bcrypt, lockout);
--   1) anula POR_COBRAR de la caja → ANULADO (idsAnulados = "devueltosACredito" legacy);
--   2) montoFinal = auto (inicial + efectivo_ventas + INGRESO − EGRESO), excl INGRESO_VIRTUAL;
--   3) caja → CERRADA + fecha_cierre; cobros ASIGNADO de la caja → CANCELADO_CIERRE_CAJA;
--   4) efectos idempotentes (me.cerrar_caja_efectos): descuento me.stock_zonas + guía
--      SALIDA_VENTAS + pickup WH (MISMO ledger vivo que el cierre GAS de hoy → paridad).
-- Atómico + idempotente (dedup si ya CERRADA; efectos guardan por id_caja/idGuia).
-- Gate jwt_app='MOS' + ME_CIERRE_FORZADO_DIRECTO='1' (flag PROPIO, independiente del cierre
-- del cajero ME; kill-switch; OFF → 'CIERRE_OFF' → GAS).
-- ============================================================================

insert into mos.config(clave, valor) values ('ME_CIERRE_FORZADO_DIRECTO', '0')
  on conflict (clave) do nothing;

-- [315] relajar el gate de efectos para aceptar al forzado MOS (además del cajero mosExpress).
--       Idempotente + solo lee ventas VIVAS de la caja → seguro para ambos orígenes.
create or replace function me.cerrar_caja_efectos(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'id_caja','')), '');
  v_caja  me.cajas%rowtype;
  v_items jsonb; v_idguia text;
  v_rdesc jsonb; v_rmeta jsonb; v_rpick jsonb;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','id_caja requerido'); end if;
  select * into v_caja from me.cajas where id_caja = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','CAJA_NO_ENCONTRADA'); end if;

  select coalesce(jsonb_agg(jsonb_build_object('codBarra', cod, 'cantidad', q)), '[]'::jsonb) into v_items
  from (
    select coalesce(nullif(btrim(d.cod_barras),''), d.sku) as cod, sum(coalesce(d.cantidad,0)) as q
    from me.ventas_detalle d
    join me.ventas v on v.id_venta = d.id_venta
    where v.id_caja = v_id and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
    group by 1 having sum(coalesce(d.cantidad,0)) > 0
  ) t;

  if jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok',true,'vacio',true,'data',jsonb_build_object('idCaja',v_id,'items',0));
  end if;

  v_idguia := 'G-VENTAS-' || v_id;
  v_rdesc := me.zona_descontar_venta(jsonb_build_object(
    'idCaja', v_id, 'zona', coalesce(v_caja.zona_id,''), 'usuario', coalesce(v_caja.vendedor,''),
    'origen', 'CIERRE', 'items', v_items));
  v_rmeta := me.zona_guia_registrar_meta(jsonb_build_object(
    'idGuia', v_idguia, 'zona', coalesce(v_caja.zona_id,''), 'tipo', 'SALIDA_VENTAS',
    'vendedor', coalesce(v_caja.vendedor,''), 'observacion', 'Auto cierre de caja · '||v_id,
    'estado', 'CONFIRMADO', 'items', v_items));
  v_rpick := wh.crear_pickup_desde_ventas(jsonb_build_object(
    'idCaja', v_id, 'idZona', coalesce(v_caja.zona_id,''), 'cajero', coalesce(v_caja.vendedor,''),
    'idGuiaME', v_idguia, 'items', v_items));

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idCaja', v_id, 'idGuia', v_idguia, 'items', jsonb_array_length(v_items),
    'descuentoOk', coalesce((v_rdesc->>'ok')::boolean, false),
    'metaOk', coalesce((v_rmeta->>'ok')::boolean, false),
    'pickupOk', coalesce((v_rpick->>'ok')::boolean, false),
    'pickup', v_rpick->'data'));
end;
$fn$;
revoke all on function me.cerrar_caja_efectos(jsonb) from public;
grant execute on function me.cerrar_caja_efectos(jsonb) to authenticated;


create or replace function me.cerrar_caja_forzado(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idcaja  text := btrim(coalesce(p->>'idCaja', p->>'id_caja', ''));
  v_clave   text := btrim(coalesce(p->>'claveAdmin', p->>'clave', ''));
  v_motivo  text := btrim(coalesce(p->>'motivo',''));
  v_caja    me.cajas%rowtype;
  v_auth    jsonb; v_cerrpor text;
  v_anulados text[]; v_efe numeric; v_ing numeric; v_egr numeric; v_auto numeric;
  v_cobros int := 0; v_efectos jsonb; v_guia boolean := false;
begin
  if coalesce(me.jwt_app(),'') <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- kill-switch: OFF → CIERRE_OFF → _desempacarME null → GAS
  if coalesce((select valor from mos.config where clave='ME_CIERRE_FORZADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','CIERRE_OFF');
  end if;
  if v_idcaja = '' then return jsonb_build_object('ok',false,'error','ID_CAJA_REQUERIDO'); end if;
  if v_clave  = '' then return jsonb_build_object('ok',true,'autorizado',false,'error','Clave requerida'); end if;
  -- serializar cierres concurrentes de la MISMA caja (defensa además de los row-locks + kardex único)
  perform pg_advisory_xact_lock(hashtext('cerrarcaja:'||v_idcaja));

  -- 0) validar PIN admin (global+personal, bcrypt, lockout, auditoría)
  v_auth := mos.verificar_clave_admin(v_clave, 'CIERRE_CAJA_FORZADO', v_idcaja, 'MOS', '',
                                      coalesce(nullif(v_motivo,''),'Cierre forzado desde MOS/Cajas'), null, null);
  if coalesce((v_auth->>'autorizado')::boolean, false) <> true then
    return jsonb_build_object('ok',true,'autorizado',false,'error', coalesce(v_auth->>'error','Clave incorrecta'));
  end if;
  v_cerrpor := coalesce(nullif(v_auth->>'nombre',''), 'admin');

  select * into v_caja from me.cajas where id_caja = v_idcaja limit 1;
  if not found then return jsonb_build_object('ok',false,'error','CAJA_NO_ENCONTRADA'); end if;

  -- idempotencia: ya cerrada → dedup SIN tocar stock. ⚠️ NO re-corremos efectos: una caja ya
  -- cerrada YA tuvo su descuento (por el path directo → guard idempotente, o por GAS legacy → SIN
  -- entrada de guard en el kardex). Re-correr descontaría de nuevo las viejas = doble descuento de
  -- stock. El GAS regeneraba la guía solo si faltaba; ese repair no vale el riesgo de doble stock.
  if v_caja.estado in ('CERRADA','CERRADA_AUTO') then
    return jsonb_build_object('ok',true,'autorizado',true,'yaCerrada',true,'idCaja',v_idcaja,
      'estado',v_caja.estado,'montoFinal',v_caja.monto_final,'cerradoPor',v_cerrpor,
      'printNodeId',v_caja.printnode_id,'estacion',v_caja.estacion,'zona',v_caja.zona_id,
      'guiaRegenerada',false,'devueltosACredito',0,'cobrosLiberados',0);
  end if;
  if v_caja.estado <> 'ABIERTA' then
    return jsonb_build_object('ok',false,'error','CAJA_ESTADO_INVALIDO','estado',v_caja.estado);
  end if;

  -- 1) anular POR_COBRAR de la caja (paridad Caja.gs)
  with anuladas as (
    update me.ventas set forma_pago='ANULADO'
     where id_caja = v_idcaja and upper(coalesce(forma_pago,''))='POR_COBRAR'
    returning id_venta
  )
  select coalesce(array_agg(id_venta), array[]::text[]) into v_anulados from anuladas;

  -- 2) efectivo de ventas NO anuladas (EFECTIVO + parte EFE de MIXTO)
  --    [fix doble-conteo] excluye ventas cobradas vía cobro (asignado/directo): su plata es el INGRESO
  --    'Abono deuda', no el efectivo de la venta (si no, 2x). Ver 27_fase2_cerrar_caja.
  select coalesce(sum(case
           when upper(v.forma_pago)='EFECTIVO' then v.total
           when upper(v.forma_pago) like 'MIXTO%' then coalesce((regexp_match(v.forma_pago,'EFE:([0-9.]+)'))[1]::numeric,0)
           else 0 end),0)
    into v_efe from me.ventas v
   where v.id_caja = v_idcaja
     and not exists (select 1 from me.movimientos_extra m
                      where m.concepto = 'Abono deuda' and position('ticket '||v.id_venta||' ' in coalesce(m.obs,'')) > 0);
  select coalesce(sum(case when tipo='INGRESO' then monto else 0 end),0),
         coalesce(sum(case when tipo='EGRESO'  then monto else 0 end),0)
    into v_ing, v_egr from me.movimientos_extra where id_caja = v_idcaja;
  v_auto := round(coalesce(v_caja.monto_inicial,0) + v_efe + v_ing - v_egr, 2);

  -- 3) cerrar caja + cancelar cobros ASIGNADO de la caja
  update me.cajas set estado='CERRADA', monto_final=v_auto, fecha_cierre=now() where id_caja = v_idcaja;
  update me.creditos_cobro_asignado set estado='CANCELADO_CIERRE_CAJA', fecha_res=now()
   where caja_destino = v_idcaja and estado='ASIGNADO';
  get diagnostics v_cobros = row_count;

  -- 4) efectos idempotentes (stock me.stock_zonas + guía + pickup)
  v_efectos := me.cerrar_caja_efectos(jsonb_build_object('id_caja', v_idcaja));
  v_guia := coalesce((v_efectos->>'ok')::boolean,false) and coalesce((v_efectos->>'vacio')::boolean,false) = false;

  return jsonb_build_object('ok',true,'autorizado',true,'yaCerrada',false,'idCaja',v_idcaja,
    'estado','CERRADA','vendedor',v_caja.vendedor,'estacion',v_caja.estacion,'zona',v_caja.zona_id,
    'printNodeId',v_caja.printnode_id,'montoInicial',v_caja.monto_inicial,
    'efectivoVentas',v_efe,'ingresos',v_ing,'egresos',v_egr,'montoFinal',v_auto,'montoFinalAuto',v_auto,
    'devueltosACredito',coalesce(array_length(v_anulados,1),0),'idsDevueltosACredito',to_jsonb(v_anulados),
    'anulados',coalesce(array_length(v_anulados,1),0),'cobrosLiberados',v_cobros,
    'cerradoPor',v_cerrpor,'guiaRegenerada',v_guia,'efectos',v_efectos->'data',
    'mensaje','Caja cerrada por '||v_cerrpor||' · S/ '||to_char(v_auto,'FM999999990.00'));
end;
$fn$;
revoke all on function me.cerrar_caja_forzado(jsonb) from public;
grant execute on function me.cerrar_caja_forzado(jsonb) to authenticated, service_role;
