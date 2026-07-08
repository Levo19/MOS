-- 413 · Espía: chunks de media (audio/video/screen) → Supabase Storage + metadata. Reemplaza el guardado en
-- Drive de subirChunkAudio/espiaSubirChunk + el listado espiaListarChunks (cero-GAS). El signaling ya estaba
-- migrado (espia_sync/espia_push_batch). NO es dinero — es vigilancia.

create table if not exists mos.espia_chunks (
  id_chunk   text primary key,
  id_sesion  text not null default '',
  device_id  text not null default '',
  tipo       text not null default 'audio',   -- audio | audio_video | screen
  idx        int  not null default 0,
  ts         bigint not null default 0,        -- epoch ms (para el rango del admin)
  url        text not null default '',
  mime       text not null default '',
  tam_bytes  bigint not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists ix_espia_chunks_dev_ts on mos.espia_chunks (device_id, ts desc);
create index if not exists ix_espia_chunks_ses on mos.espia_chunks (id_sesion);
alter table mos.espia_chunks enable row level security;

-- INSERT (lo llama la Edge espia-chunk con service role tras subir a Storage).
create or replace function mos.espia_chunk_registrar(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text;
begin
  if coalesce(me.jwt_app(),'') = '' and coalesce(auth.role(),'') <> 'service_role' then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  v_id := 'EC' || coalesce(nullif(p->>'ts',''), (extract(epoch from clock_timestamp())*1000)::bigint::text) || '_' || coalesce(p->>'idx','0') || '_' || substr(md5(random()::text),1,4);
  insert into mos.espia_chunks (id_chunk, id_sesion, device_id, tipo, idx, ts, url, mime, tam_bytes)
  values (v_id, coalesce(p->>'idSesion',''), coalesce(p->>'deviceId',''), coalesce(nullif(p->>'tipo',''),'audio'),
          coalesce((p->>'idx')::int,0), coalesce((p->>'ts')::bigint,0), coalesce(p->>'url',''),
          coalesce(p->>'mime',''), coalesce((p->>'tamBytes')::bigint,0));
  return jsonb_build_object('ok',true,'idChunk',v_id);
end; $fn$;

-- LISTAR (espiaListarChunks): {deviceId, desde?, hasta?, tipo?} → chunks del rango. Solo admin (claim MOS).
create or replace function mos.espia_listar_chunks(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_dev text := btrim(coalesce(p->>'deviceId',''));
  v_desde bigint := coalesce((p->>'desde')::bigint, (extract(epoch from now())*1000)::bigint - 12*3600000);
  v_hasta bigint := coalesce((p->>'hasta')::bigint, (extract(epoch from now())*1000)::bigint);
  v_tipo text := lower(btrim(coalesce(p->>'tipo','')));
begin
  if coalesce(me.jwt_app(),'') not in ('MOS','mosExpress','warehouseMos') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_dev = '' then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'desde', v_desde, 'hasta', v_hasta,
    'chunks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'fileId', ch.id_chunk, 'nombre', ch.device_id||'_'||ch.tipo||'_'||ch.ts, 'tipo', ch.tipo, 'ts', ch.ts,
        'tamMB', round(ch.tam_bytes/1048576.0, 1), 'url', ch.url, 'mime', ch.mime) order by ch.ts desc)
      from mos.espia_chunks ch
      where ch.device_id = v_dev and ch.ts between v_desde and v_hasta
        and (v_tipo = '' or ch.tipo = v_tipo)
    ), '[]'::jsonb),
    'total', (select count(*) from mos.espia_chunks ch where ch.device_id = v_dev and ch.ts between v_desde and v_hasta and (v_tipo='' or ch.tipo=v_tipo))));
end; $fn$;

grant execute on function mos.espia_chunk_registrar(jsonb) to service_role, authenticated, anon;
grant execute on function mos.espia_listar_chunks(jsonb)   to authenticated, anon, service_role;
