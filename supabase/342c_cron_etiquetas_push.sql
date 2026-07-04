-- 342c: push best-effort en cron_escalar_etiquetas (#10 noVistas→cajeros, #11 sinPegar→admin). Cero-GAS.
create or replace function mos.cron_escalar_etiquetas()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_res jsonb;
begin
  v_res := mos.escalar_etiquetas_zona();
  insert into mos.cron_log(job, ok, resultado)
    values ('escalar_etiquetas', coalesce((v_res->>'ok')::boolean,false), v_res);
  -- [CERO-GAS push #10/#11] best-effort, NUNCA rompe el cron.
  begin
    if coalesce((v_res->>'noVistas')::int,0) > 0 then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('CAJERO','VENDEDOR')),
        'titulo', '🏷 Etiquetas sin revisar',
        'cuerpo', (v_res->>'noVistas') || ' etiqueta(s) de precio pendientes de imprimir/pegar',
        'data', jsonb_build_object('tipo','etiquetas_sin_revisar')));
    end if;
    if coalesce((v_res->>'sinPegar')::int,0) > 0 then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
        'titulo', '⚠ Zonas sin pegar etiquetas',
        'cuerpo', (v_res->>'sinPegar') || ' zona(s) con etiquetas sin pegar +4h',
        'data', jsonb_build_object('tipo','etiquetas_sin_pegar')));
    end if;
  exception when others then null;
  end;
  return v_res;
exception when others then
  insert into mos.cron_log(job, ok, resultado)
    values ('escalar_etiquetas', false, jsonb_build_object('excepcion', SQLERRM));
  return jsonb_build_object('ok',false,'error','excepcion','detalle',SQLERRM);
end;
$function$;
