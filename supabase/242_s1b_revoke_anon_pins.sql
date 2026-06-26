-- ════════════════════════════════════════════════════════════════════════════
-- 242 · S1b SEGURIDAD — cerrar fuga de PINs anon (hermana de 240/catalogo_pos_rls)
-- ════════════════════════════════════════════════════════════════════════════
-- La revisión 500x encontró que el fix de 240 (catalogo_pos_rls) NO cubría sus hermanas:
--   • mos.personal_master_lista → devolvía PINs de TRABAJADORES con solo la anon key
--   • mos.estaciones_lista({incluirPin:true}) → devolvía Admin_PINs de estaciones
--   • mos.impresoras_lista → PrintNode IDs
-- Causa raíz: gateadas por mos._claim_ok() = me.jwt_app() in ('','MOS'), y jwt_app()=''
-- cuando NO hay JWT (anon key sola) → el '' pasa el gate. + grant anon=true. Mismo patrón.
-- FIX: revocar anon. MOS las llama vía _getListaDirectaMOS → _sbRpcMOS → mint-token (role
-- authenticated, VERIFICADO), con fallback a GAS si no hay token. Un Edge las usa con service_role.
-- Ningún caller anon. Tras revocar: MOS (mint) sigue OK; anon-key sola → 42501.
-- (El _claim_ok permisivo afecta a ~27 secdef más; auditar el resto en pase de seguridad dedicado.)
-- ════════════════════════════════════════════════════════════════════════════
revoke execute on function mos.personal_master_lista(jsonb) from anon;
revoke execute on function mos.estaciones_lista(jsonb)       from anon;
revoke execute on function mos.impresoras_lista(jsonb)       from anon;
notify pgrst, 'reload schema';
