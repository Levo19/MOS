-- 209_wh_lote_adhesivo_jobunico_tope500.sql
-- job=1 (un solo trabajo, sin trocear) + TOPE 500 etiquetas por impresión.
--   • ADHESIVO_SUB_JOB_SIZE=500 → reservar reclama TODO el lote de una → 1 PrintNode job ("de un tirón").
--   • ADHESIVO_MAX_POR_LOTE=500 → la RPC crear rechaza lotes > 500 (buffer de impresora / seguridad).
-- Conserva intactas las garantías: reserva atómica, dedup por idempotency_key, CHECK completadas<=total.
-- Si se acaba el rollo a mitad: el operador cuenta lo que salió y reimprime el resto con el botón del historial.

insert into mos.config (clave, valor, descripcion) values
  ('ADHESIVO_SUB_JOB_SIZE','500','Etiquetas por sub-job = job unico (todo en 1 trabajo)'),
  ('ADHESIVO_MAX_POR_LOTE','500','Tope maximo de etiquetas por impresion (buffer impresora / seguridad)')
on conflict (clave) do update set valor = excluded.valor;

create or replace function wh.lote_adhesivo_crear(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_cod   text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_total int  := floor(wh._num(p->>'total'))::int;
  v_idem  text := nullif(btrim(coalesce(p->>'idempotencyKey','')), '');
  v_size  int  := floor(wh._num(p->>'subJobSize'))::int;
  v_max   int;
  v_id    text;
  v_row   wh.lotes_adhesivo;
begin
  if coalesce((select valor from mos.config where clave='WH_LOTE_ADHESIVO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LOTE_ADHESIVO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_cod is null then return jsonb_build_object('ok',false,'error','FALTA_codigoBarra'); end if;
  if v_total <= 0 then return jsonb_build_object('ok',false,'error','TOTAL_INVALIDO'); end if;

  -- TOPE máximo por impresión (configurable, default 500).
  v_max := coalesce(floor(wh._num((select valor from mos.config where clave='ADHESIVO_MAX_POR_LOTE' limit 1)))::int, 500);
  if v_max <= 0 then v_max := 500; end if;
  if v_total > v_max then
    return jsonb_build_object('ok',false,'error','TOTAL_EXCEDE_MAX','max',v_max,
      'mensaje','Maximo '||v_max||' por impresion. Dividilo en tandas.');
  end if;

  if v_size is null or v_size <= 0 then
    v_size := coalesce(floor(wh._num((select valor from mos.config where clave='ADHESIVO_SUB_JOB_SIZE' limit 1)))::int, 25);
    if v_size <= 0 then v_size := 25; end if;
  end if;

  if v_idem is not null then
    select * into v_row from wh.lotes_adhesivo where idempotency_key = v_idem limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', wh._lote_adh_json(v_row)); end if;
  end if;

  v_id := 'LA' || (extract(epoch from clock_timestamp())*1000)::bigint
               || '_' || coalesce(v_idem, substr(md5(random()::text),1,6));

  insert into wh.lotes_adhesivo (id_lote, idempotency_key, codigo_barra, descripcion, vto,
    total_etq, completadas, sub_job_size, status, printer_id, tipo_etiqueta, items_json,
    usuario, origen, fecha_creacion, fecha_ultimo_update)
  values (v_id, v_idem, v_cod, coalesce(p->>'descripcion',''), coalesce(p->>'vto',''),
    v_total, 0, v_size, 'ENCOLADO', coalesce(p->>'printerId',''),
    upper(coalesce(p->>'tipoEtiqueta','ADHESIVO_ENVASADO')), p->'itemsJson',
    coalesce(p->>'usuario',''), upper(coalesce(p->>'origen','WH')), now(), now())
  on conflict (idempotency_key) where idempotency_key is not null do nothing
  returning * into v_row;

  if not found then
    select * into v_row from wh.lotes_adhesivo where idempotency_key = v_idem limit 1;
    return jsonb_build_object('ok',true,'dedup',true,'data', wh._lote_adh_json(v_row));
  end if;
  return jsonb_build_object('ok',true,'dedup',false,'data', wh._lote_adh_json(v_row));
end;
$fn$;

revoke all on function wh.lote_adhesivo_crear(jsonb) from public;
grant execute on function wh.lote_adhesivo_crear(jsonb) to service_role, authenticated;
