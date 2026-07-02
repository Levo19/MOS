-- 27_fase2_cerrar_caja.sql — [Camino a cierre-directo · PASO 2: la RPC que ESCRIBE]
-- ⚠️ NACE INERTE: gateada por mos.config.ME_CIERRE_DIRECTO (default '0'). No corre hasta flipear el flag,
-- y SOLO tras validarla contra un cierre real (gate del PASO 1 ya probó que la matemática cuadra al centavo).
-- Replica el NÚCLEO DE DINERO de _cerrarCajaAtomicoCore (Caja.gs), atómico (la función es 1 transacción):
--   1. idempotencia: si la caja ya está CERRADA → dedup (no re-procesa).
--   2. anular POR_COBRAR de la caja (forma_pago → ANULADO) — o la lista idsAnular si viene.
--   3. efectivo_ventas = Σ(EFECTIVO) + Σ(parte EFE de MIXTO) de las ventas NO anuladas de la caja.
--   4. ingresos/egresos de me.movimientos_extra.
--   5. monto_final = declarado (p.monto_final) o auto; descuadre = final - auto.
--   6. marcar caja CERRADA + monto_final + fecha_cierre.
--   7. cancelar cobros ASIGNADO de la caja → CANCELADO_CIERRE_CAJA.
-- Los EFECTOS SECUNDARIOS (guía SALIDA_VENTAS para WH, audit, push) los hace un post-hook GAS (mirrorCierre),
-- que el frontend llama tras el éxito de esta RPC. Fallback: si esta RPC falla, el frontend cae al cierre GAS.

-- seed del flag (default OFF — se prende deliberadamente tras validar)
insert into mos.config (clave, valor, descripcion) values
  ('ME_CIERRE_DIRECTO','0','ME: cierre de caja directo a Supabase (RPC me.cerrar_caja). Validar antes de prender.')
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
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  -- [kill-switch] inerte mientras el flag no esté en '1' (defensa server-side, además del gate del frontend)
  if coalesce((select valor from mos.config where clave='ME_CIERRE_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('status','error','error','CIERRE_DIRECTO_DESACTIVADO');
  end if;
  if v_id is null then return jsonb_build_object('status','error','error','ID_CAJA_REQUERIDO'); end if;

  -- [500x] serializar con los cobros a esta caja (310/314 toman 'cerrarcaja:'||caja) y con el cierre
  -- forzado (315). Sin esto, un cobro podía entrar mientras se cierra, o dos cierres pisarse.
  perform pg_advisory_xact_lock(hashtext('cerrarcaja:'||v_id));
  select * into v_caja from me.cajas where id_caja = v_id limit 1;
  if not found then return jsonb_build_object('status','error','error','CAJA_NO_ENCONTRADA'); end if;

  -- idempotencia: ya cerrada → dedup (no re-anular, no re-calcular)
  if v_caja.estado in ('CERRADA','CERRADA_AUTO') then
    return jsonb_build_object('status','success','dedup',true,'id_caja',v_id,
      'estado',v_caja.estado,'monto_final',v_caja.monto_final,'vendedor',v_caja.vendedor,
      'zona',v_caja.zona_id,'printnode_id',v_caja.printnode_id);
  end if;
  -- [Hardening 50x] solo una caja ABIERTA puede transicionar a CERRADA (defensa ante estados inesperados).
  if v_caja.estado <> 'ABIERTA' then
    return jsonb_build_object('status','error','error','CAJA_ESTADO_INVALIDO','estado',v_caja.estado);
  end if;

  -- ── 2. Anular POR_COBRAR de la caja (o la lista explícita) ──
  -- Si vino ids_anular, anula esos (que estén POR_COBRAR); si no, auto-detecta los POR_COBRAR de la caja.
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
  --    [fix doble-conteo] EXCLUYE las ventas cuya deuda se cobró vía cobro (asignado o directo): su
  --    plata YA está capturada como el movimiento INGRESO 'Abono deuda' (en la caja receptora). El cobro
  --    voltea forma_pago a EFECTIVO, pero la venta NO debe re-sumar acá o se cuenta 2x (venta + INGRESO).
  --    Marcador robusto que cubre AMBAS vías: existe un movimiento 'Abono deuda' que referencia el idVenta.
  --    [perf 100x] set de idVentas cobradas materializado UNA vez (extracción exacta del token tras
  --    'ticket ', igual que 111) → anti-join sargable, no un position() correlacionado por venta.
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

  -- ── 8. [cero-GAS] Efectos idempotentes: descuento me.stock_zonas + guía SALIDA_VENTAS + pickup WH.
  --    Antes esto lo hacía el mirror GAS (CIERRE_CAJA en background). Ahora corre acá → cierre del cajero
  --    cero-GAS. Idempotente por caja (kardex único + guard) → si el mirror GAS aún corre, ve el kardex y
  --    NO re-descuenta. BEST-EFFORT: un fallo de stock NO bloquea el cierre del DINERO (que es lo crítico);
  --    los efectos quedan para reintento idempotente (o el mirror GAS de respaldo).
  begin
    perform me.cerrar_caja_efectos(jsonb_build_object('id_caja', v_id));
  exception when others then null;
  end;

  return jsonb_build_object(
    'status','success','dedup',false,'id_caja',v_id,'estado',v_estado_f,
    'vendedor',v_caja.vendedor,'zona',v_caja.zona_id,'printnode_id',v_caja.printnode_id,
    'monto_inicial',v_caja.monto_inicial,'efectivo_ventas',v_efe,'ingresos',v_ing,'egresos',v_egr,
    'monto_final',v_final,'monto_final_auto',v_auto,'descuadre',round(v_final - v_auto, 2),
    'ids_anulados',to_jsonb(v_anulados),'tickets_anulados',array_length(v_anulados,1),
    'cobros_cancelados',v_cobros
  );
end;
$fn$;

revoke all on function me.cerrar_caja(jsonb) from public;
grant execute on function me.cerrar_caja(jsonb) to authenticated;
