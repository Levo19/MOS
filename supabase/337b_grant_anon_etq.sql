-- 337b: grant anon a etiquetas_pendientes + estaciones_lista (DeviceAuth.rpc usa anon key; gate por app ya relajado a mosExpress).
grant execute on function mos.etiquetas_pendientes(jsonb) to anon;
grant execute on function mos.estaciones_lista(jsonb) to anon;
