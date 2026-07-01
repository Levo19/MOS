-- ============================================================================
-- 307_mos_aviso_cajas_cero_gas.sql — Migración cero-GAS del "aviso a cajas" (WH)
-- ----------------------------------------------------------------------------
-- Reemplaza el flujo GAS imprimirAvisoCajeros (que leía MosExpress.CAJAS de la
-- Hoja y mandaba a PrintNode desde Apps Script) por: 1 RPC que junta el
-- preingreso + proveedor + cajas ABIERTAS con su printnode (todo desde Postgres)
-- + reserva idempotente, consumido por la Edge `aviso-cajas` (server-side ESC/POS
-- + PrintNode). 100% Supabase. INERTE hasta prender el flag WH_AVISO_DIRECTO.
-- ============================================================================

-- flag de cutover (default OFF → WH sigue avisando por GAS)
insert into mos.config(clave, valor)
  values ('WH_AVISO_DIRECTO', '0')
  on conflict (clave) do nothing;

-- registro de impresiones de aviso (idempotencia anti doble-print en reintentos)
create table if not exists mos.aviso_impresiones (
  id_preingreso text        not null,
  idem_key      text        not null,
  printers      text        default '',
  ts            timestamptz default now(),
  primary key (id_preingreso, idem_key)
);

-- ¿el caller puede pedir datos de impresión? La Edge llama con service_role;
-- también se permite un token de app WH/MOS (para pruebas/uso directo).
create or replace function mos._aviso_app_ok()
returns boolean language sql stable set search_path = '' as $fn$
  select coalesce(me.jwt_app(),'') in ('warehouseMos','MOS')
      or coalesce((current_setting('request.jwt.claims', true)::jsonb)->>'role','') = 'service_role';
$fn$;
revoke all on function mos._aviso_app_ok() from public;
grant execute on function mos._aviso_app_ok() to authenticated, service_role;

-- RPC única: preingreso + proveedor + cajas-con-printnode + reserva idempotente.
--   p = { idPreingreso, idemKey? }
--   idemKey vacío → NO reserva (paridad con la reimpresión explícita del GAS).
--   idemKey presente y ya usado → yaImpreso:true, cajas:[] (la Edge no imprime).
create or replace function mos.aviso_cajas_data(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id    text := btrim(coalesce(p->>'idPreingreso',''));
  v_idem  text := btrim(coalesce(p->>'idemKey',''));
  v_pi    wh.preingresos%rowtype;
  v_prov  text;
  v_cajas jsonb;
  v_ya    boolean := false;
begin
  if not mos._aviso_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [cutover] INERTE hasta prender el flag → WH cae a GAS mientras esté OFF.
  if coalesce((select valor from mos.config where clave='WH_AVISO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','AVISO_OFF');
  end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','idPreingreso requerido'); end if;
  select * into v_pi from wh.preingresos where id_preingreso = v_id;
  if not found then return jsonb_build_object('ok',false,'error','PREINGRESO_NO_ENCONTRADO'); end if;

  -- reserva idempotente (solo si el caller mandó idemKey)
  if v_idem <> '' then
    insert into mos.aviso_impresiones (id_preingreso, idem_key) values (v_id, v_idem)
      on conflict (id_preingreso, idem_key) do nothing;
    if not found then v_ya := true; end if;
  end if;

  select nombre into v_prov from mos.proveedores where id_proveedor = v_pi.id_proveedor;

  -- cajas ABIERTAS con printnode → una entrada por caja (vendedor/zona para el toast
  -- de la UI). La Edge deduplica por printnode al imprimir. Solo se expone printnode +
  -- vendedor + zona: NUNCA columnas de dinero (monto_inicial/monto_final) de me.cajas.
  select coalesce(jsonb_agg(jsonb_build_object(
           'printnodeId', nullif(btrim(printnode_id),''),
           'vendedor',    coalesce(vendedor,''),
           'zona',        coalesce(zona_id,'')
         ) order by vendedor), '[]'::jsonb)
    into v_cajas
    from me.cajas
   where upper(coalesce(estado,'')) = 'ABIERTA'
     and nullif(btrim(printnode_id),'') is not null;

  return jsonb_build_object(
    'ok', true,
    'yaImpreso', v_ya,
    'preingreso', jsonb_build_object(
      'idPreingreso', v_pi.id_preingreso,
      'proveedor',    coalesce(v_prov, v_pi.id_proveedor, ''),
      'monto',        coalesce(v_pi.monto, 0),
      'cargadores',   coalesce(v_pi.cargadores, '[]'),
      'comentario',   coalesce(v_pi.comentario, ''),
      'fotos',        coalesce(v_pi.fotos, ''),
      'fechaISO',     case when v_pi.fecha is null then '' else to_char(v_pi.fecha at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') end
    ),
    'cajas', case when v_ya then '[]'::jsonb else v_cajas end
  );
end;
$fn$;
revoke all on function mos.aviso_cajas_data(jsonb) from public;
grant execute on function mos.aviso_cajas_data(jsonb) to authenticated, service_role;
