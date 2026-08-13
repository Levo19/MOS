create or replace function mos.rehabilitar_jornada(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idJornada','')), '');
  v_actor  text := coalesce(
                     nullif(btrim(coalesce(p->>'actor','')),''),
                     nullif(btrim(coalesce(p->>'registradoPor','')),''),
                     'admin');
  v_now    timestamptz := clock_timestamp();
  v_iso    text;
  v_fuente text;
  v_nombre text;
  v_idpers text;
  v_monto  numeric := mos._numn(p->>'monto');
  v_montoDef numeric := mos._numn(p->>'montoDefault');
  v_final  numeric;
  v_n      int;
begin
  if coalesce((select valor from mos.config where clave='MOS_JORNADAS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_JORNADAS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idJornada'); end if;

  select upper(coalesce(fuente,'')), coalesce(nombre,''), coalesce(id_personal,'')
    into v_fuente, v_nombre, v_idpers
    from mos.jornadas
   where id_jornada = v_id
   for update;

  if not found then return jsonb_build_object('ok',false,'error','Jornada no encontrada'); end if;
  if v_fuente <> 'ELIMINADA' then return jsonb_build_object('ok',false,'error','La jornada no está vetada'); end if;

  v_final := case when v_monto is not null and v_monto > 0 then v_monto else null end;
  if v_final is null then
    select monto_base into v_final
      from mos.personal
     where (nullif(v_idpers,'') is not null and id_personal = v_idpers)
        or (lower(coalesce(nombre,'')) = lower(v_nombre))
     order by (nullif(v_idpers,'') is not null and id_personal = v_idpers) desc
     limit 1;
    if v_final is null or v_final <= 0 then v_final := null; end if;
  end if;
  if v_final is null then
    v_final := case when v_montoDef is not null and v_montoDef > 0 then v_montoDef else 0 end;
  end if;

  v_iso := to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');

  update mos.jornadas
     set monto_jornal = v_final,
         observacion  = 'REHAB_TS:' || v_iso || ' · por ' || v_actor,
         fuente       = 'MANUAL'
   where id_jornada = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Jornada no encontrada'); end if;
  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true,'data', jsonb_build_object('rehabTs', v_iso, 'idJornada', v_id, 'monto', v_final));
end;
$fn$;