-- 87_wh_fotos_select_policy.sql — Policy SELECT faltante para el bucket wh-fotos en storage.objects.
-- CONTEXTO: 61_storage_wh_fotos.sql creó INSERT/UPDATE/DELETE para `authenticated` con claim app='warehouseMos',
-- pero NO una SELECT. Consecuencias: (1) DELETE de foto fallaba con RLS (DELETE evalúa la fila → necesita SELECT
-- → "403 Access denied"); (2) el endpoint list de Storage devolvía [] (no veía objetos propios).
-- El bucket YA es público (public=true → lectura por URL anónima), así que esta SELECT policy NO expone nada nuevo:
-- solo permite que el propio token WH (claim warehouseMos) lea/liste/borre sus objetos. Patrón idéntico a las otras.
drop policy if exists wh_fotos_select on storage.objects;

create policy wh_fotos_select on storage.objects for select to authenticated
  using (bucket_id = 'wh-fotos' and (auth.jwt()->>'app') = 'warehouseMos');
