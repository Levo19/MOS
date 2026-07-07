-- 399 · Fix crear_zona/actualizar_zona: parsear politicaJSON como STRING→jsonb.
-- El front (guardarZona) envía politicaJSON = JSON.stringify({metaDiaria, comisionExcedentePct, metaAuditorias})
-- = un STRING. Las RPCs lo leían con p->'politicaJSON' (esperando un OBJETO jsonb) → habrían guardado un
-- string escapado en politica_json en vez del objeto → meta/comisión/auditoría rotas al leer. Fix:
-- (p->>'politicaJSON')::jsonb (funciona tanto si llega string como objeto). Requisito para el cutover cero-GAS
-- del editor de zonas (metas/comisiones/auditorías) — que hoy cae a GAS.

create or replace function mos.crear_zona(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare
  v_nom text := nullif(btrim(coalesce(p->>'nombre','')),'');
  v_id  text := nullif(btrim(coalesce(p->>'idZona','')),'');
  v_pol jsonb := coalesce(nullif(btrim(coalesce(p->>'politicaJSON','')),'')::jsonb, '{}'::jsonb);
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','nombre requerido'); end if;
  if v_id is null then v_id := 'Z' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS'); end if;
  insert into mos.zonas (id_zona, nombre, descripcion, direccion, responsable, estado, politica_json)
  values (v_id, v_nom, coalesce(p->>'descripcion',''), coalesce(p->>'direccion',''), coalesce(p->>'responsable',''),
    coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, true), v_pol)
  on conflict (id_zona) do nothing;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idZona',v_id));
end; $function$;

create or replace function mos.actualizar_zona(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare
  v_id  text := nullif(btrim(coalesce(p->>'idZona','')),'');
  v_pol jsonb := nullif(btrim(coalesce(p->>'politicaJSON','')),'')::jsonb;   -- null = no tocar
  v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idZona requerido'); end if;
  update mos.zonas set
    nombre       = coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), nombre),
    descripcion  = coalesce(p->>'descripcion', descripcion),
    direccion    = coalesce(p->>'direccion', direccion),
    responsable  = coalesce(p->>'responsable', responsable),
    estado       = coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, estado),
    politica_json= coalesce(v_pol, politica_json)
   where id_zona = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','zona no encontrada'); end if;
  return jsonb_build_object('ok',true);
end; $function$;

grant execute on function mos.crear_zona(jsonb), mos.actualizar_zona(jsonb) to authenticated, service_role;
