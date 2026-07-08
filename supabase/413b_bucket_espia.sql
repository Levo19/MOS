-- 413b · Bucket de Storage para los chunks del espía (audio/video/screen). Sin restricción de mime (wh-fotos
-- solo acepta imágenes → daba 415). Público como el Drive del GAS (paths inadivinables deviceId_tipo_ts). 30MB.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('espia','espia', true, 31457280, null)
on conflict (id) do update set public = true, allowed_mime_types = null, file_size_limit = 31457280;
