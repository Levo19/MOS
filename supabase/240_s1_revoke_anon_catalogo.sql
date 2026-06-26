-- ════════════════════════════════════════════════════════════════════════════
-- 240 · S1 (SEGURIDAD) — cerrar fuga de PII/Admin_PIN: catalogo_pos_rls sin `anon`
-- ════════════════════════════════════════════════════════════════════════════
-- `mos.catalogo_pos_rls()` es SECURITY DEFINER y devolvía, con grant `anon`, SIN filtro de tenant:
--   • me.clientes_frecuentes (DNI/RUC + RazónSocial + Dirección = PII de clientes)
--   • Admin_PIN de cada estación · series documentales · PrintNode IDs
-- Con grant `anon`, CUALQUIERA con la URL + anon key (pública por diseño) extraía todo eso.
--
-- FIX: revocar `anon`. El ÚNICO consumidor es ME (MosExpress), que lo llama con mint-token (Edge mint-me,
-- role `authenticated` — VERIFICADO: PostgREST resuelve current_user='authenticated' para ese JWT). Tras revocar:
--   • ME (mint-token) → authenticated → sigue leyendo el catálogo OK.
--   • atacante con solo la anon key → 42501 permission denied.  ← hueco cerrado.
-- Verificado en vivo (2026-06-25): A) mint-token devuelve el catálogo; B) anon-only → 42501.
--
-- RESIDUAL (hardening futuro, menor): un device AUTENTICADO (operador POS) todavía ve TODO el PII + Admin_PINs.
-- Lo correcto sería separar Admin_PIN/PII a una RPC aparte más restringida. No urgente (devices semi-confiables).
-- ════════════════════════════════════════════════════════════════════════════

revoke execute on function mos.catalogo_pos_rls() from anon;

notify pgrst, 'reload schema';
