-- 874 · YapeCaptor, auditoría del lado servidor (19-ago). Tres fallas y tres faltantes.
--
-- Probado en transacción con textos reales de Yape, como los manda el APK:
--   1. Un Yape SALIENTE ("Le yapeaste S/ 20.00 a PEDRO") entraba como cobro de S/ 20. El APK
--      lo filtra, pero el servidor es la última defensa y no lo hacía: un APK viejo o una
--      notificación con otro formato metía plata que SALIÓ en la caja.
--   2. El parser dejaba el título pegado al nombre: "Yape Juan Carlos P." (el APK manda
--      título + cuerpo en un solo texto). En la estación se leía "Yape yapeó".
--   3. Una promo sin monto se guardaba como Yape ilegible que nunca va a cuadrar. Ruido en el
--      río y en el cierre. Ahora se descarta con ok:true (el APK la saca de su cola) y no se
--      inserta.
--   A. Revocar un equipo desde Config (hoy solo se puede "regenerar", que es otra cosa).
--   B. El estado expone el ÚLTIMO Yape capturado y la hora: "capturando" sin un ejemplo no
--      dice si el parser está entendiendo lo que llega.
--   C. El aviso de equipo caído se repite cada 2 h mientras siga caído (antes avisaba UNA vez
--      y se callaba hasta que volviera), y avisa también cuando el permiso de notificaciones
--      se pierde (Android lo revoca tras actualizar la app).

begin;

-- ── 1+2+3 · el parser ──────────────────────────────────────────────────────────
create or replace function mos._yape_parse(p_texto text)
returns jsonb
language plpgsql
immutable
set search_path to ''
as $$
declare
  t text := regexp_replace(coalesce(p_texto,''), '[[:space:]]+', ' ', 'g');
  m text[]; v_monto numeric; v_nom text;
begin
  -- SALIENTE: dinero que se fue. No es un cobro, no se parsea.
  if t ~* '(le yapeaste|yapeaste a|enviaste|tu yapeo fue|pago enviado|pagaste a)' then
    return jsonb_build_object('monto', null, 'pagador', null, 'ok', false, 'motivo', 'SALIENTE');
  end if;

  m := regexp_match(t, 'S/\.?[[:space:]]*([0-9]+(?:[.,][0-9]{1,2})?)');
  if m is not null then
    begin v_monto := replace(m[1], ',', '.')::numeric; exception when others then v_monto := null; end;
  end if;
  if v_monto is null or v_monto <= 0 then
    return jsonb_build_object('monto', null, 'pagador', null, 'ok', false, 'motivo', 'SIN_MONTO');
  end if;

  -- "<NOMBRE> te envió / te ha yapeado / te yapeó" — el nombre puede traer puntos (JUAN P.)
  m := regexp_match(t, '([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ. ]{1,60}?)[[:space:]]te[[:space:]](?:envió|envio|ha[[:space:]]yapeado|yapeó|yapeo)');
  if m is not null then v_nom := btrim(m[1]); end if;
  if v_nom is null then
    m := regexp_match(t, '[[:space:]]de[[:space:]]([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ. ]{1,60}?)[[:space:]]*(?:$|[.!¡,]|por[[:space:]]|el[[:space:]]|a[[:space:]]las[[:space:]])');
    if m is not null then v_nom := btrim(m[1]); end if;
  end if;
  if v_nom is not null then
    -- el APK manda "título + cuerpo": el título de Yape ("Yape", "Yape ¡Recibiste un pago!",
    -- "Confirmación de pago") queda pegado al nombre. Se recorta todo lo que venga antes del
    -- último "!" o "¡", y después las palabras del propio Yape.
    v_nom := regexp_replace(v_nom, '^.*[!¡][[:space:]]*', '');
    v_nom := btrim(regexp_replace(v_nom, '^(yape|confirmaci[oó]n de pago|pago recibido|recibiste un pago|recibiste)[[:space:]]+', '', 'i'));
    v_nom := btrim(regexp_replace(v_nom, '^(yape|confirmaci[oó]n de pago|pago recibido|recibiste un pago|recibiste)[[:space:]]+', '', 'i'));
    v_nom := btrim(regexp_replace(v_nom, '^(el|la|los|las|sr\.?|sra\.?)[[:space:]]+', '', 'i'));
    v_nom := btrim(regexp_replace(v_nom, '[[:space:]]*(te|le)$', '', 'i'));
    if length(v_nom) < 2 then v_nom := null; end if;
  end if;

  return jsonb_build_object('monto', v_monto, 'pagador', v_nom, 'ok', true);
end $$;

-- ── la ingesta respeta el veredicto del parser ──────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'yape_ingesta';
  v_new := replace(v_def,
$old$  v_par := mos._yape_parse(v_raw);

  insert into mos.yapes_entrantes$old$,
$new$  v_par := mos._yape_parse(v_raw);
  -- No es un cobro (saliente, promo, sin monto): se responde ok para que el APK lo saque de
  -- su cola, y NO se guarda. Antes entraba como Yape ilegible que nunca iba a cuadrar — o
  -- peor, un envío saliente entraba como plata que llegó.
  if coalesce((v_par->>'ok')::boolean, false) = false then
    update mos.yape_dispositivos set ultima_señal = now() where id = v_dev.id;
    return jsonb_build_object('ok', true, 'descartado', true, 'motivo', coalesce(v_par->>'motivo','NO_ES_COBRO'));
  end if;

  insert into mos.yapes_entrantes$new$);
  if v_new = v_def then raise exception '874: no calzó yape_ingesta'; end if;
  execute v_new;
end $mig$;

-- ── A · revocar un equipo desde Config ─────────────────────────────────────────
create or replace function mos.yape_dispositivo_revocar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_nom text := nullif(btrim(coalesce(p->>'nombre','')),'');
  v_act boolean := coalesce((p->>'activar')::boolean, false);
  v_id bigint;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','nombre requerido'); end if;
  update mos.yape_dispositivos set activo = v_act where nombre = v_nom returning id into v_id;
  if v_id is null then return jsonb_build_object('ok',false,'error','Equipo no encontrado'); end if;
  -- revocar también quema sus códigos vivos
  if not v_act then update mos.yape_codigos set vence_ts = now() where id_dispositivo = v_id and usado_ts is null; end if;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('nombre', v_nom, 'activo', v_act));
end $$;
revoke all on function mos.yape_dispositivo_revocar(jsonb) from public;
grant execute on function mos.yape_dispositivo_revocar(jsonb) to anon, authenticated, service_role;

-- ── B · el estado con el último Yape capturado ──────────────────────────────────
create or replace function mos.yape_dispositivos_estado(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'nombre', d.nombre, 'zona', coalesce(d.zona,''), 'modelo', coalesce(d.modelo,''),
      'activo', d.activo, 'capturas', d.n_capturas, 'pendientes', coalesce(d.pendientes,0),
      'permisoOk', d.permiso_ok,
      'version', coalesce(d.version_name,''), 'versionCode', d.version_code,
      'atrasado', (d.version_code is not null and d.version_code <
                   (select max(x.version_code) from mos.yape_dispositivos x where x.activo)),
      'ultimoLatido', to_char(d.ultimo_latido at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
      'minSinLatir', case when d.ultimo_latido is null then null
                          else round(extract(epoch from (now() - d.ultimo_latido))/60)::int end,
      'estado', case when not d.activo then 'REVOCADO'
                     when d.ultimo_latido is null then 'NUNCA'
                     when d.ultimo_latido > now() - interval '30 minutes' then 'VIVO'
                     else 'CAIDO' end,
      -- el último Yape que entregó: es la prueba de que el parser entiende lo que llega
      'ultimoYape', (select jsonb_build_object('monto', y.monto, 'pagador', coalesce(y.pagador,''), 'estado', y.estado,
                                              'hace', round(extract(epoch from (now() - y.ts_notificacion))/60)::int)
                       from mos.yapes_entrantes y where y.dispositivo = d.nombre order by y.ts_notificacion desc limit 1),
      'hoy', (select count(*) from mos.yapes_entrantes y where y.dispositivo = d.nombre
                 and y.dia = (now() at time zone 'America/Lima')::date)
    ) order by d.activo desc, d.nombre), '[]'::jsonb) into v_out
    from mos.yape_dispositivos d;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('equipos', v_out));
end $$;

-- ── C · el vigilante repite y mira el permiso ───────────────────────────────────
create or replace function mos.cron_yape_vigilar()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare d record; v_hora int; v_n int := 0;
begin
  v_hora := extract(hour from (now() at time zone 'America/Lima'))::int;
  if v_hora < 7 or v_hora >= 22 then return jsonb_build_object('ok',true,'fueraDeHorario',true); end if;

  for d in
    select * from mos.yape_dispositivos
     where activo and ultimo_latido is not null
       and ( ultimo_latido < now() - interval '30 minutes' or permiso_ok = false )
       -- se repite cada 2 h mientras siga mal: un aviso único a las 9 am se olvida a las 11
       and (aviso_caido_ts is null or aviso_caido_ts < now() - interval '2 hours')
  loop
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
        'titulo', case when d.permiso_ok = false and d.ultimo_latido >= now() - interval '30 minutes'
                       then '⛔ YapeCaptor perdió el permiso de notificaciones'
                       else '📴 Un celular dejó de capturar Yapes' end,
        'cuerpo', coalesce(d.nombre,'Equipo') || coalesce(' · ' || d.zona, '') ||
                  case when d.permiso_ok = false and d.ultimo_latido >= now() - interval '30 minutes'
                       then ' está vivo pero Android le quitó el acceso a las notificaciones (pasa al actualizar la app). Hay que volver a activarlo en Ajustes.'
                       else ' lleva ' || round(extract(epoch from (now() - d.ultimo_latido))/60)::int ||
                            ' min sin dar señal. Los pagos por Yape no se están verificando.' end,
        'data', jsonb_build_object('tipo','yape_equipo_caido','equipo',d.nombre)));
      update mos.yape_dispositivos set aviso_caido_ts = now() where id = d.id;
      v_n := v_n + 1;
    exception when others then null; end;
  end loop;
  return jsonb_build_object('ok', true, 'avisados', v_n);
end $$;

commit;

-- el latido ya limpia aviso_caido_ts al volver; con permiso_ok=false no debe limpiarlo (sigue mal)
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'yape_latido';
  v_new := replace(v_def, $old$         aviso_caido_ts = null$old$,
                          $old$         aviso_caido_ts = case when coalesce((p->>'permiso')::boolean, true) then null else aviso_caido_ts end$old$);
  if v_new = v_def then raise exception '874: no calzó yape_latido'; end if;
  execute v_new;
end $mig$;
