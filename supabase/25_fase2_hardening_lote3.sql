-- 25_fase2_hardening_lote3.sql — [Lote3-B · fixes A3+A6+M1 de la revisión 2026-06-12]
-- Endurecimientos de bajo riesgo sobre RPC ya en producción. Todos preservan el comportamiento
-- legítimo (el caller normal pasa parámetros dentro de los límites nuevos) y solo cierran abusos.

-- ════════════════════════════════════════════════════════════════════
-- A3: ventas_hoy_zona_auth — cap server-side del rango temporal.
-- Antes `desde_str` lo ponía el cliente sin tope → un token de 5min podía pedir
-- desde='2000-01-01' y descargar TODO el historial de ventas (PII de clientes).
-- El uso legítimo es "ventas de la sesión de HOY"; un piso de 2 días cubre sesiones
-- que cruzan medianoche. fail-closed: prefijos vacíos siguen devolviendo 0 filas.
-- ════════════════════════════════════════════════════════════════════
create or replace function me.ventas_hoy_zona_auth(prefijos_str text default null, desde_str text default null)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with guard as (select me.jwt_app() = 'mosExpress' as ok),  -- fail-closed: solo tokens de ME
  params as (
    select
      -- [Lote3-B · A3] piso duro: desde NO puede ser anterior a hace 2 días (Lima),
      -- aunque el cliente pida una fecha más vieja. greatest(pedido, piso).
      greatest(
        case when desde_str is not null and btrim(desde_str)<>'' then btrim(desde_str)::timestamptz
             else (now() at time zone 'America/Lima')::date::timestamptz end,
        ((now() at time zone 'America/Lima')::date - 2)::timestamptz
      ) as desde,
      case when prefijos_str is not null and btrim(prefijos_str)<>''
           then array(select replace(replace(btrim(p),'%','\%'),'_','\_') || '%' from unnest(string_to_array(prefijos_str, ',')) p)
           else null end as pref_like
  ),
  filt as (
    select v.*
    from me.ventas v, params p, guard g
    where g.ok
      and v.fecha >= p.desde
      -- [scope-ALTO] fail-closed: prefijos vacíos/null ⇒ 0 filas.
      and p.pref_like is not null and coalesce(v.correlativo,'') like any (p.pref_like)
  )
  select jsonb_build_object(
    'status','success',
    'ventas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id_venta', id_venta,
        'fecha', case when fecha is not null then to_char(fecha at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
        'vendedor', coalesce(vendedor,''),
        'cliente_doc', coalesce(cliente_doc,''),
        'cliente_nombre', coalesce(cliente_nombre,''),
        'total', coalesce(total,0),
        'tipo_doc', coalesce(tipo_doc,''),
        'forma_pago', coalesce(forma_pago,''),
        'correlativo', coalesce(correlativo,''),
        'id_caja', coalesce(id_caja,''),
        'status', coalesce(estado_envio,''),
        'ref_local', coalesce(ref_local,''),
        'obs', coalesce(obs,'')
      ) order by fecha)
      from filt), '[]'::jsonb)
  );
$fn$;
revoke all on function me.ventas_hoy_zona_auth(text, text) from public;
grant execute on function me.ventas_hoy_zona_auth(text, text) to authenticated;

-- ════════════════════════════════════════════════════════════════════
-- A6: crear_movimiento_directo — validar monto > 0 y tipo en whitelist.
-- Antes: un EGRESO con monto negativo inflaba el efectivo esperado; un `tipo`
-- con typo lo sacaba de los buckets INGRESO/EGRESO del cierre (desaparecía).
-- ════════════════════════════════════════════════════════════════════
create or replace function me.crear_movimiento_directo(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app     text := me.jwt_app();
  v_id      text := nullif(btrim(coalesce(p->>'id_extra','')), '');
  v_caja    text := coalesce(p->>'id_caja','');
  v_tipo    text := upper(coalesce(p->>'tipo','EGRESO'));
  v_monto   numeric := coalesce((p->>'monto')::numeric, 0);
  v_caja_ok boolean;
  v_ins     int;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if v_id  is null         then return jsonb_build_object('status','error','error','ID_EXTRA_REQUERIDO'); end if;

  -- idempotencia PRIMERO (reintento): no re-validar la caja (ya se validó al registrar)
  perform 1 from me.movimientos_extra where id_extra = v_id;
  if found then return jsonb_build_object('status','success','id_extra',v_id,'dedup',true); end if;

  -- [Lote3-B · A6] validaciones de integridad (después de idempotencia, antes de validar caja)
  if v_monto <= 0 then return jsonb_build_object('status','error','error','MONTO_INVALIDO'); end if;
  if v_tipo not in ('INGRESO','EGRESO','INGRESO_VIRTUAL','EGRESO_VIRTUAL') then
    return jsonb_build_object('status','error','error','TIPO_INVALIDO');
  end if;

  -- caja debe estar ABIERTA para un movimiento NUEVO
  select (estado = 'ABIERTA') into v_caja_ok from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA'); end if;

  insert into me.movimientos_extra (id_extra, id_caja, ts, tipo, monto, concepto, obs, registrado_por,
                                    zona_id, dispositivo_id)
  values (v_id, v_caja, now(), v_tipo,
          v_monto, coalesce(p->>'concepto',''), coalesce(p->>'obs',''),
          coalesce(p->>'registrado_por',''), coalesce(p->>'zona_id',''), coalesce(p->>'dispositivo_id',''))
  on conflict (id_extra) do nothing;
  get diagnostics v_ins = row_count;

  return jsonb_build_object('status','success','id_extra',v_id,'dedup', v_ins = 0);
end;
$fn$;
revoke all on function me.crear_movimiento_directo(jsonb) from public;
grant execute on function me.crear_movimiento_directo(jsonb) to authenticated;

-- ════════════════════════════════════════════════════════════════════
-- M1: get_flags / get_tarjeta_config — whitelist EXACTA de claves (no prefijo).
-- Antes `like 'ME\_%'` / `like 'TARJETA\_%'` exponían a anon cualquier clave futura
-- con ese prefijo (ej. un hipotético ME_WEBHOOK_SECRET). Hoy no hay nada sensible,
-- pero el whitelist por nombre exacto es defensa preventiva.
-- ════════════════════════════════════════════════════════════════════
create or replace function me.get_flags()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb)
  from mos.config
  where clave in ('ME_ESCRITURA_DIRECTA','ME_LECTURA_DIRECTA','ME_IMPRESION_DIRECTA','ME_CPE_DIRECTO');
$fn$;
revoke all on function me.get_flags() from public;
grant execute on function me.get_flags() to anon, authenticated;

create or replace function me.get_tarjeta_config()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb)
  from mos.config
  where clave in ('TARJETA_WA_COMERCIAL','TARJETA_WA_COMPRAS','TARJETA_MARCA');
$fn$;
revoke all on function me.get_tarjeta_config() from public;
grant execute on function me.get_tarjeta_config() to anon, authenticated;
