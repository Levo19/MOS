-- 61_storage_wh_fotos.sql — [PASO 5 · B5] Bucket de Storage para fotos de WH (reemplaza Drive — el SA no tiene quota).
-- Decisión usuario (2026-06-13): fotos a Supabase Storage (100 GB del plan Pro), máxima resolución + previews on-the-fly.
-- Bucket PÚBLICO (lectura por URL, como estaban en Drive con ANYONE_WITH_LINK) — son fotos de inventario, no datos personales.
-- Subir/actualizar/borrar: solo apps con claim warehouseMos (auth.jwt()->>'app'). Límite 15 MB/foto (alta resolución).
-- Organización por path: <tipo>/<id>/<archivo>  (guias/preingresos/mermas/productos/productos-nuevos).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('wh-fotos', 'wh-fotos', true, 15728640, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- RLS en storage.objects, solo para este bucket (no toca otros buckets). Lectura = pública (bucket public=true).
drop policy if exists wh_fotos_insert on storage.objects;
drop policy if exists wh_fotos_update on storage.objects;
drop policy if exists wh_fotos_delete on storage.objects;

create policy wh_fotos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'wh-fotos' and (auth.jwt()->>'app') = 'warehouseMos');
create policy wh_fotos_update on storage.objects for update to authenticated
  using (bucket_id = 'wh-fotos' and (auth.jwt()->>'app') = 'warehouseMos')
  with check (bucket_id = 'wh-fotos' and (auth.jwt()->>'app') = 'warehouseMos');
create policy wh_fotos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'wh-fotos' and (auth.jwt()->>'app') = 'warehouseMos');
