-- 34_wh_crear_guia.sql — [PASO 4 · sesión 4a] Escritura directa: crear guía (solo CABECERA, estado ABIERTA).
-- ⚠️ INERTE: gateada por mos.config.WH_CREAR_GUIA_DIRECTO (default '0').
-- Replica _crearGuiaImpl (Guias.gs): inserta SOLO la cabecera (monto_total=0, estado ABIERTA). El detalle y
-- el stock NO se tocan al crear (eso es cerrar_guia / agregar items). OCR cols = null (guía nueva). Idempotente.

insert into mos.config (clave, valor, descripcion) values
  ('WH_CREAR_GUIA_DIRECTO','0','WH: crear guia directo a Supabase (RPC wh.crear_guia). Validar antes de prender.')
on conflict (clave) do nothing;

create or replace function wh._ts(t text, dflt timestamptz) returns timestamptz language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return dflt; end if;
  return t::timestamptz;
exception when others then return dflt;
end;
$$;

create or replace function wh.crear_guia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_tipo   text := upper(coalesce(p->>'tipo',''));
  v_fecha  timestamptz := wh._ts(p->>'fecha', now());
begin
  if coalesce((select valor from mos.config where clave='WH_CREAR_GUIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CREAR_GUIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_tipo not in ('INGRESO_PROVEEDOR','INGRESO_JEFATURA','INGRESO_ENVASADO','INGRESO_DEVOLUCION_ZONA',
                    'SALIDA_DEVOLUCION','SALIDA_ZONA','SALIDA_JEFATURA','SALIDA_ENVASADO','SALIDA_MERMA') then
    return jsonb_build_object('ok',false,'error','TIPO_INVALIDO','tipo',v_tipo);
  end if;

  -- idempotencia (retry/doble-tap no duplica la guía)
  if exists (select 1 from wh.guias where id_guia = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'id_guia',v_id,'estado',
      (select estado from wh.guias where id_guia = v_id));
  end if;

  insert into wh.guias (id_guia, tipo, fecha, usuario, id_proveedor, id_zona, numero_documento,
    comentario, monto_total, estado, id_preingreso, foto)
  values (v_id, v_tipo, v_fecha, coalesce(p->>'usuario',''), coalesce(p->>'id_proveedor',''),
    coalesce(p->>'id_zona',''), coalesce(p->>'numero_documento',''), coalesce(p->>'comentario',''),
    0, 'ABIERTA', coalesce(p->>'id_preingreso',''), coalesce(p->>'foto',''));

  return jsonb_build_object('ok',true,'dedup',false,'id_guia',v_id,'estado','ABIERTA');
end;
$fn$;

revoke all on function wh.crear_guia(jsonb) from public;
grant execute on function wh.crear_guia(jsonb) to service_role, authenticated;
