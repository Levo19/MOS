-- [978] Devolución de zona → AVISA a TODO el almacén (WH) al emitirse (inverso del despacho a zona). Cuando
--  una zona emite una devolución (mos.crear_devolucion_zona → wh.devoluciones_zona EN_TRANSITO), se manda un
--  push a los operadores de warehouseMos: "ZONA-X tiene una devolución, ve a recogerla". El ticket ya se
--  imprime del lado de la zona (ME). NO rompe la devolución si el push falla.
create or replace function mos.crear_devolucion_zona(p jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_id text; v_pl jsonb; v_zona text := coalesce(nullif(btrim(p->>'zonaOrigen'),''),'');
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok',false,'error','Devolución sin items');
  end if;
  v_id := 'DV' || (extract(epoch from clock_timestamp())*1000)::bigint || substr(md5(random()::text),1,4);
  v_pl := jsonb_build_object('items', v_items, 'notaGeneral', coalesce(p->>'notaGeneral',''));
  insert into wh.devoluciones_zona (id_devolucion, fecha_inicio, zona_origen, vendedor,
    id_dispositivo_origen, estado, payload_zona, foto_zona)
  values (v_id, now(), v_zona, coalesce(p->>'vendedor',''),
    coalesce(p->>'idDispositivoOrigen',''), 'EN_TRANSITO', v_pl, coalesce(p->>'fotoZona',''));

  -- [978] AVISO a todo el almacén: hay una devolución por recoger (inverso del despacho a zona).
  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('apps', jsonb_build_array('warehouseMos')),
      'titulo', '↩️ Devolución por recoger',
      'cuerpo', case when v_zona <> '' then upper(v_zona) else 'Una zona' end
                || ' está devolviendo mercadería (' || jsonb_array_length(v_items) || ' producto'
                || case when jsonb_array_length(v_items) = 1 then '' else 's' end
                || '). Ve a recogerla y recíbela en almacén.',
      'data', jsonb_build_object('tipo','wh_devolucion_zona','zona', v_zona, 'idDevolucion', v_id)));
  exception when others then null;   -- jamás romper la devolución por un fallo del aviso
  end;

  return jsonb_build_object('ok',true,'data', jsonb_build_object('idDevolucion', v_id, 'estado','EN_TRANSITO'));
end; $function$;

select '978 devolucion zona avisa WH listo' as ok;
