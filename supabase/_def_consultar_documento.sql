CREATE OR REPLACE FUNCTION fac.consultar_documento(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cfg fac.config%rowtype;
  v_n   text := regexp_replace(coalesce(p->>'numero',''), '\D', '', 'g');
  v_tipo text; v_url text; v_resp text; v_j jsonb; v_nombre text;
begin
  if not fac._app_ok() then return jsonb_build_object('ok',false,'motivo','no_autorizado'); end if;
  select * into v_cfg from fac.config where id = 1;
  if length(v_n) = 8 then v_tipo := '1'; v_url := coalesce(nullif(v_cfg.lookup_url_dni,''), v_cfg.lookup_url_ruc);
  elsif length(v_n) = 11 then v_tipo := '6'; v_url := coalesce(nullif(v_cfg.lookup_url_ruc,''), v_cfg.lookup_url_dni);
  else return jsonb_build_object('ok',false,'motivo','manual'); end if;
  if coalesce(v_url,'') = '' or coalesce(v_cfg.lookup_token,'') = '' then
    return jsonb_build_object('ok',false,'motivo','sin_config'); end if;
  begin
    perform set_config('statement_timeout','15000', true);
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT','12');
    select content into v_resp from extensions.http(('GET', v_url || v_n,
      array[extensions.http_header('Authorization','Bearer '||v_cfg.lookup_token)], NULL, NULL)::extensions.http_request);
    v_j := v_resp::jsonb;
  exception when others then return jsonb_build_object('ok',false,'motivo','no_encontrado'); end;
  v_nombre := coalesce(v_j->>'razonSocial', v_j->>'nombre',
                btrim(concat_ws(' ', v_j->>'nombres', v_j->>'apellidoPaterno', v_j->>'apellidoMaterno')));
  if coalesce(v_nombre,'') = '' then return jsonb_build_object('ok',false,'motivo','no_encontrado'); end if;
  return jsonb_build_object('ok',true,'doc_tipo',v_tipo,'doc_numero',v_n,'nombre',v_nombre,'direccion',coalesce(v_j->>'direccion',''));
end;
$function$
