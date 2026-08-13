create or replace function mos.eliminar_jornada(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'idJornada','')), '');
  v_actor text := coalesce(
                    nullif(btrim(coalesce(p->>'actor','')),''),
                    nullif(btrim(coalesce(p->>'registradoPor','')),''),
                    'admin');
  v_now   timestamptz := clock_timestamp();
  v_iso   text;
  v_n     int;
begin
  if coalesce((select valor from mos.config where clave='MOS_JORNADAS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_JORNADAS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idJornada'); end if;

  v_iso := to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');

  update mos.jornadas
     set monto_jornal = 0,
         observacion  = 'VETO_TS:' || v_iso || ' · por ' || v_actor,
         fuente       = 'ELIMINADA'
   where id_jornada = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Jornada no encontrada'); end if;
  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true,'data', jsonb_build_object('vetoTs', v_iso, 'idJornada', v_id));
end;
$fn$;