-- ════════════════════════════════════════════════════════════════════════════
-- 244 · S1c SEGURIDAD — cerrar el resto de fugas anon (barrido 500x ronda 2)
-- ════════════════════════════════════════════════════════════════════════════
-- Raíz: mos._claim_ok() = me.jwt_app() in ('','MOS') → '' (anon sin JWT) pasa el gate. Toda función
-- secdef + grant anon + gateada solo por _claim_ok es anon-bypassable con la sola anon key. Los apps
-- legítimos minean (mint-mos/mint-me → role authenticated + app), así que revocar anon (dejando
-- authenticated) NO los rompe — mismo patrón verificado en 240/242. Callers auditados (todos minean):
--   personal_dia_lista/series_lista/zonas_lista/categorias_lista/equivalencias_lista/nombres_por_codigos
--     → MOS _getListaDirectaMOS/_sbRpcMOS (mint, null→GAS); actualizar_segmentos_precio → _sbRpcMOSWrite (mint).
--   me.* readers → ME _mintTokenSB (y además NO son secdef → RLS ya bloquea anon; revoke = defensa-en-prof).
-- Qué se cierra: PII de nómina (personal_dia), WRITE anon a tabla de plata (actualizar_segmentos_precio),
-- series SUNAT, metas/comisiones, márgenes, mapa de catálogo, purga destructiva de espía.
-- SE MANTIENEN anon (flujo de login pre-mint): registrar/verificar/consultar_estado_dispositivo,
-- aprobar/revocar (gated por clave bcrypt), get_flags. config_publico se evalúa aparte (posible boot público).
-- ════════════════════════════════════════════════════════════════════════════
revoke execute on function mos.personal_dia_lista(jsonb)          from anon;
revoke execute on function mos.series_lista(jsonb)                from anon;
revoke execute on function mos.actualizar_segmentos_precio(jsonb) from anon;
revoke execute on function mos.zonas_lista(jsonb)                 from anon;
revoke execute on function mos.categorias_lista(jsonb)            from anon;
revoke execute on function mos.equivalencias_lista(jsonb)         from anon;
revoke execute on function mos.nombres_por_codigos(jsonb)         from anon;
revoke execute on function mos.espia_purgar()                     from anon;
revoke execute on function me.get_tarjeta_config()                from anon;
revoke execute on function me.estado_cajas()                      from anon;
revoke execute on function me.creditos_pendientes(integer)        from anon;
revoke execute on function me.cobros_en_vuelo()                   from anon;
revoke execute on function me.ventas_hoy_zona(text, text)         from anon;
notify pgrst, 'reload schema';
