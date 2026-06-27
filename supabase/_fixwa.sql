-- FIX tarjeta presentación: me.get_tarjeta_config se llama con anon (sin token) desde ME → faltaba grant a anon.
grant execute on function me.get_tarjeta_config() to anon;
