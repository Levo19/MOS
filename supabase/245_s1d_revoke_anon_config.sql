-- 245 · S1d — cerrar config_publico anon (LOW: flags/RUC/metas, sin creds). Caller MOS _getObjDirectoMOS
-- (mint, null→GAS), no es boot-anon → revocar es seguro. Completa el set de 240/242/244.
revoke execute on function mos.config_publico(jsonb) from anon;
notify pgrst, 'reload schema';
