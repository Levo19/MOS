-- ============================================================================
-- 1009_buzon_ia_rag.sql — Cerebro del buzón (GO del dueño 01-sep-2026)
-- ----------------------------------------------------------------------------
-- El Master quiere que la IA le sugiera respuestas en el Buzón Directo:
--   (a) aprendiendo de SUS respuestas anteriores (cada respuesta enviada se indexa), y
--   (b) con RAG del MANUAL OPERATIVO de MOS/ME/WH (docs/manual_operativo/, corpus curado).
-- Infra: pgvector (768 dims = gemini text-embedding-004). La Edge `buzon-ia` embebe y llama
-- a estas RPCs con SERVICE ROLE (ninguna es alcanzable desde las apps).
-- ============================================================================

create extension if not exists vector with schema extensions;

-- Corpus documental (manual operativo, chunk = sección de markdown)
create table if not exists mos.doc_chunks (
  id         bigint generated always as identity primary key,
  fuente     text not null,             -- ej: manual_mos.md
  seccion    text not null,             -- ej: "Cajas > Cierre forzado"
  contenido  text not null,
  emb        extensions.vector(768),
  updated_at timestamptz not null default now(),
  unique (fuente, seccion)
);
create index if not exists ix_doc_chunks_emb on mos.doc_chunks
  using hnsw (emb extensions.vector_cosine_ops);
alter table mos.doc_chunks enable row level security;
alter table mos.doc_chunks force row level security;

-- Memoria de respuestas del Master (Q = lo que preguntó el admin, A = lo que respondió él)
create table if not exists mos.buzon_qa (
  id_mensaje bigint primary key,        -- mos.buzon_mensajes.id de la respuesta del master
  id_ticket  bigint not null,
  pregunta   text not null,
  respuesta  text not null,
  emb        extensions.vector(768),
  created_at timestamptz not null default now()
);
create index if not exists ix_buzon_qa_emb on mos.buzon_qa
  using hnsw (emb extensions.vector_cosine_ops);
alter table mos.buzon_qa enable row level security;
alter table mos.buzon_qa force row level security;

-- ── RPCs (SOLO service_role: las usa la Edge buzon-ia) ──────────────────────
create or replace function mos.buzon_ia_upsert_doc(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  insert into mos.doc_chunks (fuente, seccion, contenido, emb, updated_at)
  values (btrim(coalesce(p->>'fuente','')), btrim(coalesce(p->>'seccion','')),
          coalesce(p->>'contenido',''), (p->>'emb')::extensions.vector(768), now())
  on conflict (fuente, seccion) do update
    set contenido = excluded.contenido, emb = excluded.emb, updated_at = now();
  return jsonb_build_object('ok', true);
end; $fn$;
revoke all on function mos.buzon_ia_upsert_doc(jsonb) from public, anon, authenticated;
grant execute on function mos.buzon_ia_upsert_doc(jsonb) to service_role;

create or replace function mos.buzon_ia_guardar_qa(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  insert into mos.buzon_qa (id_mensaje, id_ticket, pregunta, respuesta, emb)
  values ((p->>'idMensaje')::bigint, (p->>'idTicket')::bigint,
          coalesce(p->>'pregunta',''), coalesce(p->>'respuesta',''),
          (p->>'emb')::extensions.vector(768))
  on conflict (id_mensaje) do update
    set pregunta = excluded.pregunta, respuesta = excluded.respuesta, emb = excluded.emb;
  return jsonb_build_object('ok', true);
end; $fn$;
revoke all on function mos.buzon_ia_guardar_qa(jsonb) from public, anon, authenticated;
grant execute on function mos.buzon_ia_guardar_qa(jsonb) to service_role;

create or replace function mos.buzon_ia_buscar(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_emb  extensions.vector(768) := (p->>'emb')::extensions.vector(768);
  v_kd   int := least(greatest(coalesce((p->>'kDocs')::int, 4), 0), 8);
  v_kq   int := least(greatest(coalesce((p->>'kQa')::int, 3), 0), 6);
begin
  return jsonb_build_object('ok', true,
    'docs', coalesce((
      select jsonb_agg(jsonb_build_object('fuente', fuente, 'seccion', seccion,
                                          'contenido', contenido, 'sim', round((1 - dist)::numeric, 3)))
      from (select d.fuente, d.seccion, d.contenido, (d.emb operator(extensions.<=>) v_emb) as dist
              from mos.doc_chunks d where d.emb is not null
             order by d.emb operator(extensions.<=>) v_emb limit v_kd) t), '[]'::jsonb),
    'qa', coalesce((
      select jsonb_agg(jsonb_build_object('pregunta', pregunta, 'respuesta', respuesta,
                                          'sim', round((1 - dist)::numeric, 3)))
      from (select q.pregunta, q.respuesta, (q.emb operator(extensions.<=>) v_emb) as dist
              from mos.buzon_qa q where q.emb is not null
             order by q.emb operator(extensions.<=>) v_emb limit v_kq) t), '[]'::jsonb));
end; $fn$;
revoke all on function mos.buzon_ia_buscar(jsonb) from public, anon, authenticated;
grant execute on function mos.buzon_ia_buscar(jsonb) to service_role;
