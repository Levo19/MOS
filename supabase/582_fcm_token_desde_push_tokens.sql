-- 582 · [Espía V2 · fix] fcm_token_dispositivo leía mos.dispositivos.fcm_token, que quedó
-- VACÍA tras el cutover cero-GAS (los tokens FCM ahora viven en mos.push_tokens, keyeados
-- por device_id). Por eso el wake push del espía fallaba ("FCM falló · revisá tokens") aunque
-- el dispositivo SÍ tenía token. Fix: leer el token más reciente ACTIVO de push_tokens por
-- device_id; fallback a la columna vieja por si algún device aún la tuviera.
create or replace function mos.fcm_token_dispositivo(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'deviceId', p->>'ID_Dispositivo','')), '');
  v_row mos.dispositivos%rowtype;
  v_tok text;
begin
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  select * into v_row from mos.dispositivos where id_dispositivo = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','NO_REGISTRADO'); end if;

  -- [582] fuente real del token: mos.push_tokens por device_id, el más reciente activo
  select pt.token into v_tok
    from mos.push_tokens pt
   where pt.device_id = v_id
     and coalesce(pt.activo, true)
     and coalesce(nullif(btrim(pt.token),''),'') <> ''
   order by coalesce(pt.ultima_vez, pt.fecha) desc nulls last
   limit 1;
  v_tok := coalesce(nullif(btrim(v_tok),''), nullif(btrim(v_row.fcm_token),''), '');

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'fcmToken', v_tok,
    'estado',   coalesce(v_row.estado,''),
    'app',      coalesce(v_row.app,'')));
end;
$fn$;

revoke all on function mos.fcm_token_dispositivo(jsonb) from public;
grant execute on function mos.fcm_token_dispositivo(jsonb) to authenticated, service_role;
notify pgrst, 'reload schema';
